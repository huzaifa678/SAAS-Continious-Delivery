.PHONY: help schema vet validate check-schema

help:
	@echo "Targets:"
	@echo "  schema        Regenerate per-chart values.schema.json from CUE."
	@echo "  vet           Strictly validate merged values (base+env) per service via cue vet."
	@echo "  validate      schema + vet + helm template (full pre-commit check)."
	@echo "  check-schema  Fail if generated values.schema.json is out of sync with CUE (CI gate)."

schema:
	@scripts/gen-values-schema.sh

vet:
	@scripts/vet-values.sh

validate: schema vet
	@for svc in auth-service billing-service subscription-service usage-service; do \
	  for env in dev staging prod; do \
	    helm template t charts/$$svc -f charts/$$svc/values.yaml -f charts/$$svc/values-$$env.yaml >/dev/null \
	      && echo "helm: $$svc/$$env OK" \
	      || { echo "helm: $$svc/$$env FAIL"; exit 1; }; \
	  done; \
	done

check-schema:
	@tmp=$$(mktemp -d); \
	for svc in auth-service billing-service subscription-service usage-service; do \
	  cp charts/$$svc/values.schema.json $$tmp/$$svc.json; \
	done; \
	scripts/gen-values-schema.sh >/dev/null; \
	for svc in auth-service billing-service subscription-service usage-service; do \
	  if ! diff -q $$tmp/$$svc.json charts/$$svc/values.schema.json >/dev/null; then \
	    echo "values.schema.json for $$svc is out of sync with schemas/service — run 'make schema'"; \
	    exit 1; \
	  fi; \
	done; \
	echo "all values.schema.json files in sync"
