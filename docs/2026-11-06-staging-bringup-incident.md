# Staging bring-up incident — 2026-11-06

A sequential log of the control-plane / DB-tier / gateway / migration work done on the
`staging` (EKS `saas-eks-test`) environment, continuing directly from the 2026-11-05
writeup. That one restored the keystone (pod-to-pod traffic between the managed-NG and
Karpenter pools, `node_to_node_all`) which brought the Crossplane composition function
and the NGF gateways back; this session picks up from there — a malformed ApplicationSet
was throttling etcd and starving Karpenter, the gateways had public NLBs but the UIs
still timed out, Cilium's DNS proxy was refusing to resolve the RDS hostname so every DB
app saw "unknown host", the Crossplane `AppDatabase` connection secrets were the wrong
*shape* **and** provisioned in the wrong *order* so migration Jobs deadlocked, `airflow-db`
never appeared, and three services (auth/subscription/agent) had no migration path at
all. Entries are roughly in the order they were encountered. Fixes are tagged **[CD repo]**
(this repo), **[infra]** (`saas-services-infra`, Terraform), **[service]** (an individual
microservice repo), or **[operational]** (a one-off cluster/AWS action). Follows the
2026-11-05 incident format.

Starting state: the cluster was **torn down** partway through, so the later entries are
"make the config correct for the next provision" rather than live hot-patches — validated
by `helm template` / `terraform` render / `go test`, not yet by a running cluster.

## Cross-cutting root causes

Almost every failure in this session traces to a handful of themes:

