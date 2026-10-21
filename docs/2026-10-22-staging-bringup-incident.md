# Staging bring-up incident — 2026-10-22

A sequential log of every error hit while bringing the `staging` (EKS `saas-eks-test`)
environment up, with root cause and fix for each. Entries are roughly in the order they
were encountered. Fixes are tagged **[CD repo]** (this repo), **[infra]**
(`saas-services-infra`, Terraform), **[service]** (an individual microservice repo), or
**[operational]** (one-off cluster/AWS action). Follows the 2026-10-18 incident format.

## Cross-cutting root causes

Most individual failures trace to a few themes:

1. **Nothing could schedule because Karpenter never provisioned a node.** A chain of
   three independent Karpenter/IAM bugs (SA↔Pod-Identity name mismatch, a reserved label
   on the NodePools, and the controller IAM role missing `ec2:CreateFleet` prerequisites)
   kept `EC2NodeClass` `Ready=False`. With only the 2 (later 3) managed-node-group nodes,
   ELK and the microservice pods sat `Pending`, and a capacity deadlock stalled
   `argocd-repo-server` itself.
2. **OCI Helm charts in ECR were unreachable by ArgoCD.** The microservice apps pull
   their charts from `…/helm/<svc>` in ECR; a `oci://` scheme mismatch on the repoURL, a
   missing `ec2`→`ecr:ListImages` permission, and a stale published chart schema each
   blocked them in turn.
3. **Deprecated upstreams.** Bitnami pulled its public Docker Hub catalog (keycloak), the
   ADOT otel image lacks contrib components, and a dependabot bump pushed an OTel artifact
   past the Spring-managed SDK — all surfaced as pull/validation/crash failures.

Environment note: the EKS API endpoint resolved intermittently from the laptop during the
session (`dial tcp: lookup …eks.amazonaws.com: i/o timeout` / `no such host`), making
`kubectl` flaky — not a cluster fault.

---

## 1. kibana pre-install token job — `ECONNREFUSED` to elasticsearch:9200

- **Symptom:** `pre-install-kibana-staging-kibana-*` jobs in `Error`:
  `create-kibana-token` → `connect ECONNREFUSED 172.20.x.x:9200`; `kibana-staging` stuck
  `Missing` (the failing PreSync hook blocks the chart). Carried over from 2026-10-18 #10.
- **Root cause:** Kibana's chart pre-install hook hits the `elasticsearch-master` Service
  before ES has ready endpoints. Kibana's `app.yaml` was `syncWave: "0"` — the **same wave
  as Elasticsearch** (logstash=1, otel=2) — so Argo applied them together and the hook
  raced ES. The observability ApplicationSet also had **no `retry`**, so a failed PreSync
  hook never self-healed (left `kibana-staging` Missing indefinitely).
- **Fix [CD repo]:**
  - `gitops/observability/elk/kibana/app.yaml` → `syncWave: "1"` (after ES).
  - `appsets/observability.yaml` → added `syncPolicy.retry` (limit 7, 30s→10m backoff) so
    the hook re-runs until ES is ready. (The retry was the committed durable fix.)
- **Note:** these Applications are generated independently (no `RollingSync`), so the wave
  annotation is intent/ordering; the `retry` is what actually recovers. **Committed.**

## 2. otel-collector (ELK, monitoring) crashloop — unknown config components

- **Symptom:** `otel-collector-*` (namespace `monitoring`, ELK stack) crashloop:
  `unknown type: "transform" for id "transform/logs"`, `unknown type: "opensearch"`,
  `unknown type: "sigv4_os"`.
- **Root cause:** the image was the **ADOT** collector (`public.ecr.aws/aws-observability/
  aws-otel-collector`), which doesn't ship the upstream-contrib `transform` processor or
  `opensearch` exporter. Also a genuine config bug: `sigv4_os` was used as an extension
  **type** — a named `sigv4auth` instance must be keyed `sigv4auth/os`.
- **Fix [CD repo]** (`gitops/observability/elk/otel-collector/`):
  - `values.yaml` → image `otel/opentelemetry-collector-contrib:0.159.0`.
  - `templates/configmap.yaml` → `sigv4_os` → `sigv4auth/os` (definition + references).
  - Corrected the `opensearch` exporter to the contrib 0.159.0 schema: `endpoint`/`auth`
    nested under `http:`, added required `dataset`/`namespace`, replaced the invalid
    Logstash-style `%{+yyyy.MM.dd}` with `logs_index` + `logs_index_time_format` (the date
    suffix is joined with a `-`).
