.PHONY: setup-infra deploy-infra deploy-osac \
       setup-caas \
       destroy-osac destroy-infra \
       gather-infra gather-caas cleanup-dns

EXTRA_VARS ?=
ENV_INFRA := .env.infra

# --- Setup: installations and prerequisites ---

setup-infra:
	$(MAKE) -f Makefile setup EXTRA_VARS='$(EXTRA_VARS)'

# --- Deploy: netris lab ---

deploy-infra:
	$(MAKE) -f Makefile deploy-lab EXTRA_VARS='$(EXTRA_VARS)'

# --- Deploy: OCP + OSAC from snapshot ---

deploy-osac:
	$(MAKE) -f Makefile deploy-ocp-snapshot EXTRA_VARS='$(EXTRA_VARS)'
	@printf '%s\n' \
		'KUBECONFIG=/root/.kube/config' \
		'OSAC_NAMESPACE=$(or $(OSAC_NAMESPACE),osac-e2e-ci)' \
		'OSAC_VM_KUBECONFIG=/root/.kube/config' \
		'OSAC_PULL_SECRET_PATH=$(or $(OSAC_PULL_SECRET_PATH),/root/pull-secret)' \
		> $(ENV_INFRA)

# --- Suite setup ---

setup-caas:
	$(MAKE) -f Makefile setup-caas EXTRA_VARS='$(EXTRA_VARS)'

# --- Destroy ---

destroy-osac:
	$(MAKE) -f Makefile destroy-ocp EXTRA_VARS='$(EXTRA_VARS)'
	@rm -f $(ENV_INFRA)

destroy-infra:
	$(MAKE) -f Makefile destroy EXTRA_VARS='$(EXTRA_VARS)'
	@rm -f $(ENV_INFRA)

# --- Gather ---

gather-infra:
	$(MAKE) -f Makefile gather-lab EXTRA_VARS='$(EXTRA_VARS)'

gather-caas:
	$(MAKE) -f Makefile gather EXTRA_VARS='$(EXTRA_VARS)'
	$(MAKE) -f Makefile gather-caas EXTRA_VARS='$(EXTRA_VARS)'

cleanup-dns:
	$(MAKE) -f Makefile cleanup-dns EXTRA_VARS='$(EXTRA_VARS)'
