#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
POLICY_DIR="policy/kubernetes"
SERVICES=(auth-service billing-service subscription-service usage-service)
ENVS=(dev staging prod)
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
FAILED=0

run_conftest() {
  local label="$1" file="$2"
  echo "── policy: ${label}"
  conftest test "${file}" -p "${POLICY_DIR}" || FAILED=1
}

for svc in "${SERVICES[@]}"; do
  for env in "${ENVS[@]}"; do
    out="${WORK}/${svc}-${env}.yaml"
    helm template t "charts/${svc}" \
      -f "charts/${svc}/values.yaml" \
      -f "charts/${svc}/values-${env}.yaml" > "${out}"
    run_conftest "helm ${svc}/${env}" "${out}"
  done
done

for env in "${ENVS[@]}"; do
  pr="${WORK}/pr-${env}"
  cp -r post-renderer/saas-chart "${pr}"
  helm template saas saas-chart \
    -f saas-chart/values.yaml \
    -f "saas-chart/values-${env}.yaml" > "${pr}/base/rendered.yaml"
  ( cd "${pr}/base" && kustomize edit add resource rendered.yaml )
  out="${WORK}/saas-chart-${env}.yaml"
  kustomize build "${pr}/overlays/${env}" > "${out}"
  run_conftest "helm+kustomize saas-chart/${env}" "${out}"
done

for env in "${ENVS[@]}"; do
  out="${WORK}/infra-${env}.yaml"
  kustomize build "infra/overlays/${env}" > "${out}"
  run_conftest "kustomize infra/overlays/${env}" "${out}"
done

# Cluster addons + observability stacks moved into GitOps (gitops/**), rendered
# per env by the `addons` / `observability` ApplicationSets. Every overlay dir
# (whatever its depth) is gated with the same policy set.
while IFS= read -r overlay; do
  label="${overlay#gitops/}"
  out="${WORK}/gitops-$(echo "${label}" | tr '/' '-').yaml"
  kustomize build "${overlay}" > "${out}"
  run_conftest "kustomize ${overlay}" "${out}"
done < <(find gitops -type d -path '*/overlays/*' -not -path '*/overlays' | sort)

if [[ "${FAILED}" -ne 0 ]]; then
  echo "policy-check: FAILED — one or more manifests violated a deny policy" >&2
  exit 1
fi
echo "policy-check: OK — no deny violations"
