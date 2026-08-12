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

# Every gitops/** addon (infra + observability) is a local umbrella Helm chart
# rendered per env, then Kustomize post-rendered — the same helm+kustomize path as
# saas-chart, matching how the flattened addons/observability ApplicationSets apply
# them. Each chart's post-renderer overlays declare which envs it targets.
while IFS= read -r chart; do
  dir="$(dirname "${chart}")"           # gitops/infra/<addon> | gitops/observability/<stack>/<comp>
  rel="${dir#gitops/}"
  addon="$(basename "${dir}")"
  ns="$(awk '/^namespace:/{print $2}' "${dir}/app.yaml")"
  prbase="post-renderer/${rel}"
  for ov in "${prbase}"/overlays/*/; do
    [[ -d "${ov}" ]] || continue
    env="$(basename "${ov}")"
    tag="${rel//\//-}-${env}"
    pr="${WORK}/gitops-${tag}"
    cp -r "${prbase}" "${pr}"
    vfs=(-f "${dir}/values.yaml")
    [[ -f "${dir}/values-${env}.yaml" ]] && vfs+=(-f "${dir}/values-${env}.yaml")
    [[ -f "${dir}/values-${env}.generated.yaml" ]] && vfs+=(-f "${dir}/values-${env}.generated.yaml")
    helm template "${addon}" "${dir}" "${vfs[@]}" --namespace "${ns}" --include-crds \
      > "${pr}/base/rendered.yaml"
    ( cd "${pr}/base" && kustomize edit add resource rendered.yaml )
    out="${WORK}/gitops-${tag}.yaml"
    kustomize build "${pr}/overlays/${env}" > "${out}"
    run_conftest "helm+kustomize ${rel}/${env}" "${out}"
  done
done < <(find gitops -name Chart.yaml | sort)

if [[ "${FAILED}" -ne 0 ]]; then
  echo "policy-check: FAILED — one or more manifests violated a deny policy" >&2
  exit 1
fi
echo "policy-check: OK — no deny violations"
