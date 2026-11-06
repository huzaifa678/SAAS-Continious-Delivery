# Staging bring-up incident — 2026-11-05

A sequential log of every error hit bringing the `staging` (EKS `saas-eks-test`)
environment up from a near-fully-broken ArgoCD dashboard, with root cause and fix for
each. Entries are roughly in the order they were encountered. Fixes are tagged
**[CD repo]** (this repo), **[infra]** (`saas-services-infra`, Terraform),
**[service]** (an individual microservice repo), or **[operational]** (a one-off
cluster/AWS action). Follows the 2026-10-22 incident format.

Starting state: `kubectl -n argocd get applications` showed most apps `OutOfSync` and
`Missing/Degraded` — only the leaf addons (external-dns, aws-lb-controller, crossplane
operator, storage, snapshot-controller, ECR creds, image-updater) were green.

## Cross-cutting root causes

Almost every individual failure traces to a few themes:

1. **Staging was never given a Prometheus stack.** The `prometheus-stack` app is gated
   behind the `stack-grafana` cluster label; staging only carried `stack-elk`. That one
   gap surfaced three times: argo-rollouts' ServiceMonitor failed to apply, istio's HPA
   went `Degraded` (no resource-metrics API → it also exposed that **metrics-server was
   never deployed** at all), and the microservice canary **analysis** (which queries
   Prometheus) aborted the rollouts.
2. **Two node pools, one too-narrow shared security group.** Managed-NG nodes and
   Karpenter nodes share only `saas-eks-test-nodes-sg`, which allowed just DNS/VXLAN/
   health from itself. The managed-NG SG's self "allow-all" doesn't cover Karpenter
   nodes and the cluster-primary SG is only on Karpenter nodes, so **arbitrary
   pod-to-pod traffic between the two pools was dropped** — which independently broke
   Karpenter node registration (private API endpoint), the Crossplane composition
   function gRPC, and the NGINX Gateway Fabric control-plane↔data-plane channel.
3. **The flattened appsets have no cross-app ordering.** `addons`/`infra`/`platform`/
   `microservices` generate independent auto-synced Applications with **no RollingSync
   and no app-of-apps**, so the `sync-wave` annotations are cosmetic across apps —
   convergence relies entirely on ArgoCD's retry loop. That is fine for transient CRD
   races but leaves consumers stuck forever when a CRD-provider app is itself broken, so
   several failures were really "the thing that installs this CRD/XRD never came up".
4. **Missing provisioning the platform assumed existed.** No GitOps provisioned the
   Keycloak `saas` realm, the `keycloak-admin-secret`, or (as a durable manifest)
   metrics-server; several ECR images (functions, a service) weren't published.
5. **Stuck ArgoCD sync operations.** Several apps had a sync operation that began before
   a fix was pushed; while it ran (waiting on health that would never come) `selfHeal`
   could not start a fresh sync, so pushed fixes never applied until the op was
   terminated.

Environment note: the EKS API endpoint is **private-only**, and `kubectl` from the
laptop intermittently returned `net/http: TLS handshake timeout` during the session —
transient, not a cluster fault.

---

## 1. Microservices stuck `Missing` — argo-rollouts never installed (ServiceMonitor)

- **Symptom:** `agent/auth/subscription/billing/usage-service-staging` all
  `OutOfSync/Missing`: `AnalysisTemplate.argoproj.io "" not found; Rollout.argoproj.io
  "" not found`. `argo-rollouts-staging` itself `OutOfSync`.
- **Root cause:** `gitops/infra/argo-rollouts/values.yaml` sets
  `controller.metrics.serviceMonitor.enabled: true` unconditionally. The ServiceMonitor
  CRD (`monitoring.coreos.com`) ships only with `prometheus-stack`, which is gated behind
  the `stack-grafana` cluster label — staging only had `stack-elk`. So argo-rollouts
  couldn't sync → the `Rollout`/`AnalysisTemplate` CRDs never installed → every service
  chart that renders a Rollout died.
