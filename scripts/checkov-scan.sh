#!/usr/bin/env bash
# Renders every service chart per env into its real deploy namespace (saas-apps —
# the microservices ApplicationSet destination) and runs Checkov over the output.
# Rendering with the concrete namespace is what makes CKV_K8S_21 ("don't use the
# default namespace") deterministic, since Checkov reads metadata.namespace.
set -euo pipefail

cd "$(dirname "$0")/.."

SERVICES=(auth-service billing-service subscription-service usage-service agent-service)
ENVS=(dev staging prod)
NAMESPACE="saas-apps"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

for svc in "${SERVICES[@]}"; do
  for env in "${ENVS[@]}"; do
    helm template "${svc}" "charts/${svc}" \
      --namespace "${NAMESPACE}" \
      -f "charts/${svc}/values.yaml" \
      -f "charts/${svc}/values-${env}.yaml" \
      > "${WORK}/${svc}-${env}.yaml"
  done
done

checkov --directory "${WORK}" --framework kubernetes --compact "$@"