- **Status:** **committed**; renders clean via `helm template`.

## 3. api-gateway — `ImagePullBackOff` (image tag absent from ECR)

- **Symptom:** `api-gateway-blue-*` `ImagePullBackOff`:
  `…/api-gateway:sha-c27eadd…: not found`.
- **Root cause:** `saas-chart/values-staging.yaml` pins an image `sha-` tag that was never
  built/pushed to ECR (staging tags come from gated promotion PRs, not image-updater).
- **Fix [operational]:** build+push that commit's image, or repin the staging tag to one
  that exists in ECR (`aws ecr describe-images --repository-name api-gateway`).
- **Status:** **open** (not a repo bug — needs the image published).

## 4. otel-collector agent (saas-apps) — kafka receiver `'logs' has invalid keys: topic`

- **Symptom:** `api-gateway-staging-opentelemetry-collector-agent` crashloop:
  `'receivers' … "kafka/logs" … 'logs' has invalid keys: topic`.
- **Root cause:** at contrib 0.159.0 the kafka **receiver** per-signal block takes
  `topics` (a **list**), while the kafka **exporter** takes a singular `topic`. The base
  config used `topic` for both; the receiver rejected it.
- **Fix [CD repo]:** `saas-chart/values.yaml` + `values-dev.yaml` kafka **receiver** →
  `logs.topics: [otel-logs]` (exporter `logs.topic` left as-is). **Committed.**
