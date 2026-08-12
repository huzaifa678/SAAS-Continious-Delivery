# Usage ETL — Option B: Argo Workflows + KEDA (wiring guide)

This is the **alternative** way to run the usage-service ETL. The **active**
setup is Airflow with `KubernetesExecutor` ([`infra/base/airflow/`](infra/base/airflow/)).
The two are **mutually exclusive** — both consume `billing.usage-charge.created`
and write the same `usage_events` / `usage_aggregates` / pgvector, so running
both double-processes and corrupts aggregates. Enable exactly one.

Manifests live in [`infra/base/usage-etl-argo-keda/`](infra/base/usage-etl-argo-keda/)
and are **not referenced by any kustomization** until you follow this guide.

## Architecture

```
Kafka (billing.usage-charge.created)
        │
        ▼
  ingest  ── Deployment scaled by KEDA ScaledObject (Kafka consumer-lag,
        │    scale-to-zero) — streaming, runs etl.ingest continuously
        ▼
  usage_events (Postgres)
        │
        ▼
  Argo Workflows CronWorkflow  (*/5)   ── ordered DAG
        aggregate ──▶ embed
        (etl.aggregate)  (etl.embed → pgvector)
```

- **KEDA** does what it's best at: event-driven scaling of the streaming
  consumer, down to zero when there's no lag.
- **Argo Workflows** does what it's best at: the ordered `aggregate → embed`
  batch DAG with per-step retries — the dependency plain CronJobs can't express.

## Prerequisites

- **KEDA** — already installed as a cluster addon, now a flattened umbrella chart
  [`gitops/infra/keda`](gitops/infra/keda) delivered by the `addons` ApplicationSet.
- **Argo Workflows controller** — the `argoproj/argo-workflows` Helm chart
  (namespace `argo`). Not currently delivered; to enable it, add it as a
  flattened umbrella chart under `gitops/infra/argo-workflows` (mirroring the
  other addons) so the `addons` ApplicationSet picks it up. The legacy
  `infra/base/usage-etl-argo-keda/` manifests are unwired.
- **`usage_events` database** — the usage-service chart's `AppDatabase` claim
  (RDS `usage` instance). Ingest/aggregate/embed connect to it.
- **MSK** bootstrap brokers — from the Terraform GitOps contract
  (`kafka.bootstrap_brokers`; see `saas-services-infra/docs/gitops-contract.md`).
- **usage-service image** in ECR (the same image that carries `etl/` +
  `usage_common/`).

## Wiring steps

### 1. Turn Option A off, Option B on

Airflow (Option A) is now the flattened chart [`gitops/infra/airflow`](gitops/infra/airflow),
delivered by the `addons` ApplicationSet; the `infra` ApplicationSet's
[`infra/base/kustomization.yaml`](infra/base/kustomization.yaml) carries only raw
platform manifests (`pod-identity-refresh`). To switch to Option B:

- **Disable Airflow** — remove `gitops/infra/airflow/app.yaml` (so the `addons`
  matrix stops generating it), or gate it off per env.
- **Enable the Argo Workflows ETL** — wire the `usage-etl-argo-keda` manifests
  (namespace, `CronWorkflow`, `ingest.yaml`) into the `infra` overlays, and add
  the `argo-workflows` controller as a flattened chart (see Prerequisites).

Never run both Airflow and the Argo Workflows ETL in the same cluster.

### 2. Provide the `usage-etl-env` Secret

Both the ingest Deployment and the workflow steps read config via
`envFrom: secretRef: usage-etl-env` (namespace `usage-etl`). Keys mirror the
usage-service config:

```
DATABASE_URL=postgresql+psycopg2://usage_user:...@<usage-rds-endpoint>:5432/usage_db
KAFKA_BOOTSTRAP_SERVERS=<msk brokers>
SCHEMA_REGISTRY_URL=<schema registry>
OPENAI_API_KEY=<key>
EMBEDDING_MODEL=text-embedding-3-small
PGVECTOR_COLLECTION=usage_events
```

Preferred (no plaintext in git): an **ExternalSecret** sourcing these from
Secrets Manager — the DB creds are already there via the same convention the
`provider-sql` blocks use (`saas-usage-db-secret`).

### 3. KEDA authentication for MSK (ingest)

MSK is SASL/IAM. Add a `TriggerAuthentication` and reference it from the
ScaledObject in [`ingest.yaml`](infra/base/usage-etl-argo-keda/ingest.yaml), and
set `bootstrapServers` from the contract:

```yaml
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: kafka-msk
  namespace: usage-etl
spec:
  podIdentity:
    provider: aws            # IRSA / Pod Identity for the KEDA operator role
---
# in ingest.yaml, under triggers[0]:
      metadata:
        bootstrapServers: <kafka.bootstrap_brokers from the contract>
        sasl: aws_msk_iam
        tls: enable
      authenticationRef:
        name: kafka-msk
```

### 4. Image tag

`ingest.yaml` and `workflow.yaml` use `image: usage-service:latest` as a
placeholder. Pin the real ECR tag via an overlay `images:` patch or ArgoCD
Image Updater (same mechanism the services use).

### 5. Workflow RBAC

[`workflow.yaml`](infra/base/usage-etl-argo-keda/workflow.yaml) ships the
`usage-etl-workflow` ServiceAccount + Role/RoleBinding (create pods, write
`workflowtaskresults`) that Argo needs to run steps in the `usage-etl`
namespace. No extra action unless your Argo install expects a different SA.

## Verify

```bash
# controller up
kubectl -n argo get pods

# ingest scaling
kubectl -n usage-etl get scaledobject,deploy usage-ingest

# batch DAG
kubectl -n usage-etl get cronworkflow
argo -n usage-etl list
argo -n usage-etl get @latest        # watch aggregate -> embed

# data moving
psql "$DATABASE_URL" -c "select count(*) from usage_events;"
psql "$DATABASE_URL" -c "select count(*) from usage_aggregates;"
```

## Rollback to Airflow (A)

Revert step 1 (restore the `airflow/*` resources, remove
`usage-etl-argo-keda`). Optionally delete the `argo-workflows` Application —
Airflow needs no workflow engine.

## Variations

- **Full DAG in Argo** — if you'd rather not keep a streaming consumer, add
  `ingest` as the first task in the `CronWorkflow` DAG (`ingest → aggregate →
  embed`) and drop the KEDA ScaledObject + ingest Deployment. Simpler, but you
  reintroduce per-run consumer cold-starts and lose scale-on-lag.
- **Run history** — for workflow history beyond the controller's TTL, enable the
  Argo Workflows **archive** (a Postgres backend) in the controller Helm values.
