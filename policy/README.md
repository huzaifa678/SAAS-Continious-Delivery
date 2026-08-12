# Policy as Code — `saas-continious-delivery`

Every Kubernetes manifest this repo ships is validated by [OPA/Rego](https://www.openpolicyagent.org/)
policies via [`conftest`](https://www.conftest.dev/) **before** Argo CD ever
syncs it. This complements the existing [CUE + `values.schema.json`](../README.md#values-validation-with-cue)
layer: CUE validates the *values* going into Helm; conftest validates the
*rendered Kubernetes objects* coming out of Helm **and** Kustomize.

```
values.yaml ──(CUE / values.schema.json)──▶ Helm ─┐
                                                   ├─▶ rendered manifests ──(conftest / Rego)──▶ Argo CD sync
infra overlays ─────────────────────────▶ Kustomize ┘
```

## Why render first, then test

The four microservices render as **`argoproj.io/Rollout`** objects (not
`Deployment`s), and the api-gateway plus every cluster addon are produced by
**Helm + a Kustomize post-renderer**. A policy set that inspected raw templates,
or only understood `Deployment`, would miss every workload. So
[`scripts/policy-check.sh`](../scripts/policy-check.sh) renders all paths exactly
as Argo CD does and pipes the result through conftest:

1. **Helm** — the four microservice charts (`charts/<svc>`, all envs).
2. **Helm + Kustomize post-render** — `saas-chart`/api-gateway, applying
   `post-renderer/saas-chart/overlays/<env>` the same way the Argo `Application`
   does (helm output injected as a Kustomize resource, then the env overlay
   patched on top).
3. **Helm + Kustomize post-render — every `gitops/**` addon.** Each flattened
   addon (`gitops/infra/<addon>`, `gitops/observability/<stack>/<comp>`) is a
   local umbrella chart rendered per env, then post-rendered by
   `post-renderer/<same path>/overlays/<env>` (which also applies the genuine
   per-env patches — resource tiers, prod HA replicas, LB scheme).
4. **Kustomize (raw)** — the `infra/overlays/<env>` platform manifests
   (crossplane `provider-sql`, `pod-identity-refresh`).

This is also *why* Helm, the post-renderer, and Kustomize all remain first-class
after the move to ApplicationSets — the policy gate covers, and the render paths
still exercise, every one of them. Note the security `deny` for host access is
waived per-workload via the `policy.saas.io/allow-host-access` annotation (added
by the post-renderer) for sanctioned node agents — see `security.rego`.

## The policy set

Rules live in [`policy/kubernetes/`](kubernetes/), all in `package main`:

- **[`security.rego`](kubernetes/security.rego)** — `deny` (blocking). Privileged
  containers, host namespaces (`hostNetwork/PID/IPC`), `hostPath` volumes, running
  as `runAsUser: 0`, dangerous added capabilities (`NET_RAW`, `SYS_ADMIN`, `ALL`…).
  Unambiguous container-escape risks — enforced hard.
- **[`governance.rego`](kubernetes/governance.rego)** — `warn` (advisory). Mutable
  `:latest`/untagged images, un-approved registries, missing
  `resources.requests`/`limits`, `runAsNonRoot`/`readOnlyRootFilesystem`/
  `allowPrivilegeEscalation` hardening, missing liveness/readiness probes.
- **[`lib.rego`](kubernetes/lib.rego)** — pod-workload helpers (Rollout-aware).
- **[`policy_test.rego`](kubernetes/policy_test.rego)** — unit tests (`conftest verify`).

The `warn` tier intentionally fires on the charts today (e.g. base values ship
`image.tag: latest` as a placeholder) — it surfaces genuine production-readiness
gaps without red-lighting CI. `deny` rules are calibrated so a compliant manifest
stays green while a real regression (someone adds `privileged: true`) fails fast.

## Run it locally

```bash
make policy-test   # conftest verify — unit-test the Rego rules (hermetic)
make policy        # render helm + kustomize (all svc/env) and conftest test
```

Both require `helm`, `kustomize`, and `conftest` on `PATH`. CI runs the same
`scripts/policy-check.sh` in [`.github/workflows/policy-check.yml`](../.github/workflows/policy-check.yml).

## Handling a violation

- **`deny`** — fix the chart/manifest. A legitimate exception must be encoded as
  an explicit, commented carve-out in `policy/kubernetes/` — never by muting the
  whole rule.
- **`warn`** — address it or note it in the PR; it won't block the merge.