- **Fix [CD repo]:** `gitops/infra/argo-rollouts/values-staging.yaml` (new) disables
  `serviceMonitor` + `dashboard` on staging (relies on the addons appset's
  `ignoreMissingValueFiles`). **Committed.** (Superseded in spirit by #16 — staging now
  has Prometheus — but the override is harmless and kept.)

## 2. argo-rollouts `OutOfSync` — invalid notification ConfigMap

- **Symptom:** `argo-rollouts-staging` `OutOfSync`, op error: `failed to create typed
  patch object (argo-rollouts-notification-configmap ... .data.service.slack: expected
  string, got &value.valueUnstructured`.
- **Root cause:** `values.yaml` had `notifications.notifiers.service.slack: {}`. The
  upstream chart writes notifiers into the notification ConfigMap, whose `.data` values
  must be strings; an empty map makes Server-Side Apply reject the ConfigMap.
- **Fix [CD repo]:** removed the `notifications` block (no notifier is actually
  configured). **Committed** (`b7d8397`).

## 3. `infra` / `platform` rejected — Crossplane provider CRD chicken-and-egg

- **Symptom:** `infra-staging` and `platform-staging` `OutOfSync`, op: `one or more
  synchronization tasks are not valid: failed to discover server resources for group
  version postgresql.sql.crossplane.io/v1alpha1 … aws.upbound.io/v1beta1 …
  elasticache.aws.upbound.io/v1beta1 … the server could not find the requested
  resource`.
- **Root cause:** each of these Applications bundles a Crossplane `Provider` package
  (wave `-1`) together with resources that consume the CRDs that provider installs
  (`ProviderConfig`s, claims, the elasticache `User`/`UserGroup`). ArgoCD server-side
  dry-runs the whole manifest set **at plan time, before any wave applies**, so it can't
  discover the not-yet-registered CRDs and rejects the entire sync. Sync-waves don't help
  because discovery precedes wave application.
- **Fix [CD repo]:** `appsets/infra.yaml` + `appsets/platform.yaml` — added
  `SkipDryRunOnMissingResource=true` to `syncOptions` and a `retry` block, so the plan
  proceeds and waves + retry converge once the provider registers its CRDs. **Committed.**

## 4. `api-gateway` `Degraded` — green slot rendered an empty image

- **Symptom:** `api-gateway-staging` op: `Deployment.apps "api-gateway-green" is invalid:
  spec.template.spec.containers[0].image: Required value`.
- **Root cause:** `saas-chart/templates/api-gateway.yaml` sets the non-active (green)
  slot's image to `apiGateway.blueGreen.previewImage`, which is `""` at rest (staging/
  prod promote via gated PRs, no image-updater). An empty `image` is an invalid
  Deployment, failing every sync even though the slot is scaled to 0.
- **Fix [CD repo]:** fall back to the active image when `previewImage` is empty
  (`$bg.previewImage | default (printf "%s:%s" repo tag)`). Rendered green now carries a
  valid image. **Committed.**

## 5. `keycloak-0` `CreateContainerConfigError` — admin secret never provisioned

- **Symptom:** `keycloak-0` `CreateContainerConfigError`; the StatefulSet mounts
  `keycloak-admin-secret/password` (for `KC_BOOTSTRAP_ADMIN_PASSWORD`, `Optional: false`)
  but the secret did not exist. (ESO itself was healthy — the `keycloak-contract` and
  `keycloak-postgres-secret` ExternalSecrets synced fine.)
- **Root cause:** nothing created `keycloak-admin-secret`. `values.yaml` only noted
  "provide it via external-secrets or manually"; no ExternalSecret template existed.
- **Fix [CD repo]:** `gitops/infra/keycloak/templates/admin-secret-externalsecret.yaml`
  (new) materializes `keycloak-admin-secret/password` from AWS Secrets Manager (wave
  `-5`), plus an `adminSecret` values block. **Committed** (`79fd389`).
