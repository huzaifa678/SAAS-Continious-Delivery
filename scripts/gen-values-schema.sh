#!/usr/bin/env bash
# Generates values.schema.json for each service chart from the shared CUE schema.
# Helm validates these natively on install/template/upgrade, so ArgoCD also enforces them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SERVICES=(auth-service billing-service subscription-service usage-service)

for svc in "${SERVICES[@]}"; do
  out="charts/${svc}/values.schema.json"
  cue def --out openapi ./schemas/service \
    | jq '
        def fix:
          walk(
            if type=="object" then
              (if has("$ref") then {"$ref": (.["$ref"] | sub("#/components/schemas/"; "#/$defs/"))} else . end)
              | (if .exclusiveMinimum == true and (.minimum|type=="number") then .exclusiveMinimum = .minimum | del(.minimum) else . end)
              | (if .exclusiveMaximum == true and (.maximum|type=="number") then .exclusiveMaximum = .maximum | del(.maximum) else . end)
              | (if .exclusiveMinimum == false then del(.exclusiveMinimum) else . end)
              | (if .exclusiveMaximum == false then del(.exclusiveMaximum) else . end)
              | (if (.type=="object") and (has("properties")) and (has("additionalProperties")|not) then .additionalProperties = false else . end)
            else . end
          );
        {
          "$schema": "https://json-schema.org/draft-07/schema",
          "title": "'"${svc}"' values",
          "$defs": (.components.schemas | with_entries(.value |= fix)),
          "allOf": [{"$ref": "#/$defs/Values"}]
        }' > "$out"
  echo "wrote $out"
done
