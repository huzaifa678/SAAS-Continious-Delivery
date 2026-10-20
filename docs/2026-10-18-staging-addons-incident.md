# Staging bring-up incident — 2026-10-18

A sequential log of every error hit while bringing the `staging` (EKS `saas-eks-test`)
environment up, with root cause and fix for each. Entries are in the order they were
encountered. Fixes are tagged **[CD repo]** (this repo), **[infra]**
(`saas-services-infra`, Terraform), or **[operational]** (one-off cluster action).

## Cross-cutting root causes

Two themes explain most of the individual failures caused by the former configurations:

1. **Half-finished addons migration (Terraform → CD `addons` ApplicationSet).** Several
   addons existed twice: the old Terraform-bootstrapped ArgoCD Applications
   (`external-secrets`, `karpenter`, `cert-manager`, `external-dns`) *and* the new CD
   `*-staging` apps. The duplicates fought (most destructively for External Secrets)
   and the old ones pointed at dead chart refs.
2. **Staging was flipped to `eso` delivery mode** but several pieces still assumed
   `render` mode or prod-only behaviour.

Environment note: the EKS API endpoint resolved intermittently from laptops during the
session (`dial tcp: lookup …eks.amazonaws.com: no such host` / `i/o timeout`), which
made `kubectl` flaky — not a cluster fault, but it slowed diagnosis.

---

## 1. Backstage config-render Job — `StartError` (`/bin/sh` not found)

- **Symptom:** `backstage-config-render-*` pods in `StartError`:
  `exec: "/bin/sh": stat /bin/sh: no such file or directory` (plus a transient
  `FailedMount … failed to sync configmap cache`).
- **Root cause:** the PreSync render Job ran a `/bin/sh -ec` script on image
  `registry.k8s.io/kubectl:v1.31.1`, which is **distroless** (no shell).
- **Fix [CD repo]:** `gitops/infra/backstage/values.yaml` → `config.image: alpine/k8s:1.31.1`
  (kubectl on top of a BusyBox shell). **Committed.**

## 2. Keycloak (staging) on in-cluster Postgres — `keycloak-postgres` CreateContainerConfigError

- **Symptom:** `keycloak-postgres` pod `CreateContainerConfigError`; staging was running
  an in-cluster Postgres though it should use its own RDS instance.
- **Root cause:** staging is in `eso` delivery mode, but `set-delivery-mode.py` and the
  guard only produced the keycloak eso file for **prod**, so staging keycloak was never
  flipped off in-cluster Postgres.
- **Fix [CD repo]:**
  - Added `gitops/infra/keycloak/values-staging.eso.yaml` (enables `gitopsContract.eso`,
    feeds `KC_DB_URL_HOST` from the `keycloak-contract` Secret via `extraEnvFrom`).
  - `gitops/infra/keycloak/values-staging.yaml` → `inClusterDb.enabled: false`.
  - `scripts/set-delivery-mode.py` + `scripts/check-delivery-mode.py`: keycloak eso now
    required for `("staging","prod")`; `docs/gitops-contract-delivery-modes.md` updated.
  **Committed.**

## 3. otel-collector (grafana/monitoring) crashloop — empty `prometheusEndpoint`

- **Symptom:** `otel-collector-*` crashloop; rendered `prometheusremotewrite.endpoint`
  was a scheme-less `api/v1/remote_write`.
- **Root cause:** `.github/workflows/render-gitops.yml` rendered the otel/cilium/velero
  `values-<env>.generated.yaml` **only in `render` mode** (staging is `eso`) and never
  `git add`ed them even in render mode — so staging shipped the chart default
  (`prometheusEndpoint: ""`).
- **Fix [CD repo]:** render-gitops now renders **and commits** otel/cilium/velero in
  both modes (only karpenter/keycloak stay render-gated); `check-delivery-mode.py` guard
  scoped to the toggle-governed charts so the newly-committed cilium/velero generated
  files don't trip it. **Committed.** Takes effect after `render-gitops` runs for the
  `test` tier (and only renders otel if the observability contract is published).

## 4. External Secrets — every ExternalSecret `SecretSyncedError` (cascade)

This starved keycloak / backstage / api-gateway / karpenter of their secrets and was the
single biggest blocker. It unwound in four layers:

### 4a. `could not get ClusterSecretStore "aws-secrets-manager" … not found`
- `kubectl get clustersecretstore` → none. All ExternalSecrets reference it, so all failed.

### 4b. CRD apply blocked by a stale conversion webhook (duplicate operator)
- **Symptom:** `external-secrets-staging` sync `Failed`:
  `CustomResourceDefinition "…external-secrets.io" is invalid: spec.conversion.strategy:
  Required value, spec.conversion.webhookClientConfig: Forbidden: should not be set when
  strategy is not set to Webhook`.
