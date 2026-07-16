REPORTS_DIR ?= reports

.PHONY: test lint format test-vmaas test-caas test-storage test-bmaas

test:
	mkdir -p $(REPORTS_DIR)
	pytest tests/ -v $(if $(TEST),-k "$(TEST)") --junitxml=$(REPORTS_DIR)/results.xml

lint:
	ruff check tests/
	ruff format --check tests/

format:
	ruff format tests/

test-vmaas:
	mkdir -p $(REPORTS_DIR)
	pytest tests/vmaas/ -v $(if $(TEST),-k "$(TEST)") --junitxml=$(REPORTS_DIR)/vmaas.xml

test-caas:
	mkdir -p $(REPORTS_DIR)
	pytest tests/caas/ -v $(if $(TEST),-k "$(TEST)") --junitxml=$(REPORTS_DIR)/caas.xml

test-storage:
	mkdir -p $(REPORTS_DIR)
	pytest tests/storage/ -v $(if $(TEST),-k "$(TEST)") --junitxml=$(REPORTS_DIR)/storage.xml

test-bmaas:
	mkdir -p $(REPORTS_DIR)
	pytest tests/bmaas/ -v $(if $(TEST),-k "$(TEST)") --junitxml=$(REPORTS_DIR)/bmaas.xml

# ─── Infrastructure orchestration ───────────────────────────────────

INFRA       ?= netris
SUITE       ?= caas
EXTRA_VARS  ?=
INFRA_DIR    = infra/$(INFRA)

.PHONY: e2e setup-infra deploy-infra deploy-osac setup-suite run-tests \
        destroy-osac destroy-infra gather-infra redeploy-osac \
        _validate-backend _validate-suite-contract

_validate-backend:
	@if [ ! -f $(INFRA_DIR)/contract.mk ]; then \
		echo "ERROR: backend '$(INFRA)' not found at $(INFRA_DIR)/"; exit 1; \
	fi
	@. $(INFRA_DIR)/capabilities && \
		echo "$$SUPPORTED_SUITES" | tr ' ' '\n' | grep -qx "$(SUITE)" || \
		{ echo "ERROR: backend '$(INFRA)' does not support suite '$(SUITE)'"; \
		  echo "Supported: $$(. $(INFRA_DIR)/capabilities && echo $$SUPPORTED_SUITES)"; \
		  exit 1; }

_validate-suite-contract:
	@if [ ! -f $(INFRA_DIR)/.env.infra ]; then \
		echo "ERROR: $(INFRA_DIR)/.env.infra not found. Run 'make deploy-osac' first."; exit 1; \
	fi
	@if [ -f tests/$(SUITE)/contract ]; then \
		set -a && . $(INFRA_DIR)/.env.infra && set +a && \
		. tests/$(SUITE)/contract && \
		missing="" && \
		for var in $$REQUIRED_VARS; do \
			eval val="\$$$$var" && \
			if [ -z "$$val" ]; then missing="$$missing $$var"; fi; \
		done && \
		if [ -n "$$missing" ]; then \
			echo "ERROR: backend '$(INFRA)' missing required vars for suite '$(SUITE)':$$missing"; \
			exit 1; \
		fi; \
	fi

e2e: _validate-backend setup-infra deploy-infra deploy-osac setup-suite run-tests

setup-infra: _validate-backend
	$(MAKE) -C $(INFRA_DIR) -f contract.mk setup-infra EXTRA_VARS='$(EXTRA_VARS)'

deploy-infra: _validate-backend
	$(MAKE) -C $(INFRA_DIR) -f contract.mk deploy-infra EXTRA_VARS='$(EXTRA_VARS)'

deploy-osac: _validate-backend
	$(MAKE) -C $(INFRA_DIR) -f contract.mk deploy-osac EXTRA_VARS='$(EXTRA_VARS)'

setup-suite: _validate-backend
	$(MAKE) -C $(INFRA_DIR) -f contract.mk setup-$(SUITE) EXTRA_VARS='$(EXTRA_VARS)'

run-tests: _validate-suite-contract
	@set -a && . $(INFRA_DIR)/.env.infra && set +a && \
		$(MAKE) test-$(SUITE)

destroy-osac:
	$(MAKE) -C $(INFRA_DIR) -f contract.mk destroy-osac EXTRA_VARS='$(EXTRA_VARS)'

destroy-infra:
	$(MAKE) -C $(INFRA_DIR) -f contract.mk destroy-infra EXTRA_VARS='$(EXTRA_VARS)'

gather-infra:
	$(MAKE) -C $(INFRA_DIR) -f contract.mk gather-infra EXTRA_VARS='$(EXTRA_VARS)'

gather-suite:
	$(MAKE) -C $(INFRA_DIR) -f contract.mk gather-$(SUITE) EXTRA_VARS='$(EXTRA_VARS)'

redeploy-osac: destroy-osac deploy-osac