1. **One malformed ApplicationSet entry can degrade the whole control plane.** A duplicate
   generated Application name put the ApplicationSet controller into a tight
   validation-error reconcile loop whose status writes throttled **etcd**
   (`ResourceExhausted: too many requests`) across *all* appsets — which starved the API
   server that Karpenter depends on to create nodes/pods (#1).
2. **Cilium default-deny egress needs the DNS proxy to *see* the name before the FQDN rule
   can allow the IP.** A too-narrow DNS-visibility `matchPattern` refused resolution of the
   multi-label RDS hostname, so every DB app (and its migrate Job) got "unknown host" even
   though the `toFQDNs` egress rule for `*.rds.amazonaws.com` was present (#5). This is the
   "lack of Cilium hardening" theme — the FQDN policy was right but the DNS-visibility half
   was missing.
3. **The `function-appdatabase` connection secret didn't match its own contract.** The XRD
   advertises `connectionSecretKeys: [username, password, host, port, database, dsn]`, but
   the Go function only wrote `username/password/host/database`. Every consumer that
   trusted the contract broke: billing read a non-existent `/etc/database/port`, usage had
   a `secretKeyRef` to a missing `port` key, and airflow required a single `dsn` key that
   was never emitted (#7, #8, #9).
4. **ArgoCD marks a just-applied custom resource Healthy instantly, and PreSync runs before
   the sync phase.** So a consumer raced ahead of the thing it depended on. This recurred
   three ways: the migrate hook ran as `PreSync` *before* its sync-phase `AppDatabase`
   claim (secret never existed → deadlock, #6); the Job ran before its own ServiceAccount
   (#6); and the new migration Jobs vs their ExternalSecrets (#12). The durable fix each
   time is an explicit sync-wave plus a Lua health check that holds the wave.
5. **"External" NLBs are only half-managed by the load-balancer controller.** Instance
   targets keep client-IP preservation on (default) and leave backend-SG wiring to a
   reconcile that is flaky under Karpenter SG discovery — so a *public* NLB with a *correct*
   DNS record still can't deliver packets to the NodePort (#3/#4).

---

## 1. Duplicate `otel-collector` Application name → etcd throttle → Karpenter starved (the keystone)

- **Symptom:** the `observability` ApplicationSet was `ErrorOccurred` —
  `ApplicationSet observability contains applications with duplicate name:
  otel-collector-staging` — and the argocd-applicationset-controller logs filled with
  `rpc error: code = ResourceExhausted desc = etcdserver: throttle: too many requests`
  against the `observability`, `microservices` **and** `addons` appsets at once. Karpenter
  was not getting nodes/pods created.
- **Root cause (a livelock, not a lock deadlock):** the observability appset generated
  Application names with `{{.path.basename}}-{{.metadata.labels.env}}`, and there are
  **two** `otel-collector` directories — `gitops/observability/elk/otel-collector` and
  `gitops/observability/grafana/otel-collector` — so both rendered the same name,
  `otel-collector-staging`. The chain:
  - The appset controller validates the generated set, rejects the duplicate name, and
    writes an `ErrorOccurred` condition to the ApplicationSet `.status` — a **permanent**,
    deterministic error (the same two dirs render the same name every pass), so it never
    self-clears the way a transient CRD-not-registered-yet error does.
  - `.status` is a subresource but still a real write (controller → apiserver → **etcd**),
    and etcd is MVCC+Raft: each accepted write is a new revision committed via a quorum
    proposal + WAL fsync — not a cheap touch.
  - The loop stays *hot* rather than backing off: the controller **watches** its own
    ApplicationSet and the child Applications, so each status write is itself a change
    event that re-enqueues the appset as a **fresh** work item, bypassing controller-runtime's
    per-item exponential backoff. `observability`, `microservices` and `addons` were all
    churning at once, on top of the application-controller already rewriting status for
    dozens of `OutOfSync/Degraded` apps.
  - etcd sheds load by **rejecting** writes (`etcdserver: too many requests`) once in-flight
    proposals exceed its limit. The rejection doesn't calm the loop — it **feeds** it: a
    throttled status write is *itself* an error, which returns from `Reconcile()` and
    triggers another requeue → another write attempt. So two failure sources (permanent
    duplicate name + throttled write) both spin the loop, and every attempt — whether it
    lands a revision or gets rejected — still consumes an apiserver→etcd request slot. It's
    the **attempt rate**, not "every failure persisting," that saturates etcd.
  - Because etcd is the whole control plane's single backing store, that saturation rejects
    writes **indiscriminately**: Karpenter provisions capacity by writing `NodeClaim`s and
    updating node state through the same apiserver→etcd path, so its writes got rejected/
    delayed and **no nodes/pods were created**. One cosmetic naming collision in one appset
    livelocked a controller and degraded cluster-wide scheduling.
- **Fix [CD repo]:** `appsets/observability.yaml` — name Applications
  `{{ default .path.basename .appName }}-{{.metadata.labels.env}}`, and give each collider
  an explicit `appName` in its `app.yaml` (`otel-collector-elk`, `otel-collector-grafana`).
  Removing the *permanent* validation error is what breaks the livelock: reconcile now
  succeeds, the loop goes quiet, the write rate drops to baseline, and etcd recovers — so
  Karpenter's writes get through again. **Committed** (`85fce0b`).

## 2. Hardcoded `nlbTarget` + unmanaged NLB cleanup — gateway target rework

- **Symptom:** each gateway chart (argocd/keycloak/backstage/grafana) hardcoded its NLB
  hostname in the CD repo as an `external-dns` target annotation, which has to be
  hand-updated every re-provision; and `teardown.sh` left the NGF-created NLBs and their
  security groups behind on destroy (NGF recreates the LB Service faster than the sweep
  deletes it).
- **Root cause:** DNS was being published *from* the Gateway via a manually-copied LB
  hostname instead of being *discovered* from the Service the LB controller creates; and
  teardown deleted LB Services without first stopping the NGF control plane that owns them.
- **Fix [CD repo]:** drop the `nlbTarget` block from all four `gitops/**/gateway.yaml`
  charts; add `service` to `gitops/infra/external-dns/values.yaml` `sources` so external-dns
  reads the NLB hostname from the Service `.status.loadBalancer`; annotate the HTTPRoute
  with `external-dns.alpha.kubernetes.io/controller: "none"` and the `nginx-gateway-lb`
  Service with `external-dns.alpha.kubernetes.io/hostname: <host>`. NGF is also told to
  provision internet-facing NLBs on the public subnets via
  `spec.infrastructure.annotations` (its own LB defaults internal). **Committed**
  (`be8fa4c`, `6e5999b`; earlier `769faff` moved to the `type: external` LB controller).
- **Fix [infra]:** `scripts/teardown.sh` — new step "1b" deletes all `Gateway`s and scales
  `app.kubernetes.io/name=nginx-gateway-fabric` deployments to 0 *before* the LB-service
  deletion, and step 5b's SG sweep loops over `elbv2.k8s.aws/cluster`,
  `service.k8s.aws/stack` and `ingress.k8s.aws/stack` tag keys. **Written** (`bash -n`
  clean).

## 3. Public NLB, correct DNS, UI still times out — preserve_client_ip + node SG

- **Symptom:** the gateway NLBs were internet-facing with public IPs and the domains
  resolved, but every UI hung and timed out. A sister repo (`Continious-delivery`) with the
  same NGF setup worked.
- **Root cause:** two compounding issues on the `external` + instance-target NLB.
  (a) `preserve_client_ip` defaults **on** for instance targets, so data packets arrive at
  the node carrying the *real client IP* — not matched by a VPC-CIDR-scoped node-SG rule.
  (b) the load-balancer controller's backend-SG auto-management is unreliable with
  Karpenter SG discovery, so nothing reliably opened the NodePort range to the NLB. The
  working sister repo used the **in-tree `nlb`** annotation, which auto-manages the node
  SG — the reason its UI worked.
- **Decision:** keep `aws-load-balancer-type: external` (don't revert to in-tree) and fix
  the node SG explicitly, so target management stays declarative and auditable.
- **Fix [CD repo]:** set
  `service.beta.kubernetes.io/aws-load-balancer-target-group-attributes:
  preserve_client_ip.enabled=false` on each `nginx-gateway-lb` Service. **Written.**
- **Fix [infra]:** `modules/node-security-group/main.tf` — new `nlb_nodeports` ingress rule
  allowing the VPC CIDR into the pinned gateway NodePort range; `variables.tf` adds
  `gateway_nodeport_min`/`max` (default 30100–30107, validated 30000–32767). **Written.**

## 4. Pin the gateway NodePorts — make the node-SG rule tight

- **Symptom:** the node-SG rule from #3 would otherwise have to open the whole ephemeral
  NodePort range because Kubernetes assigns gateway NodePorts dynamically.
- **Root cause:** nothing pinned the gateway Services' NodePorts.
- **Fix [CD repo]:** convert each gateway Service `ports` to block style with guarded,
  pinned `nodePort`s + a `nodePorts` values block — argocd `30100/30101`, keycloak
  `30102/30103`, backstage `30104/30105`, grafana `30106/30107` — matching the infra
  window. **Written.**

## 5. RDS is "unknown host" for every DB service — Cilium DNS-visibility too narrow

- **Symptom:** agent/auth/subscription/billing couldn't connect to Postgres; the app (and
  the migrate Jobs) failed resolving the RDS endpoint — effectively "unknown host" —
  despite healthy Cilium agents and a `toFQDNs` egress rule for `*.rds.amazonaws.com`.
- **Root cause:** Cilium egress is default-deny, and a `toFQDNs` rule only works if the
  **DNS proxy is first allowed to *see* (resolve) the name** via a DNS-visibility rule
  (`toEndpoints: kube-dns … toPorts:53 … rules.dns.matchPattern`). The chart defaulted that
  pattern to `*.amazonaws.com`, which Cilium **refused** for the multi-label RDS host
  (`<id>.<region>.rds.amazonaws.com`) — so the DNS query was blocked, the pod never learned
  an IP, and the FQDN egress rule had nothing to match. The FQDN policy was correct; the
  DNS-visibility half was under-hardened. (`charts/<svc>/templates/security.yaml` line ~117
  renders the DNS rule from `ciliumEgress.dnsMatchPatterns`.)
- **Fix [CD repo]:** `charts/{agent,auth,billing,subscription}-service/values-staging.yaml`
  — add `security.ciliumEgress.dnsMatchPatterns: ["*"]` (resolution only; actual egress
  stays restricted to the `rds`/`kafka`/`redis` `toFQDNs`), plus `rds: true` on the
  services that lacked it. **Committed** (`afaa7ed`). (Lineage: infra commits `a835f31`
  "Allow Cilium VXLAN/health between nodes" and `5b5bad8` "Disable VPC CNI network policy
  enforcement" hardened the node-level path earlier; this is the pod-level DNS half.)

## 6. AppDatabase claim/secret ordering deadlocks — the DB role is composed too late

The DB `Role` + `Database` + `Grant` (and the connection Secret) are **composed by
`function-appdatabase`** when the `AppDatabase` claim syncs — so anything that runs before
the claim finds no role and no secret. Three variants of this bit, all theme 4:

- **(a) Claim at a *later* wave than its consumer (airflow).** The airflow `AppDatabase`
  claim carried `sync-wave: "2"`, but the airflow workload is at wave `0` and mounts the
  `airflow-db` secret the claim writes. ArgoCD won't advance to wave `2` until wave `0` is
  Healthy — and wave `0` can't be Healthy without the secret wave `2` would create. The
  later wave therefore **never applies**: `airflow-db` is never created and the Role/Database
  are never provisioned. (Confirmed in-session: billing/usage's `<svc>-db` secrets *were*
  written, so provider-sql itself worked — airflow's were simply never requested.)
  **Fix [CD repo]:** `gitops/infra/airflow/templates/appdatabase.yaml` → claim
  `sync-wave: "-3"` (create the DB first). **Committed** (`7dd8d3e`).
- **(b) Migrate hook as PreSync, before the sync-phase claim (billing/usage).** The migrate
  Job was `argocd.argoproj.io/hook: PreSync` at wave `0`, but the claim is an ordinary
  **sync-phase** resource — PreSync runs entirely before the sync phase, so the secret could
  not exist when the hook ran → `CreateContainerConfigError`, hook never Healthy, whole sync
  parked. **Fix [CD repo]:** claim → `sync-wave: "-10"`; migrate ConfigMap/Job → **Sync**
  hook at wave `-6`/`-5` (after the claim, before the Rollout). **Committed** (`6e7bceb`).
- **(c) Job before its ServiceAccount.** The Job runs as the service SA, created at the
  default wave `0` — after the hook — so the Job failed "serviceaccount not found". **Fix
  [CD repo]:** SA → `sync-wave: "-6"`. **Committed** (`f7d54c5`; charts bumped
  `0.1.3 → 0.1.5`).

The durable guard for all three is #9's `AppDatabase` health check: once ArgoCD treats the
claim as Healthy only when Crossplane reports `Ready=True`, a consumer can't be scheduled
ahead of the role/secret regardless of wave arithmetic.

## 7. billing/usage migrate Jobs still fail — connection-secret shape mismatch

- **Symptom:** with ordering fixed (#6), the Jobs still couldn't start —
  `CreateContainerConfigError` — because they referenced secret keys that weren't there.
- **Root cause:** the secret-shape mismatch (theme 3). billing read
  `/etc/database/{port,db,user}` and usage had a `secretKeyRef` to key `port`, none of
  which the function wrote.
- **Fix [CD repo]:** first pass (`0.1.6`) pointed the templates at the keys the function
  *did* write (`database`/`username`/`host`/`password`) with a literal `5432` fallback —
  superseded by #9/#10 once the function itself was fixed. **Written.**

## 8. `airflow-db` secret not found — function never emits `dsn`, no health gate

- **Symptom:** airflow components wouldn't start (`CreateContainerConfigError`):
  `secret "airflow-db" does not exist`.
- **Root cause:** two layers. (a) airflow consumes a single
  `AIRFLOW__DATABASE__SQL_ALCHEMY_CONN` from secret key `dsn`, which the function never
  emitted (theme 3). (b) the `AppDatabase` claim is a custom resource ArgoCD marks Healthy
  instantly, so airflow (a later wave) started before Crossplane wrote `airflow-db` (theme
  4).
- **Fix:** see #9 (function emits `dsn`) and its ArgoCD `AppDatabase` health check.

## 9. Root fix — `function-appdatabase` emits the full connection secret + ArgoCD health gate

- **Symptom:** the keystone of #7/#8 — every AppDatabase consumer was coding around a
  secret that didn't satisfy the XRD's own `connectionSecretKeys`.
- **Root cause:** `functions/function-appdatabase/fn.go` mapped only
  `username/password/endpoint→host` from provider-sql's Role connection details, dropped
  `port`, and never synthesized the `dsn` the XRD advertises.
- **Fix [CD repo]:** `fn.go` now also maps `port`, defaults it to `5432` when provider-sql
  omits it, and builds a libpq/SQLAlchemy `dsn`
  (`postgresql://user:pass@host:port/db?sslmode=require`, URL-encoding credentials and
  handling a `host` that already carries `:port`). `go build` / `go vet` / `go test` pass.
  The image is rebuilt + Trivy-scanned by `.github/workflows/build-function.yml`, whose
  `bump-tag` job auto-updates `platform/functions/functions.yaml` on merge. **Written —
  needs merge so CI republishes the image and repins the tag.**
- **Fix [infra]:** `modules/k8s-and-helm/argocd-values.yaml` — add
  `resource.customizations.health.platform.saas.example_AppDatabase` (Lua, holds the
  sync-wave until `status.conditions[Ready]=True`). **Written — apply
  `live/test/50-addons-helm`.**

## 10. billing/usage consume the real secret `port` (drop the hardcoded 5432)

- **Root cause:** transitional — once the function emitted `port` (#9), the `0.1.6`
  literal-`5432` fallback was a second source of truth.
- **Fix [CD repo]:** `charts/billing-service/templates/db-migration.yaml` reads
  `DB_PORT="$(cat /etc/database/port 2>/dev/null || echo '5432')"` (Liquibase needs a
  `jdbc:` URL assembled from parts, so it can't take the raw `dsn`);
  `charts/usage-service/templates/db-migration.yaml` makes `POSTGRES_PORT` a `secretKeyRef`
  on `port`. Both bumped to `0.1.7`. **Written.** Safe because the platform app (functions,
  wave 0) upgrades the function before microservices (wave 2), and the #9 health gate holds
  the workload until the claim is Ready.

## 11. VPC flow logs cost — confirm the S3 path is the cheap one

- **Context:** flow logs had already been moved off CloudWatch Logs (VPC "ingestion" at
  `$0.50/GB` on *uncompressed* data — the expensive path) to S3 (infra `ddcd55e` "Move VPC
  flow logs to S3"); this was a cost sanity check, not a fix.
- **Findings [infra, no change]:** `layers/00-network/main.tf` delivers to S3
  (gzip, AES256) with a lifecycle `expiration` = per-env retention
  (`modules/guardrails/main.tf`: dev/test `14`, staging `90`, prod `365`), `traffic_type`
  `REJECT` on test and `ALL` on staging/prod, `max_aggregation_interval` at the module
  default `600s`, default v2 format. S3 vended-log delivery is ~`$0.25/GB` (≈half of
  CloudWatch) and storage bills on the gzipped size (~8–10× smaller) → roughly 2–2.5×
  cheaper; the REJECT-only test env is the biggest proportional win. Rough estimate pending
  real `BucketSizeBytes`: test ~$2–4/mo, staging ~$75–80/mo, prod ~$260–410/mo. **Optional
  follow-up:** an S3 lifecycle *transition* (Standard-IA or Glacier IR at ≥30 days) for
  prod's 365-day retention to cut that storage ~40–68%.

## 12. No migration path for auth / subscription / agent — add ArgoCD-native Jobs

- **Symptom:** auth, subscription and agent had no way to create their tables. auth
  (Prisma) and subscription (TypeORM) ship migrations inside their images but ran nothing;
  agent (Spring/JPA, `ddl-auto=validate`) ships **no** in-image migrator, so it fails
  validation against an empty DB. agent's chart had an `appdatabase.yaml` + Liquibase
  `db-migration.yaml`, but both were disabled and the Job was broken (read secret keys
  `db`/`user` the function never writes, a missing newline folded `exec liquibase update`
  into the URL env so Liquibase never ran, a `PreSync` hook that fired before its own
  ExternalSecret existed — the #6 bug again — and no secret volume mounted).
- **Root cause:** the three services connect with the **SM-synced app secret** (`<svc>`
  ExternalSecret, from `saas/<svc>` — `auth-service/main.tf` etc. in infra), not a
  Crossplane `AppDatabase` owner role. So a migration must run as that *same* identity, or
  tables end up owned by the wrong role (the AppDatabase pattern fits billing/usage/airflow
  because they *consume* that owner role; these three don't).
- **Fix [CD repo]:** a `templates/db-migration.yaml` per chart (Argo CD `Sync` hook,
  `BeforeHookCreation`, no-mesh-sidecar, locked-down `securityContext`), each reusing the
  **service image** (or the Liquibase image for agent) and connecting with the same
  ExternalSecret-synced Secret the app uses:
  - **auth** — `./node_modules/.bin/prisma migrate deploy` (`DATABASE_URL`).
  - **subscription** — `./node_modules/.bin/typeorm migration:run -d dist/data-source.js`
    (`POSTGRES_*`).
  - **agent** — Liquibase against the committed `migrations/changelog.sql`, URL/creds from
    `SPRING_DATASOURCE_URL/_USERNAME/_PASSWORD` (rewritten: real keys, `sslmode=require`
    appended, `Sync` hook, inline-script bug fixed). `appdatabase.yaml` stays off
    (`database.enabled: false`, `migrations.enabled: true`).

  Wave order per service: ExternalSecret `-3`, migrate Job `-2`, Rollout `0`. Each
  `values.yaml` gains a full `database` block; `Chart.yaml` → `0.1.4`. The repo-wide CUE
  `#Database` contract (`schemas/service/values.cue`, enforced by `make vet` and the
  `check-schema` CI gate that regenerates each `values.schema.json` from it) requires
  `enabled`/`instance`/`databaseName`/`owner` + the full `migrations` block on **every**
  service — so auth/subscription **conform** rather than fork the schema: `enabled: false`
  (no AppDatabase), `instance`/`databaseName`/`owner` recording the RDS mapping, and
  `migrations.image: ""` (the Job defaults to the service image) + a valid but inert
  `sslmode`. `make vet` passes 15/15, `make check-schema` clean, all three charts `helm
  template` clean. **Written.** (An earlier attempt hand-edited the generated
  `values.schema.json`; that drifts from CUE and fails `check-schema`, so it was reverted in
  favour of conforming the values.)
- **Fix [CD repo]:** `charts/auth-service/values.yaml` — add `ciliumEgress.rds: true` to the
  base values (staging already got it via #5, but the default lacked it). **Written.**
- **Fix [service]:** `auth-service` `prisma/schema.prisma` — add `url = env("DATABASE_URL")`
  to the datasource (the runtime image strips `npx` and omits `prisma.config.ts`, so
  `migrate deploy` needs the URL on the datasource). **Written — needs an auth-service image
  rebuild** (the schema is baked into the image the Job runs).
- **Fix [infra]:** `modules/k8s-and-helm/argocd-values.yaml` — add
  `resource.customizations.health.external-secrets.io_ExternalSecret` (Lua, holds the wave
  until `conditions[Ready]=True`). Without it the wave `-2` Job can start before ESO has
  written the wave `-3` Secret → the same `CreateContainerConfigError` as #7. **Written —
  apply `live/test/50-addons-helm`.**

## 13. agent pgvector — division of labour (not a gap) + explicit extension changeset

- **Question raised:** `changelog.sql` references `conversation_embeddings` (changeset 007,
  the FTS index) but never creates that table, and nothing ran `CREATE EXTENSION vector` —
  was the vector/RAG schema missing?
- **Finding:** by design, not a gap. `conversation_embeddings` is owned by **langchain4j**:
  `LangChain4jConfig.embeddingStore()` builds `PgVectorEmbeddingStore.builder()…
  .createTable(true)`, which creates the table (and the `vector` extension) at first use.
  `ddl-auto=validate` doesn't touch it because it's not a JPA entity. So the split is:
  Liquibase (migration, wave `-2`) creates the 7 JPA-backed relational tables that
  `validate` checks at boot; langchain4j (app, `@Lazy`) creates the vector table; and
  changeset 007 (`runAlways:true`, guarded on `to_regclass`) backfills the FTS GIN index on
  a later sync once the app has made the table. The index-missing window only affects sparse
  retrieval, not correctness.
- **Hardening [CD repo]:** the one implicit dependency was the `vector` **extension** —
  creating it needs an `rds_superuser`-capable role, and only the app did it. Added changeset
  `000-enable-pgvector` (`CREATE EXTENSION IF NOT EXISTS vector`) at the top of
  `charts/agent-service/migrations/changelog.sql`, so the migration (which runs as the RDS
  master user via `SPRING_DATASOURCE_*`) provisions it declaratively; langchain4j's own
  `CREATE EXTENSION IF NOT EXISTS` then no-ops. Table ownership stays with langchain4j (its
  schema, its version). Chart stays at `0.1.4`. **Written.**

---

## Open items

- **Merge/push the CD-repo changes** so CI republishes the OCI charts + function image:
  - `functions/function-appdatabase/fn.go` (#9) — merge triggers the image build +
    `functions.yaml` auto-bump.
  - gateway charts: `nlbTarget` removal, `external-dns` source, `preserve_client_ip`,
    pinned NodePorts (#2/#3/#4); `gitops/infra/external-dns/values.yaml`.
  - `charts/billing-service` + `charts/usage-service` `0.1.7` (#10).
  - `charts/{auth,subscription,agent}-service` `0.1.4` — new `db-migration.yaml`, full
    `database` values block, auth `ciliumEgress.rds`, agent `000-enable-pgvector`
    changeset (#12/#13). `values.schema.json` is generated from CUE — not hand-edited.
  - Already committed this session: `85fce0b` (#1), `afaa7ed` (#5), `6e7bceb`/`f7d54c5`
    (#6), and the gateway LB/external-dns commits (#2).
- **Rebuild + push the `auth-service` image** carrying the `schema.prisma` datasource url
  (#12). subscription/agent need no rebuild.
- **Apply infra:**
  - `live/test/50-addons-helm` — the `AppDatabase` + `ExternalSecret` ArgoCD health checks
    (#9/#12).
  - `live/test/10-platform` (or the relevant layer) — the `node-security-group` NodePort
    ingress rule (#3/#4).
  - `scripts/teardown.sh` is a destroy-path script (#2) — no apply, in place for next
    teardown.
- **Verify on the next provision:**
  - No duplicate-name errors on any ApplicationSet and no `etcdserver: throttle` in the
    applicationset-controller logs; Karpenter provisions nodes promptly (#1).
  - DB apps resolve and reach RDS with `dnsMatchPatterns: ["*"]` (#5).
  - `kubectl get secret airflow-db -n airflow -o jsonpath='{.data.dsn}' | base64 -d`
    populated; a billing/usage secret's `host` key format (host-only vs host:port — the
    `dsn` builder handles both) (#9).
  - The three new migration Jobs complete and the Rollouts start behind them (#12).
- **agent pgvector — resolved (#13):** confirmed by-design (langchain4j owns the vector
  table); added the explicit `000-enable-pgvector` extension changeset. Verify next
  provision: `CREATE EXTENSION vector` succeeds as the agent DB user (it's the RDS master,
  so it has the privilege) and `conversation_embeddings` + its FTS index appear after the
  app's first RAG call.
- **Optional:** prod S3 lifecycle transition for flow logs (#11).