- **Root cause:** the **old v0.9.11** Terraform-bootstrapped ESO operator (with
  `installCRDs: true` + its cert-controller + a `cert-manager.io/inject-ca-from`
  annotation) kept **re-injecting** a conversion-webhook block onto the shared CRDs,
  while the new chart (**v2.10.0**, conversion-less) tried to apply them — producing an
  invalid `conversion` (`webhookClientConfig` without `strategy: Webhook`). The CRD apply
  failed → the sync never reached the wave-2 ClusterSecretStore.
- **Interim [operational]:** created the ClusterSecretStore manually (its CRD was valid).
- **Durable [infra]:** removed the old ESO bootstrap (`kubectl_manifest.external_secrets_app`
  + its template in `modules/k8s-and-helm/argocd.tf`). **Operational cleanup still needed:**
  delete the running old operator + cert-controller and strip the inject annotations, or
  they keep re-injecting.

### 4c. ClusterSecretStore `InvalidProviderConfig`
- **Root cause:** the CD CSS template used `auth.jwt.serviceAccountRef` (IRSA), but this
  cluster authenticates via **EKS Pod Identity**, so jwt/AssumeRoleWithWebIdentity has no
  role to assume.
- **Fix [CD repo]:** `gitops/infra/external-secrets/templates/clustersecretstore.yaml`
  made the `auth` stanza optional (`clusterSecretStore.serviceAccount`); default omits it
  so the AWS provider uses the controller pod's ambient Pod-Identity creds. **Committed.**

### 4d. `GetSecretValue … AccessDeniedException: Access to KMS is not allowed`
- **Root cause:** the SaaS secrets are encrypted with a customer-managed KMS key; the
  external-secrets **Pod Identity role** (`saas-eks-test-external-secrets-irsa` — Pod
  Identity despite the `-irsa` name) lacked `kms:Decrypt`.
- **Fix [infra]:** added `kms:Decrypt`/`kms:DescribeKey` (scoped via `kms:ViaService =
  secretsmanager.<region>.amazonaws.com`) to `external_secrets_policy` in
  `modules/iam/main.tf`. **Uncommitted** (per request). Interim hotfix: an inline role
  policy via `aws iam put-role-policy`.
- **Result:** ClusterSecretStore went `Valid`; ExternalSecrets synced.

## 5. Backstage container — `exec: packages/backend: Permission denied`

- **Symptom:** after #1 was fixed the main pod failed:
  `/usr/local/bin/docker-entrypoint.sh: … exec: packages/backend: Permission denied`.
- **Root cause:** the Deployment's `args` overrode the SAAS-IDP image CMD but dropped the
  leading `node`. The image ENTRYPOINT is the node base image's `docker-entrypoint.sh`
  (`exec "$@"`), so it tried to execute the `packages/backend` **directory**.
- **Fix [CD repo]:** `gitops/infra/backstage/templates/deployment.yaml` — `args` now start
  with `node`. **Committed.**

## 6. Microservices + old addons — `Unknown` sync

### 6a. Microservices (`agent/auth/billing/subscription/usage-service-staging`)
- **Symptom:** `ComparisonError … failed to resolve revision "0.1.0": … HEAD
  https://533267178572.dkr.ecr…/v2/helm/manifests/0.1.0: basic credential not found`.
- **Root cause:** ArgoCD had **no credential for the ECR OCI Helm registry** (charts are
  pushed there; ECR needs auth and tokens expire ~12h). Auth failure, not a missing chart.
- **Fix [CD repo]:** new addon `gitops/infra/argocd-ecr-credentials/` + post-renderer
  overlays — an ESO **`ECRAuthorizationToken` generator** feeding an ArgoCD `repository`
  Secret, refreshed hourly. **Uncommitted/untracked** at teardown.
- **Fix [infra]:** `ecr:GetAuthorizationToken` + pull (`BatchGetImage`,
  `GetDownloadUrlForLayer`, `BatchCheckLayerAvailability` on `repository/helm/*`) added to
  `external_secrets_policy`. **Uncommitted.**
- **Interim [operational]:** a manual `repository` Secret unblocks pulls (~12h). NOTE: at
  teardown the manual secret alone had **not** yet taken effect — suspected argocd-repo-server
  needing a restart, or needing a `repo-creds` (prefix) secret with the host-only URL.
  **Left verifying.**

### 6b. Old `karpenter` / `cert-manager` / `external-dns`
- **Symptom:** `Unknown` sync, e.g. `public.ecr.aws/karpenter:1.4.0: not found`.
- **Root cause:** dead **old Terraform-bootstrapped** duplicates, superseded by the CD
  `*-staging` apps.
