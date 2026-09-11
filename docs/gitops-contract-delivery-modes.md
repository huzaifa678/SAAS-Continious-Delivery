# GitOps contract delivery modes

The Terraform `gitops_contract` (see `saas-services-infra/docs/gitops-contract.md`)
is the single source of truth for cluster identity, the RDS instances, and which
Secrets Manager secret holds each one's master credentials. The **cluster-identity
values** (karpenter `clusterName`/queue, keycloak's external DB host) can reach the
cluster **two mutually-exclusive ways**. A per-environment toggle picks one; a guard
rail refuses to let both apply; a workflow performs the switch for you.

| | `render` (original) | `eso` (new) |
|---|---|---|
| Storage | SSM SecureString `/saas/<env>/gitops-contract` | Secrets Manager `saas/<env>/infra-contract` (+ existing per-DB secrets) |
| Delivery | `scripts/render_gitops.py` generates & commits `values-<env>.generated.yaml` | External Secrets materializes a Secret at runtime; charts read it via `values-<env>.eso.yaml` |
| Trigger | `render-gitops.yml` | ArgoCD sync (no CI render step for these values) |

## Scope: what the toggle governs (and what it doesn't)

Only values that a chart consumes as a **single scalar** move to `eso`, because a
runtime Secret can feed an env var but cannot be looped over at Helm-template time:

- **karpenter** `settings.clusterName` + `interruptionQueue` → `CLUSTER_NAME` /
  `INTERRUPTION_QUEUE` env from the `karpenter-contract` Secret.
- **keycloak** (prod) DB host → `KC_DB_URL_HOST` env from the `keycloak-contract` Secret.

**Not in the toggle:**

- **Crossplane `provider-sql`** is a *list* of per-instance manifests
  (`ExternalSecret` + `ProviderConfig`), whose enumeration is inherently
  author-time — a runtime Secret can't generate a variable number of manifests. It
  stays contract-generated (`infra/overlays/<env>/crossplane/provider-sql.yaml`) in
  **both** modes. Its DB credentials already reach the cluster through External
  Secrets regardless of mode, so nothing is lost.
- **`platform/functions/functions.yaml`** is owned by `build-function.yml` (rendered
  from the ECR login), not the contract.

`render-gitops.yml` therefore renders provider-sql (and functions) in both modes,
and renders the karpenter/keycloak `*.generated.yaml` only when the mode is `render`.

## The toggle

`contracts/delivery-mode.<env>` holds a single word, `render` or `eso`, per env
(`dev`, `staging`, `prod`). Default is `render`, so existing environments are
unchanged until deliberately flipped.

## Switching modes — automated

**Do not** hand-edit value files. Either run the workflow or the script.

- **Workflow (preferred):** run **Actions → switch-delivery-mode** with the target
  env + mode. It runs `set-delivery-mode.py`, regenerates the render values from the
  contract when switching back to `render`, re-validates the guard, and opens a PR.
- **Locally:** `scripts/set-delivery-mode.py --env <env> --mode <render|eso>`, then
  commit. (Switching to `render` locally leaves the `*.generated.yaml` to be
  re-created by the `render-gitops` workflow, which needs the contract from AWS.)

The script deterministically writes/removes the mode's value files and flips the
toggle, so the manual copy/delete steps are gone.

## How mutual exclusion is enforced

The addons `ApplicationSet` layers Helm value files with `ignoreMissingValueFiles: true`:

```yaml
valueFiles:
  - values.yaml
  - values-<env>.yaml
  - values-<env>.generated.yaml   # render mode only
  - values-<env>.eso.yaml         # eso mode only
```

A mode is expressed by *which file exists*. `scripts/check-delivery-mode.py`
(run by `.github/workflows/delivery-mode-guard.yml`) asserts, per env:

- **`render`**: no `values-<env>.eso.yaml` for karpenter/keycloak.
- **`eso`**: no `values-<env>.generated.yaml` for karpenter/keycloak, and the
  required `values-<env>.eso.yaml` files exist (karpenter for every env; keycloak
  for prod).

If both (or neither) mode's files are present for an env, the guard fails the build.

## Infra side

After the `20-data` apply, `saas-services-infra/.github/workflows/infra.yml`
dual-publishes: the full contract to SSM (render) **and** the identity slice to
Secrets Manager `saas/<env>/infra-contract` (eso). Master DB credentials stay in the
per-DB secrets. The ESO IAM role already allows `secretsmanager:GetSecretValue`, so
no IAM change is needed to adopt `eso`.