- **Prerequisite [operational]:** the AWS SM secret `keycloak-admin-secret` (key
  `password`) must exist, else the ExternalSecret reports `SecretSyncError`.

## 6. `istio` `Degraded` — no metrics-server

- **Symptom:** `istiod` pod `1/1 Running`, but the app is `Degraded`; events show the
  HPA `FailedGetResourceMetric ... unable to fetch metrics from resource metrics API …
  pods.metrics.k8s.io not found`. `kubectl top` → `Metrics API not available`.
- **Root cause:** metrics-server is not installed anywhere in the repo (KEDA's
  `external.metrics.k8s.io` and the EKS extension API do not provide the
  `v1beta1.metrics.k8s.io` resource-metrics API that CPU/memory HPAs need).
- **Fix [CD repo]:** new addon `gitops/infra/metrics-server/` (Chart.yaml + vendored
  `metrics-server-3.12.2.tgz` + `app.yaml` ns `kube-system` wave `-2` + values) and
  `post-renderer/infra/metrics-server/{base,overlays/{dev,staging,prod}}` (the addons
  appset requires the post-renderer overlay dir or the sync fails). **Committed.**

## 7. Karpenter `CreateContainerConfigError` — transient contract-secret race

- **Symptom:** both `karpenter-staging` controller pods (ns `kube-system`)
  `CreateContainerConfigError`; `INTERRUPTION_QUEUE` references the `karpenter-contract`
  secret.
- **Root cause:** the `karpenter-contract` ExternalSecret (wave `-2`) had not finished
  syncing when the controller first started, during a fresh bring-up.
- **Fix:** none needed — self-healed once ESO wrote the secret (pod then `1/1 Running`,
  all conditions `True`, no events). **No change.**

## 8. Karpenter provisioned NodeClaims that never launched — EC2 Spot SLR missing

- **Symptom:** Karpenter healthy and creating NodeClaims, but the `default` pool
  (spot) NodeClaim stuck; controller logs repeat `AuthFailure
  .ServiceLinkedRoleCreationNotPermitted: The provided credentials do not have permission
  to create the service-linked role for EC2 Spot Instances`.
- **Root cause:** the account lacks the `AWSServiceRoleForEC2Spot` service-linked role,
  and Karpenter's controller role isn't permitted to create it.
- **Fix [infra]:** `layers/10-platform/main.tf` — added
  `aws_iam_service_linked_role.ec2_spot` (`aws_service_name = "spot.amazonaws.com"`),
  account-wide, with an import note for the case where it already exists. **Written.**

## 9. Karpenter on-demand node launched but never registered — private endpoint + SG

- **Symptom:** the `data` pool (on-demand) launched an instance (`provider-id` present)
  but the node never joined; Karpenter GC'd the NodeClaim at the 15-min registration
  timeout. `EC2NodeClass` fully `Ready`, access entry present and correct
  (`EC2_LINUX` / `system:nodes`).
- **Root cause:** the cluster API endpoint is **private-only**, so the kubelet reaches
  the API through the EKS **cluster primary security group** — but Karpenter nodes attach
  only the SG(s) matched by `securityGroupSelectorTerms` (tag `karpenter.sh/discovery`),
  which matched just the custom `*-nodes-sg`. Managed-NG nodes auto-attach the cluster
  primary SG; Karpenter nodes did not, so the kubelet couldn't register.
- **Fix [infra]:** tag the cluster primary SG for Karpenter discovery —
  `layers/10-platform/main.tf` `aws_ec2_tag.karpenter_cluster_primary_sg_discovery`
  (`karpenter.sh/discovery=<cluster>` on `module.eks.cluster_primary_security_group_id`)
  plus a new `cluster_primary_security_group_id` output on `modules/eks`. **Written.**
  (Quick operational unblock: `aws ec2 create-tags --resources <cluster-sg>
  --tags Key=karpenter.sh/discovery,Value=saas-eks-test`.)

## 10. Crossplane Functions `Installed: False` — image tag absent from ECR