- **Fix [infra]:** removed their bootstraps (`kubectl_manifest.{karpenter,cert_manager,
  external_dns}_app` + templates) in `modules/k8s-and-helm/argocd.tf`. **Uncommitted.**
  **Operational cleanup:** `kubectl -n argocd delete application external-secrets
  cert-manager external-dns karpenter` (orphans, doesn't prune). The old `external-dns`
  fighting the new one was the likely cause of missing ArgoCD/Backstage DNS records.

## 7. api-gateway — `failed to initialize Keycloak middleware`

- **Symptom:** `Get http://keycloak-http.keycloak.svc.cluster.local:80/realms/saas/…` fails.
- **Root cause:** **config is correct** (service `keycloak-http`, realm `saas`, port 80 all
  match); the gateway eagerly initialises its Keycloak middleware and dies if keycloak's
  JWKS endpoint is unreachable. Keycloak was still `Degraded` (see #2 + #4).
- **Fix:** none needed — recovers once keycloak is healthy. (Candidate hardening: make the
  gateway tolerate keycloak being temporarily unavailable at startup.)

## 8. otel-collector agent (saas-apps) — kafka config `invalid keys: encoding, topic`

- **Symptom:** `api-gateway-staging-opentelemetry-collector-agent` crashloop:
  `'kafkareceiver.Config'/'kafkaexporter.Config' has invalid keys: encoding, topic`.
- **Root cause:** recent kafka receiver/exporter versions moved `topic`/`encoding` under a
  per-signal `logs:` block; the top-level keys now error.
- **Fix [CD repo]:** nested `topic`/`encoding` under `logs:` for every `kafka/logs`
  receiver/exporter in `saas-chart/values.yaml` + `values-{dev,staging,prod}.yaml`.
  **Committed** (ready to commit).

## 9. logstash — crashloop (kafka consumer class-load failure) — UNRESOLVED

- **Symptom:** `logstash-staging-logstash-0` crashloop; Java `ClassLoader.loadClass`
  stack during kafka consumer construction (`KafkaConsumer.<init>` → `ConfigDef.parseType`
  → `Utils.loadClass`). Exception header not captured before teardown.
- **Suspected cause:** the `aws-msk-iam-auth` uber-jar (added by
  `gitops/observability/elk/logstash/Dockerfile` to `logstash-core/lib/jars/`) not on the
  kafka input plugin's classpath in the bumped `8.19.19` image — i.e. the
  `sasl_client_callback_handler_class` (`software.amazon.msk.auth.iam.IAMClientCallbackHandler`)
  fails to load.
- **Next step:** capture the exception header:
  `kubectl -n logging logs logstash-staging-logstash-0 --tail=250 | grep -iE
  "error|exception|caused by|classnotfound|no such|unable|could not"`.
- **Status:** **open.**

## 10. kibana pre-install token job — 401 then ECONNREFUSED — UNRESOLVED

- **Symptom:** `create-kibana-token` → first `statusCode 401 security_exception
  [elastic]`, later `connect ECONNREFUSED 172.20.16.23:9200`. `kibana-staging` stuck
  `Missing` (the failing PreSync hook blocks the chart).
- **Analysis:** `172.20.16.23` is the `elasticsearch-master` **Service ClusterIP**; at
  teardown ES was healthy (`elasticsearch-master-0` 1/1, endpoint `10.0.6.89:9200`), so
  the ECONNREFUSED was the hook running **before ES was ready** (ordering). The earlier
  401 points at a possible stale-credential mismatch (`elasticsearch-master-credentials`
  secret vs the password persisted in the ES data PVC).
- **Next step:** delete the failed `pre-install-kibana-staging-kibana` job and resync
  `kibana-staging` so the hook re-runs against the now-ready ES. If the **401** returns,
  reset ES creds: delete the ES data PVC + `elasticsearch-master-credentials` and resync
  `elasticsearch-staging` (safe on this test cluster) so a fresh matching password is
  generated.
- **Status:** **open.**

---

## Open items at teardown

- **logstash** crashloop (#9) — need the exception header.
- **kibana** 401/ECONNREFUSED (#10) — re-run hook; possibly reset ES creds.
- **ECR OCI repo credential** (#6a) — verify whether the manual secret works after an
  argocd-repo-server restart or as a `repo-creds` host-only secret; then confirm the new
  `argocd-ecr-credentials` addon mirrors it.
- **Finish the ESO old-operator cutover** (#4b) — remove the running old operator +
  cert-controller + inject annotations so the CRD conversion stops being re-injected.
- **Apply the uncommitted infra changes** (`modules/iam/main.tf`,
  `modules/k8s-and-helm/argocd.tf`) and run the `kubectl … delete application` cleanup.
- **api-gateway** (#7) recovers once keycloak is healthy — re-check after bring-up.
