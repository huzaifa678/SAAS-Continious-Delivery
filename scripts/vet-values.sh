#!/usr/bin/env bash
# Strictly validates each merged (base + env) values file against the CUE strict schema.
# Catches type errors, typos, out-of-range values, and conditional constraints
# (e.g. keda.enabled=true requires triggers) that values.schema.json can't express.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SERVICES=(auth-service billing-service subscription-service usage-service agent-service)
ENVS=(dev staging prod)

fail=0
for svc in "${SERVICES[@]}"; do
  for env in "${ENVS[@]}"; do
    if ! out=$(yq ea '. as $item ireduce ({}; . * $item)' \
        "charts/${svc}/values.yaml" "charts/${svc}/values-${env}.yaml" \
      | cue vet -d '#Values' ./schemas/service/strict yaml: - 2>&1); then
      echo "FAIL: ${svc}/${env}"
      echo "${out}" | sed 's/^/  /'
      fail=1
    else
      echo "OK:   ${svc}/${env}"
    fi
  done
done

exit "${fail}"