- **Follow-on (same agent, after #5 let it render) [CD repo]:** the collector then
  rejected the SASL mechanism at runtime — `kafka/logs…auth::sasl: mechanism should be one
  of 'PLAIN', 'AWS_MSK_IAM_OAUTHBEARER', 'SCRAM-SHA-256', 'SCRAM-SHA-512'; configured value
  AWS_MSK_IAM`. At contrib 0.159.0 the MSK-IAM mechanism is named
  **`AWS_MSK_IAM_OAUTHBEARER`**. Changed all six kafka `auth.sasl.mechanism` values in
  `saas-chart/values{,-dev,-staging,-prod}.yaml`. (The Logstash kafka input keeps
  `AWS_MSK_IAM` — different client, using the MSK-IAM auth jar.) **Committed.**

## 5. api-gateway render broken by otel `null` overrides (self-inflicted)

- **Symptom:** `api-gateway-staging` `ComparisonError`:
  `opentelemetry-collector.rewriteDeprecatedComponentNames … expected
  map[string]interface {}; got interface {}`.
- **Root cause:** an attempt to stop staging/prod inheriting the dev Kafka→Loki consumer
  used `key: null` overrides (`receivers.kafka/logs: null`, `service.pipelines.logs/consume:
  null`, `traces: null`). The otel subchart's `rewriteDeprecatedComponentNames` walks the
  config maps and dies on any `null` value.
- **Fix [CD repo]:** reverted the `null` overrides in `saas-chart/values-staging.yaml` and
  `values-prod.yaml` (keeps the valid `topics:` receiver fix from #4). Renders clean again.
  **Committed.**
- **Follow-up:** the cleaner way to keep the dev consumer out of staging/prod is to move it
  from the shared base `values.yaml` into `values-dev.yaml` (no `null`s). Not yet done;
  staging currently inherits a Kafka→Loki consumer pointed at a non-existent `loki`
  (logs export errors, non-fatal).

## 6. Image/dependency scan failures in the service repos

- **agent-service & billing-service — Trivy HIGH `CVE-2026-77214` (`libexpat`).**
  - **Root cause:** the pinned `eclipse-temurin:21-jre-alpine` base ships `libexpat
    2.8.5-r0`; fixed in `2.9.0-r0`. The first fix used `apk upgrade … expat` — a **silent
    no-op**, because the installed package is **`libexpat`**, not `expat`.
  - **Fix [service]:** `RUN apk upgrade --no-cache libexpat` in each service's runtime
    stage (verified against the pinned base image: `2.8.5-r0 → 2.9.0-r0`).
- **billing-service — `contextLoads()` fails, `NoClassDefFoundError
  io/opentelemetry/api/incubator/common/ExtendedAttributeKey`.**
  - **Root cause:** a dependabot bump (`8b5590b`) moved
    `opentelemetry-api-incubator` to `1.67.0-alpha`, but Spring Boot 4.1.1 manages the OTel
    SDK at `1.62.0`; `sdk-logs 1.62.0` needs the incubator at the matching version.
  - **Fix [service]:** pin `opentelemetry-api-incubator:1.62.0-alpha` in
    `billing-bootstrap/build.gradle`. (Consider a dependabot ignore so it doesn't re-bump.)
- **usage-service (airflow image) — Trivy `aiohttp`/`certifi`/`uv` HIGH/CRITICAL.**
  - **Fix [service]:** `airflow/requirements.txt` → `aiohttp>=3.14.4`,
    `certifi>=2026.10.19`; `uv` (bundled tool binary) ignored in `airflow/.trivyignore`
    (`GHSA-hq85-5cpj-mr62`), consistent with the existing vendored-tool ignores. Lockfile
    regenerated for SAAS-IDP's follow-redirects/markdown-it bumps (below).
- **SAAS-IDP (Backstage) — Trivy Node.js HIGH `follow-redirects`/`markdown-it`.**
  - **Fix [service]:** `resolutions` → `follow-redirects: 1.16.1`, `markdown-it: 14.3.3`
    (clears CVE-2026-111755/111756 and -111758/-111759); `yarn.lock` regenerated so
    `yarn install --immutable` passes.

## 7. Karpenter never provisioned nodes — three stacked bugs + a capacity deadlock

The single biggest blocker. `EC2NodeClass default` sat `Ready=False`, so no Karpenter node
ever launched; ELK and microservice pods stayed `Pending`.

### 7a. Controller Deployment rejected by SSA — duplicate `CLUSTER_NAME` env
- **Symptom:** `karpenter-staging` sync `Failed`: `…Kind=Deployment …
  containers["controller"].env: duplicate entries for key [name="CLUSTER_NAME"]`.
- **Root cause:** staging loads both `values-staging.yaml` (sets `settings.clusterName`
  statically — needed for the NodePool/EC2NodeClass discovery tags at Helm render) **and**
  `values-staging.eso.yaml` (injects `CLUSTER_NAME` via `controller.env` from the
  `karpenter-contract` Secret). The chart emits `CLUSTER_NAME` from `settings.clusterName`
  **and** from `controller.env` → duplicate → Server-Side Apply rejects the Deployment.
- **Fix [CD repo]:** `gitops/infra/karpenter/values-staging.eso.yaml` — drop the
  `CLUSTER_NAME` entry from `controller.env` (keep `INTERRUPTION_QUEUE`); `settings
  .clusterName` is the sole source. **Committed.**

### 7b. Pod Identity never bound — ServiceAccount name mismatch
- **Symptom:** after 7a, the controller ran but used the **node instance role**
  (`default-eks-node-group-…`) → `403 UnauthorizedOperation` on `ec2:DescribeImages`,
  `DescribeInstanceTypeOfferings`, `pricing:GetProducts`; SQS `NonExistentQueue`.
- **Root cause:** the EKS Pod Identity association (`layers/10-platform`) targets SA
  `karpenter` in `kube-system`, but the CD Helm release is named `karpenter-staging`, so
  the chart's SA defaulted to `karpenter-staging`. No association matched → the pod fell
  back to the node role (uses Pod Identity, which requires the exact SA name).
- **Fix [CD repo]:** `gitops/infra/karpenter/values.yaml` →
  `karpenter.serviceAccount.name: karpenter` (env-independent; matches the association).
  **Committed.** Verified the pod then carried `AWS_CONTAINER_CREDENTIALS_FULL_URI`.

### 7c. NodePools invalid — reserved label
- **Symptom:** sync op `Failed`: `NodePool.karpenter.sh "data/default/batch" is invalid:
  spec.template.metadata.labels: label "karpenter.sh/nodepool" is restricted`.
- **Root cause:** `templates/nodepool.yaml` set `karpenter.sh/nodepool: <name>` in each
  pool's `spec.template.metadata.labels` — a **reserved label Karpenter sets itself**.
- **Fix [CD repo]:** removed that label from all three pools (kept `workload: data|batch`).
  **Committed.**

### 7d. `EC2NodeClass` `CreateFleetAuthCheckFailed` — controller IAM gaps
- **Symptom:** subnets/SGs/AMIs/instance-profile all `Ready=True`, but
  `ValidationSucceeded=False (CreateFleetAuthCheckFailed): Controller isn't authorized to
  call ec2:CreateFleet`. No denial logged (reported as a condition, not an error).
- **Root cause (found via CloudTrail + `iam simulate-principal-policy`):** the controller
  policy was missing permissions the `CreateFleet` DryRun needs. In order:
  1. `ec2:CreateFleet` had no `fleet/*` (nor `snapshot/*`) in its `Resource` list.
  2. The real blocker: **`ec2:CreateTags`** was absent from the create-actions statement.
     `CreateFleet` tags the fleet/instance/volume *at creation* via `TagSpecification`,
     which AWS authorizes as `ec2:CreateTags` on those create resources. `CreateTags`
     existed only in a separate statement gated on `aws:ResourceTag=owned`, which a
     **not-yet-created** resource can't satisfy → the DryRun was denied. CloudTrail named
     it exactly: `not authorized to perform: ec2:CreateTags on resource …/fleet/*`.
- **Fix [infra]:** `modules/iam/karpenter.tf` `AllowScopedEC2InstanceActions` — added
  `fleet/*` + `snapshot/*` resources and the `ec2:CreateTags` action (region-scoped like
  the rest). **After apply + a controller restart, `EC2NodeClass` went `Ready=True` and a
  `data` NodeClaim launched.** Ruled out SCP (account is the org **management** account —
  immune to SCPs — and only `FullAWSAccess` exists) and permissions boundaries (none).

### 7e. Bootstrap capacity deadlock
- **Symptom:** `argocd-repo-server` (new rollout replica) and ELK/otel pods `Pending`;
  nodes at ~87% CPU requests.
- **Root cause:** the 2 managed nodes were full, Karpenter (7a–7d) couldn't add nodes, and
  the pods needed to fix Karpenter (repo-server to render, the controller to roll) couldn't
  schedule — a deadlock.
- **Fix [operational]:** temporarily scaled the EKS **managed** node group to
  `desiredSize=3` (`aws eks update-nodegroup-config …`) for headroom. Revert to 2 once
  Karpenter carries the load. (Not a GitOps-tracked change; bump `desired_size` in
  `layers/10-platform` if you want it persisted.)

## 8. Microservices (`agent/auth/billing/subscription/usage-service-staging`) — `Unknown` sync

Three stacked causes behind `basic credential not found` / schema errors on the ECR OCI
Helm charts (`oci://…/helm/<svc>`):

### 8a. Credential never matched — `oci://` scheme mismatch
- **Root cause:** the `argocd-ecr-credentials` ESO Secret (url `…/helm`, no scheme) didn't
  match the appset source `repoURL: oci://…/helm`. ArgoCD's OCI credential lookup didn't
  reconcile the scheme difference → `basic credential not found`.
- **Fix [CD repo]:** `appsets/microservices.yaml` → repoURL **scheme-less**
  (`533267178572.dkr.ecr.us-east-1.amazonaws.com/helm`); `enableOCI: true` on the credential
  marks it OCI. (The `repository` vs `repo-creds` secret type was a red herring — once the
  scheme matched, matching worked; the Secret is back to `repository`/exact-match in
  `gitops/infra/argocd-ecr-credentials/templates/ecr-helm-repo-externalsecret.yaml`.)
  **Committed.**

### 8b. Tag listing denied — `ecr:ListImages`
- **Symptom:** after 8a, `403 … not authorized to perform: ecr:ListImages on …/helm/<svc>`.
- **Root cause:** the appset uses a **SemVer range** `targetRevision: ">=0.1.0 <1.0.0"`
  (floating, so a chart bump auto-resolves without editing the appset). Resolving a range
  requires **listing tags**; the ESO role (`saas-eks-test-external-secrets-irsa`, which
  mints the ECR token) had only pull actions.
- **Fix [infra]:** `modules/iam/main.tf` — added `ecr:ListImages` + `ecr:DescribeImages`
  on `repository/helm/*` to the ESO role. **Applied.**

### 8c. Stale published chart schema (version skew)
- **Symptom:** after 8b, `values don't meet the specifications of the schema(s) …
  additional properties 'serviceAccount', 'externalSecret', 'security', 'migrations' not
  allowed`.
- **Root cause:** the repo charts gained new keys + an updated `values.schema.json`, but
  the **published** `helm/<svc>:0.1.0` still carried the **old** schema (the push-charts
  workflow skips re-publishing an existing immutable version). Values from git `main`
  (new) validated against the old published schema → fail.
- **Fix [CD repo]:** bumped `charts/<svc>/Chart.yaml` `version: 0.1.1` for all five
  services; the push-charts workflow published `0.1.1`, and the floating range resolved to
  it. Apps moved `Unknown`→`OutOfSync/Missing` (render+validate OK; waiting only on nodes).
  **Committed.** NOTE: the `image.tag` lives in git values (`$values/.../values-<env>.yaml`,
  read from `main`), decoupled from the chart version — a tag change needs no chart bump.

## 9. keycloak — Bitnami image `NotFound` (Docker Hub deprecation)

- **Symptom:** `keycloak-0` init container `ImagePullBackOff`:
  `docker.io/bitnami/keycloak:26.3.3-debian-12-r0: not found`; `keycloak-postgresql-0`
  likewise.
- **Root cause:** the stray `keycloak-helm` app (Bitnami chart, created by Terraform
  `modules/k8s-and-helm/argo-keycloak.yaml.tpl`, **separate** from the gitops keycloakx
  `keycloak-staging`) pulls `docker.io/bitnami/*`, which Bitnami removed from Docker Hub
  (Aug 2025). Its bundled Postgres subchart was also running though keycloak uses RDS
  (`externalDatabase.host`).
- **Fix [infra]:** `modules/k8s-and-helm/argo-keycloak.yaml.tpl` →
  `image.repository: bitnamilegacy/keycloak` (frozen archive still has historical tags) and
  `postgresql.enabled: false` (keycloak is on RDS). **Committed (apply pending).**
- **Follow-on [infra]:** after the image pulled, keycloak crashed with
  `UnknownHostException: keycloak-db.<…>.rds.amazonaws.com:5432` — the RDS **port was baked
  into the hostname**. `externalDatabase.host` used the RDS *endpoint* (`host:5432`) while
  `externalDatabase.port` was also `5432`, so keycloak tried to resolve `host:5432` as a
  host. Fixed the tpl to set the host to `split(":", keycloak_db_endpoint)[0]` (hostname
  only; port stays separate). **Committed (apply pending).** Likely next: the chart has no
  `externalDatabase.password`/`existingSecret` wired (DB auth may surface next), and the
  RDS security group must allow the cluster on 5432.
- **Caveats:** `bitnamilegacy` is unmaintained (no CVE patches) and `charts.bitnami.com/
  bitnami` with `targetRevision: "*"` is itself deprecated — this is a stopgap. The
  maintained path is the keycloakx addon (`gitops/infra/keycloak`, `keycloak-staging`);
  consider consolidating onto it and deleting `keycloak-helm`.

---

## Open items

- **api-gateway image** (#3) — publish/repin the missing `api-gateway` ECR tag.
- **Nodes finishing provisioning** (#7) — after the `ec2:CreateTags` apply the first `data`
  NodeClaim was launching; confirm it reaches `Registered` and ES/logstash/kibana + the
  microservice pods schedule. Revert the managed node group to `desiredSize=2` once
  Karpenter is carrying workloads (7e).
- **Infra applies** — `modules/iam/karpenter.tf` (`CreateTags`), `modules/iam/main.tf`
  (`ecr:ListImages`), `modules/k8s-and-helm/argo-keycloak.yaml.tpl` (bitnamilegacy): ensure
  all are applied via Atlantis.
- **otel dev-consumer cleanup** (#5 follow-up) — move the Kafka→Loki consumer out of the
  shared base `saas-chart/values.yaml` into `values-dev.yaml` so staging/prod don't inherit
  it (avoids the non-fatal loki export errors; no `null` overrides).
- **keycloak consolidation** (#9) — decide between the bitnamilegacy stopgap and migrating
  fully to the keycloakx `keycloak-staging`; delete the stray `keycloak-helm` if migrating.
- **dependabot guard** (#6) — add an ignore for `opentelemetry-api-incubator` in
  billing-service so it stays pinned to the Spring-managed SDK version.
