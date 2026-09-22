.PHONY: help schema vet validate check-schema check-composition composition policy policy-test

COMPOSITION_GEN := scripts/gen/appdatabase-composition
COMPOSITION_OUT := platform/compositions/appdatabase-postgres.yaml

APPCACHE_GEN := scripts/gen/appcache-composition
APPCACHE_OUT := platform/compositions/appcache.yaml

help:
	@echo "Targets:"
	@echo "  schema             Regenerate per-chart values.schema.json from CUE."
	@echo "  vet                Strictly validate merged values (base+env) per service via cue vet."
	@echo "  validate           schema + vet + helm template (full pre-commit check)."
	@echo "  check-schema       Fail if generated values.schema.json is out of sync with CUE (CI gate)."
	@echo "  composition        Regenerate the XAppDatabase Crossplane Composition (Go pipeline generator)."
	@echo "  check-composition  Fail if the checked-in Composition is out of sync with the generator (CI gate)."
	@echo "  policy-test        conftest verify — unit-test the Rego policy set (hermetic)."
	@echo "  policy             Render helm + kustomize (all svc/env) and run conftest/OPA."

policy-test:
	@conftest verify -p policy/kubernetes

policy:
	@scripts/policy-check.sh

schema:
	@scripts/gen-values-schema.sh

composition:
	@cd $(COMPOSITION_GEN) && go run . -out $(CURDIR)/$(COMPOSITION_OUT)
	@cd $(APPCACHE_GEN) && go run . -out $(CURDIR)/$(APPCACHE_OUT)

check-composition:
	@fail=0; \
	for f in $(COMPOSITION_OUT) $(APPCACHE_OUT); do \
	  cp $$f $$f.bak; \
	done; \
	cd $(COMPOSITION_GEN) && go run . -out $(CURDIR)/$(COMPOSITION_OUT) >/dev/null; \
	cd $(CURDIR); \
	cd $(APPCACHE_GEN) && go run . -out $(CURDIR)/$(APPCACHE_OUT) >/dev/null; \
	cd $(CURDIR); \
	for f in $(COMPOSITION_OUT) $(APPCACHE_OUT); do \
	  if ! diff -q $$f.bak $$f >/dev/null; then \
	    echo "$$f is out of sync with its generator — run 'make composition'"; \
	    mv $$f.bak $$f; \
	    fail=1; \
	  else \
	    rm -f $$f.bak; \
	  fi; \
	done; \
	if [ $$fail -ne 0 ]; then exit 1; fi; \
	echo "compositions in sync with generators"

vet:
	@scripts/vet-values.sh

validate: schema vet
	@for svc in auth-service billing-service subscription-service usage-service agent-service; do \
	  for env in dev staging prod; do \
	    helm template t charts/$$svc -f charts/$$svc/values.yaml -f charts/$$svc/values-$$env.yaml >/dev/null \
	      && echo "helm: $$svc/$$env OK" \
	      || { echo "helm: $$svc/$$env FAIL"; exit 1; }; \
	  done; \
	done

check-schema:
	@tmp=$$(mktemp -d); \
	for svc in auth-service billing-service subscription-service usage-service agent-service; do \
	  cp charts/$$svc/values.schema.json $$tmp/$$svc.json; \
	done; \
	scripts/gen-values-schema.sh >/dev/null; \
	for svc in auth-service billing-service subscription-service usage-service agent-service; do \
	  if ! diff -q $$tmp/$$svc.json charts/$$svc/values.schema.json >/dev/null; then \
	    echo "values.schema.json for $$svc is out of sync with schemas/service — run 'make schema'"; \
	    exit 1; \
	  fi; \
	done; \
	echo "all values.schema.json files in sync"