- **Symptom:** `function-appcache` / `function-appdatabase` `Installed=False`:
  `MANIFEST_UNKNOWN: Requested image not found … :sha-f9fb15f6`; `platform-staging` op
  stuck `waiting for healthy state of Function/function-appcache`.
- **Root cause:** the pinned function image tag was never built/pushed to ECR.
- **Fix [service/operational + CD repo]:** rebuilt + pushed the function images; repinned
  `platform/functions/functions.yaml` to `sha-b7d8397e`. **Committed** (`2ec3051`).

## 11. `provider-aws-elasticache` `Installed: False` — pinned a version that never existed

- **Symptom:** `UnpackPackage` error: `MANIFEST_UNKNOWN: manifest unknown; unknown
  tag=v1.21.1` for `xpkg.upbound.io/upbound/provider-aws-elasticache:v1.21.1`.
- **Root cause:** `v1.21.1` is not published — the Upbound v1 line tops out at `v1.9.2`;
  the current line is `v2.x`.
- **Fix [CD repo]:** `platform/providers/provider-aws.yaml` → pin `v2.9.4`. v2 preserves
  the `v1beta1` APIs this repo uses (the `aws.upbound.io/v1beta1` ProviderConfig and the
  `elasticache.aws.upbound.io/v1beta1` User/UserGroup/ReplicationGroup the AppCache
  composition emits) and keeps the same package name + SA. **Written.**

## 12. `logstash` crashloop — MSK IAM jar in the wrong classloader

- **Symptom:** `logstash-staging-logstash-0` FATAL: `java.lang.NoClassDefFoundError:
  org/apache/kafka/common/security/auth/AuthenticateCallbackHandler`.
- **Root cause:** `IAMClientCallbackHandler` (from `aws-msk-iam-auth`) implements
  kafka-clients' `AuthenticateCallbackHandler`. The Dockerfile put the IAM jar in
  `logstash-core/lib/jars` (the parent/boot classpath), but in Logstash 8.19 /
  logstash-integration-kafka 11.x `kafka-clients` is loaded by the **plugin's own
  classloader** (`vendor/jar-dependencies`), which the parent can't see — so the handler
  fails to link. (Worked on the old 8.5.1 image; regressed on the 8.19 bump.)
