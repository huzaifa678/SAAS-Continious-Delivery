# Image delivery — registry & Argo CD Image Updater

## Registry: ECR, immutable `sha-*` tags (best practice)

Every service builds in its own repo's `*-ci.yml`, then **pushes to ECR** (not
Docker Hub): private, KMS-encrypted, scan-on-push, and `IMMUTABLE` tags (see
`ecr.tf` in `saas-services-infra`). Each build is tagged `sha-<git-sha>` — a
unique, immutable coordinate. That immutability is what makes automated image
updates safe: a tag can never be silently repointed at different bits.

> "docker push or ecr push?" — they're the same command (`docker push` to an ECR
> host); the point is the **registry**. Use ECR for every environment. Keep the
> immutable `sha-<git-sha>` scheme; do not deploy mutable `:latest`/`:dev`.

## What changed: bot commits → Image Updater

Before, each `*-ci.yml` ended by cloning this repo and committing the new tag
into `values-dev.yaml` (a "bot commit"). That step is **removed**. Instead,
[Argo CD Image Updater](https://argocd-image-updater.readthedocs.io/) watches ECR
and performs the tag bump itself, via **git write-back** (it commits to this
repo), so Git stays the single source of truth and Argo CD syncs as usual.

```
CI: build ──▶ Trivy scan ──▶ push  <ecr>/<svc>:sha-<sha>   (no values edit)
                                        │
Image Updater (in-cluster) ── polls ECR ┘
   dev             : newest sha-* ─▶ commit to main ─▶ Argo syncs      (continuous)
   staging / prod  : (excluded) ─▶ explicit promotion PR ─▶ Argo syncs (gated)
```

## Per-environment strategy

| Env | Strategy | Write-back | Rationale |
|---|---|---|---|
| **dev** | `newest-build` of `sha-*` | commit to `main` | Continuous deploy; every green build lands in dev automatically. |
| **staging** | **not** auto-tracked | explicit promotion | Soak a specific `sha-*` deliberately; don't let staging drift under it. |
| **prod** | **not** auto-tracked | explicit promotion | Auto-updating prod from the registry on every build is an anti-pattern — prod changes must be a deliberate, reviewable act. |

The Image Updater annotations are applied through each ApplicationSet's
`spec.templatePatch`
([`appsets/microservices.yaml`](../appsets/microservices.yaml),
[`appsets/api-gateway.yaml`](../appsets/api-gateway.yaml)), gated on
`{{ if eq .metadata.labels.env "dev" }}`. The patch merges onto the generated
Application **only for the dev-labelled cluster**, so the annotation block is
entirely absent on staging and prod — nothing for Image Updater to act on there.

### Promoting to prod

Staging and prod stay on the existing explicit path: a PR that updates
`charts/<svc>/values-<env>.yaml` (or `saas-chart/values-<env>.yaml`) to the exact
`sha-*` you're promoting, reviewed and merged like any change. If you would
rather Image Updater *open* that PR for you, widen the `templatePatch` guard
(e.g. `ne .metadata.labels.env "prod"`) and set `git-branch` to a PR branch
(`main:argocd-image-updater/<svc>`) — you get a promotion PR per build to
approve. Cleaner still is to add **semver release tags** (`vX.Y.Z`) in CI and
point prod at a `semver` constraint; that decouples prod cadence from every dev
build.

> ⚠️ The current prod CD workflows (`*-cd.yml`) retag `sha → prod` with
> `aws ecr put-image --image-tag prod`. Because the ECR repos are `IMMUTABLE`,
> re-tagging `prod` a second time will **fail** (the tag already exists).
> Prefer referencing the immutable `sha-*` tag in `values-prod.yaml` directly
> (which the Image-Updater-PR or a manual PR does) over a mutable `:prod` tag.

## Cluster setup (prerequisites)

The addon is installed per cluster via
[`infra/base/argocd-image-updater/`](../infra/base/argocd-image-updater/)
(referenced from each env overlay). Before it can update anything:

1. **ECR read access** — the `argocd-image-updater` ServiceAccount needs IRSA
   with `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`,
   `ecr:GetDownloadUrlForLayer`, `ecr:DescribeImages`. Set the role ARN in the
   addon's `serviceAccount.annotations`. The bundled `ecr-login.sh` auth script
   exchanges that for a registry token every `credsexpire`.
2. **Git write-back creds** — a secret `image-updater-git-creds` in `argocd`
   holding a token/deploy key with **write** access to this repo, referenced by
   `write-back-method: git:secret:argocd/image-updater-git-creds`. Give it the
   minimum: push to `main` (and, if you enable prod PRs, to the PR branches).
3. Confirm with `kubectl -n argocd logs deploy/argocd-image-updater` that it
   authenticates to ECR and detects the applications.

Until (1) and (2) are in place, **dev will not receive new images** (the
CI bot that used to do it is gone) — so complete this setup as part of the
cut-over.