- **Fix [CD repo]:** `gitops/observability/elk/logstash/Dockerfile` — install the jar
  into the kafka plugin's `vendor/jar-dependencies/software/amazon/msk/aws-msk-iam-auth/
  <ver>/` tree and register it via `require_jar` in the plugin's `*_jars.rb`, so it
  shares the classloader with `kafka-clients`. **Written — needs `logstash-msk` image
  rebuild + retag.**

## 13. Stuck ArgoCD sync operations blocked pushed fixes (platform, nginx-gateway)

- **Symptom:** after pushing the function retag, the live `Function` kept reverting to
  the old `sha-f9fb15f6`; `platform-staging` `operationState.phase=Running` pinned to a
  pre-push revision. `nginx-gateway-staging` likewise `Running` on an ancient revision.
- **Root cause:** a sync operation that started before the push captured the old
  manifests and kept re-applying them; while an operation runs, `selfHeal` won't start a
  new sync, so HEAD never applied. `kubectl patch … operation=null` only cancels a
  *queued* op, not a running one.
- **Fix [operational]:** terminate the running op (what the ArgoCD UI "Terminate" does) —
  `kubectl -n argocd patch application <app> --type merge -p
  '{"status":{"operationState":{"phase":"Terminating"}}}'` — then `selfHeal` re-syncs
  against HEAD. For functions, a direct `kubectl patch function.pkg … spec.package=<new>`
  also breaks the deadlock. After terminating, `function-app*` installed on
  `sha-b7d8397e` and stayed, and the `nginx-gateway-staging-config` CR finally applied.

## 14. Microservice Rollouts `InvalidSpec` — canary analysis arg not resolved

- **Symptom:** `agent/auth/subscription/usage/billing` Rollouts `Degraded`,
  `spec.strategy.canary.steps[2].analysis.templates: Invalid value … args.service-name
  was not resolved` → the Rollout controller created **zero** pods.
- **Root cause:** the inline canary **step** analysis (rendered verbatim from
  `rollout.steps` in values) references the `*-success-rate` / `*-latency-p95`
  AnalysisTemplates without passing their required `service-name` arg, and the templates
  declared the arg with **no default**. (The background `analysis` block passes it; the
  step-level ones don't.)
- **Fix [CD repo]:** default the `service-name` (`{{ $svc }}`) and `namespace`
  (`{{ .Release.Namespace }}`) args in each `charts/<svc>/templates/analysistemplate.yaml`
  (×5), and bump each `Chart.yaml` `0.1.1 → 0.1.2`. **Written — needs push so the
  push-charts workflow republishes `0.1.2` and the floating range resolves it.**

## 15. `api-gateway` crashloop — Keycloak `saas` realm not provisioned

- **Symptom:** `api-gateway-blue-*` `CrashLoopBackOff`: `failed to initialize Keycloak
  middleware … invalid HTTP status code: 404` fetching
  `/realms/saas/protocol/openid-connect/certs`.
- **Root cause:** Keycloak was up but **empty** — nothing in GitOps imported the `saas`
  realm (the keycloak chart had no realm import; Backstage only consumes it).
- **Fix [CD repo]:** wire realm import into the keycloakx chart —
  `keycloakx.command` adds `--import-realm`; `extraVolumes`/`extraVolumeMounts` mount a
  `keycloak-realm-import` ConfigMap at `/opt/keycloak/data/import`;
  `templates/realm-import-configmap.yaml` builds it from `files/saas-realm.json`; a
  `realmImport.enabled` toggle. Added `files/saas-realm.json` (realm `saas`, clients
  `saas-frontend` + `api-gateway`, roles platform-admin/tenant-admin/user). **Written.**
  Note: it's a git-committed ConfigMap, so the export must carry no client secrets (the
  `api-gateway` confidential client's secret is Keycloak-generated on import).

## 16. Canary analysis can't run on staging — no Prometheus

- **Symptom:** once the Rollouts were valid (#14), `auth-service` started cleanly then
  received `SIGTERM` ~26s later — the canary reached its analysis step, couldn't reach
  `prometheus-stack-kube-prom-prometheus.monitoring.svc:9090`, and the rollout aborted.
- **Root cause:** `charts/<svc>/values-staging.yaml` enables Prometheus-gated canary
  analysis, but staging had no Prometheus (same gap as #1/#6).
- **Fix [infra]:** `live/test/env.hcl` → `observability = ["elk", "grafana"]` (matching
  prod). `contains(observability,"grafana")` sets `stack-grafana=true` on the ArgoCD
  cluster secret (`modules/k8s-and-helm`), so the observability ApplicationSet deploys
  `prometheus-stack` on staging. **Written — apply `live/test/50-addons-helm`.** (`elk`
  stays first so `layers/40-observability`, which uses `observability[0]`, is unchanged.)

## 17. `kibana` stuck `Missing` — pre-install hook secret already exists

- **Symptom:** `pre-install-kibana-staging-kibana-*` jobs `Error`; the hook creates the
  ES token successfully (`200`) then fails creating the K8s secret: `409 … secrets
  "kibana-staging-kibana-es-token" already exists`.
- **Root cause:** a leftover secret from earlier failed runs; the hook uses `create`
  (not idempotent). (ES itself was healthy by then.)
- **Fix [operational]:** `kubectl -n logging delete secret
  kibana-staging-kibana-es-token` → the next retry recreates it and completes. **Durable
  follow-up [CD repo, open]:** make the hook idempotent (`kubectl apply` / `create
  --dry-run=client -o yaml | apply`).

## 18. `subscription-service` crashloop — broken image

- **Symptom:** `Error: Cannot find module '/app/dist/main.js'` → `MODULE_NOT_FOUND`.
- **Root cause:** the published subscription-service image is missing its compiled
  output (bad build).
- **Fix [service]:** rebuild/republish the image from the service repo CI. **Open** — not
  an infra/GitOps issue.

## 19. DB tier down — Crossplane composition function unreachable (the keystone)

The single highest-impact failure: `agent-service` (`Connection to localhost:5434
refused` — the app fell back to localhost because its DB connection secret never
existed), `usage-service`/`airflow` (`secret "<svc>-db" not found`), and
`billing-service` (`Missing`) were all down for one reason.

- **Symptom:** `XAppDatabase` composites created but producing **zero** managed
  resources; composite events: `cannot run Function "function-appdatabase": rpc error:
  code = DeadlineExceeded … dial tcp 10.0.3.x:9443: i/o timeout`. The function pod was
  `1/1 Running` on a Karpenter node; Cilium agents healthy on every node; all
  `rds-<instance>` ProviderConfigs present.
- **Root cause:** **pod-to-pod traffic between the managed-NG and Karpenter node pools
  was dropped** (theme 2). Crossplane (on a managed node) couldn't reach the
  `function-appdatabase` gRPC (`:9443`) on the Karpenter node. The pools share only
  `saas-eks-test-nodes-sg`, which allowed just DNS/VXLAN/health from itself; the managed
  SG's self "allow-all" isn't on Karpenter nodes, and the cluster-primary SG isn't on
  managed nodes — so no SG permitted arbitrary pod ports between pools. **The same drop
  also caused the NGINX Gateway Fabric data-plane↔control-plane timeouts** (keycloak/
  argocd/backstage gateways `Degraded`, `dial 172.20.181.240:443 i/o timeout`).
- **Fix [infra]:** `modules/node-security-group/main.tf` — add a self-referencing
  **allow-all** ingress (`node_to_node_all`, `ip_protocol = "-1"`, referenced SG = the
  node SG). Both pools already carry this SG, so it becomes the one shared path for all
  intra-cluster pod traffic (standard EKS node-SG behaviour). **Written.** SG rule changes
  apply **live** to running instances, so no node recycle is needed. (Immediate
  operational unblock: `aws ec2 authorize-security-group-ingress --group-id
  <nodes-sg> --ip-permissions 'IpProtocol=-1,UserIdGroupPairs=[{GroupId=<nodes-sg>}]'`.)
  This one fix restores the whole DB tier **and** the gateways.

---

## Open items

- **Push the CD-repo changes:** `charts/*` (`0.1.2`, #14), `platform/providers/
  provider-aws.yaml` (#11), `gitops/observability/elk/logstash/Dockerfile` (#12),
  `gitops/infra/keycloak/**` (#15). Several were already committed (#1, #2, #3, #4, #5,
  #6, #10).
- **Build/apply/operational:**
  - Rebuild + push `logstash-msk` and bump its `imageTag` (#12).
  - Apply infra: `layers/10-platform` (Spot SLR + cluster-primary-SG discovery tag, #8/#9),
    `modules/node-security-group` (#19), `live/test/50-addons-helm` (Prometheus, #16).
  - Create the `keycloak-admin-secret` in AWS Secrets Manager (#5).
  - Apply the `nodes-sg` allow-all (live via CLI or Terraform, #19) — unblocks the DB
    tier and the gateways.
- **subscription-service image** (#18) — rebuild/republish from the service repo.
- **kibana pre-install hook idempotency** (#17) — switch `create` to `apply`.
- **Realm redirect URIs** (#15) — `files/saas-realm.json` `saas-frontend` redirect was set
  to `https://app.staging.freeeasycrypto.com` (inferred from the keycloak host); confirm
  the real frontend URL.
- **Re-enable argo-rollouts `serviceMonitor` on staging** (#1) now that Prometheus is
  deployed, if ServiceMonitor scraping of the rollouts controller is wanted.
