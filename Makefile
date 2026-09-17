# freshehr-open-health-stack — one entrypoint for all three IaC layers.
# Run `make help` for the list.

SHELL := /bin/bash
DOCKER_DIR := docker
CHART := charts/health-stack
NS := health-stack

# Which chart values file to use for the helm targets (hetzner|scaleway|dev).
ENV ?= hetzner
# The terraform-* targets below only drive Hetzner; terraform/envs/scaleway
# exists but has no Makefile wiring yet — run terraform directly in that dir.
TF_ENV := terraform/envs/hetzner

# GHCR namespace + tag for the three custom images (see `make images`).
IMAGE_ORG ?= ghcr.io/freshehrteam
IMAGE_TAG ?= latest

# Extra args for `docker compose`.
PROFILE ?=
# An explicit -f disables compose's automatic override merging, so include the
# dev override ourselves when it exists (rename it to .disabled to run
# prod-like — same contract as running `docker compose` from docker/ directly).
OVERRIDE := $(wildcard $(DOCKER_DIR)/docker-compose.override.yml)
COMPOSE := docker compose -f $(DOCKER_DIR)/docker-compose.yml $(if $(OVERRIDE),-f $(OVERRIDE)) $(PROFILE)

.DEFAULT_GOAL := help

## ── Layer 1: docker-compose ──────────────────────────────────────────────────

.PHONY: env
env: ## Create docker/.env from .env.example if missing
	@test -f $(DOCKER_DIR)/.env || (cp .env.example $(DOCKER_DIR)/.env && echo "Created $(DOCKER_DIR)/.env — edit it before `make up`.")

.PHONY: certs
certs: ## Generate self-signed dev TLS certs for the compose nginx
	@mkdir -p $(DOCKER_DIR)/nginx/certs
	openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
		-keyout $(DOCKER_DIR)/nginx/certs/tls.key \
		-out    $(DOCKER_DIR)/nginx/certs/tls.crt \
		-subj   "/CN=localhost" \
		-addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
	@echo "Wrote $(DOCKER_DIR)/nginx/certs/tls.{crt,key}"

.PHONY: build
build: ## Build the custom images: hapi (fetches the interceptor JAR) + hades (fetches the upstream JAR)
	$(COMPOSE) build hapi hades

.PHONY: up
up: env certs ## Bring up the whole compose stack (8 services)
	$(COMPOSE) up -d

.PHONY: down
down: ## Stop the compose stack (keeps volumes)
	$(COMPOSE) down

.PHONY: destroy
destroy: ## Stop the compose stack AND delete volumes (data loss)
	$(COMPOSE) down -v

.PHONY: ps
ps: ## Show compose service status
	$(COMPOSE) ps

.PHONY: logs
logs: ## Tail logs from all compose services
	$(COMPOSE) logs -f --tail=100

.PHONY: config
config: ## Validate + render the merged compose config
	$(COMPOSE) config

.PHONY: images
images: ## Build all three custom images (IMAGE_ORG/IMAGE_TAG override the defaults)
	@# hapi-openfhir fetches the interceptor JAR at build time from the pinned
	@# GitHub release asset (Dockerfile ARG INTERCEPTOR_VERSION); nothing to stage.
	docker build -t $(IMAGE_ORG)/hapi-openfhir:$(IMAGE_TAG) $(DOCKER_DIR)/hapi
	docker build -f $(DOCKER_DIR)/openfhir/bootstrap.Dockerfile -t $(IMAGE_ORG)/fhirconnect-eps-mappings:$(IMAGE_TAG) $(DOCKER_DIR)/openfhir
	@# hades: the upstream JAR version is pinned by the Dockerfile's ARG
	@# HADES_VERSION/HADES_SHA256; IMAGE_TAG stays the team's release tag.
	docker build -t $(IMAGE_ORG)/hades:$(IMAGE_TAG) $(DOCKER_DIR)/hades
	@echo "Built: $(IMAGE_ORG)/hapi-openfhir:$(IMAGE_TAG)  $(IMAGE_ORG)/fhirconnect-eps-mappings:$(IMAGE_TAG)  $(IMAGE_ORG)/hades:$(IMAGE_TAG)"

.PHONY: images-push
images-push: images ## Build then push the custom images to GHCR (needs `docker login ghcr.io` with a PAT that has write:packages)
	docker push $(IMAGE_ORG)/hapi-openfhir:$(IMAGE_TAG)
	docker push $(IMAGE_ORG)/fhirconnect-eps-mappings:$(IMAGE_TAG)
	docker push $(IMAGE_ORG)/hades:$(IMAGE_TAG)

.PHONY: token
token: ## Print a Bearer access token from Keycloak (client_credentials, api-client)
	@# sed extraction, not jq: keep the Makefile free of extra host dependencies.
	@#
	@# The openFHIR per-API scopes are OPTIONAL client scopes (attaching custom
	@# scopes as defaults at realm-import time detaches the built-ins and the
	@# token loses realm_access.roles — the EHRbase USER role), so they must be
	@# requested explicitly via scope=. Requesting them costs nothing for the
	@# EHRbase/HAPI routes, which ignore the scope claim.
	@curl -sS -X POST http://localhost:8081/auth/realms/freshehr/protocol/openid-connect/token \
		-d grant_type=client_credentials \
		-d client_id=$${KC_API_CLIENT_ID:-api-client} \
		-d client_secret=$${KC_API_CLIENT_SECRET:-dev-api-client-secret} \
		--data-urlencode "scope=$${KC_TOKEN_SCOPES:-opt.c opt.r opt.u opt.d fc.c fc.r fc.u fc.d conceptmap.c conceptmap.r conceptmap.u conceptmap.d openfhir.map openfhir.insights}" \
	| sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'

.PHONY: template
template: ## Upload every operational template (OPT) in the bootstrap dir into EHRbase (required once per fresh CDR)
	@# openFHIR bootstraps the OPTs into its own store, but EHRbase needs them too —
	@# without them a composition store fails with 422 "Could not retrieve template
	@# for template Id: <id>". Idempotent: re-uploading an existing template
	@# returns 409, which is fine.
	@#
	@# Loops over the directory rather than naming one file: docker/openfhir/bootstrap
	@# is the single source of truth feeding openFHIR, EHRbase and the UI, and it now
	@# carries more than one template. Adding an OPT there must not also require
	@# editing this target.
	@#
	@# Routed through nginx (https, -k: self-signed dev cert) with a Bearer token —
	@# EHRbase runs as an OAuth2 resource server (SECURITY_AUTHTYPE=OAUTH).
	@TOKEN=$$($(MAKE) --no-print-directory token); \
	[ -n "$$TOKEN" ] || { echo "ERROR: could not fetch a token from Keycloak (is the stack up?)"; exit 1; }; \
	found=0; \
	for opt in "$(DOCKER_DIR)"/openfhir/bootstrap/*.opt; do \
		[ -e "$$opt" ] || continue; \
		found=1; \
		printf '  %s -> HTTP ' "$$(basename "$$opt")"; \
		curl -sSk -H "Authorization: Bearer $$TOKEN" \
			-X POST https://localhost/ehrbase/rest/openehr/v1/definition/template/adl1.4 \
			-H 'Content-Type: application/xml' -H 'Accept: application/xml' \
			--data-binary @"$$opt" \
			-o /dev/null -w '%{http_code}\n'; \
	done; \
	[ "$$found" = 1 ] || echo "  (no *.opt in $(DOCKER_DIR)/openfhir/bootstrap)"; \
	echo "  templates in EHRbase:"; curl -sSk -H "Authorization: Bearer $$TOKEN" \
		-H 'Accept: application/json' \
		https://localhost/ehrbase/rest/openehr/v1/definition/template/adl1.4

.PHONY: bootstrap
bootstrap: ## Make openFHIR re-scan its bootstrap dir (no restart needed)
	@# BootstrapController rescans openfhir.bootstrap.dir in place: new files are
	@# created, changed files updated, unchanged ones skipped. This is what picks up
	@# a mapping YAML or an OPT added after the engine started — `make template` only
	@# loads EHRbase, which knows nothing about FHIR Connect.
	@#
	@# RESOLVED (verified 2026-08-31 against a running engine): $$bootstrap scans
	@# only *.yml and *.opt — the ledger shows MODEL/CONTEXT/OPT rows but zero
	@# CONCEPTMAP rows, and a mapping run then fails with "No such id: null,
	@# url: ... ConceptMap exists. Terminology translation not possible." The
	@# `conceptmaps` target below (once removed on the opposite assumption) is
	@# therefore required and runs as part of this target.
	@#
	@# NOTE (openfhir.protected): with the engine as a resource server, data
	@# loaded via these authenticated calls lands under the token's `tenant`
	@# claim (freshehr). The engine's own STARTUP bootstrap runs outside any
	@# request context, writes under the internal fallback tenant, and is
	@# invisible to freshehr callers — this target is the canonical loading path.
	@TOKEN=$$($(MAKE) --no-print-directory token); \
	[ -n "$$TOKEN" ] || { echo "ERROR: could not fetch a token from Keycloak (is the stack up?)"; exit 1; }; \
	code=$$(curl -sSk -H "Authorization: Bearer $$TOKEN" -X POST 'https://localhost/openfhir/$$bootstrap' \
		-o /dev/null -w '%{http_code}'); \
	echo "  bootstrap -> HTTP $$code"; \
	case "$$code" in 2*) ;; *) echo "ERROR: \$$bootstrap failed (HTTP $$code)"; exit 1;; esac
	@$(MAKE) --no-print-directory conceptmaps

.PHONY: conceptmaps
conceptmaps: ## Load the *_conceptmap.json terminology maps into openFHIR
	@# $$bootstrap only scans *.yml and *.opt, so the ConceptMaps sitting next to the
	@# mappers are never loaded by it (verified — see the bootstrap target). Without
	@# them a mapping run fails with "No such id: null, url: ... ConceptMap exists.
	@# Terminology translation not possible."
	@#
	@# Idempotent, but noisily so: re-posting an existing map answers 500 with
	@# "ConceptMap with this url ... already exists", not a 409. That is a conflict,
	@# not a failure, so it is reported as "already loaded" rather than being allowed
	@# to look like a broken bootstrap.
	@TOKEN=$$($(MAKE) --no-print-directory token); \
	[ -n "$$TOKEN" ] || { echo "ERROR: could not fetch a token from Keycloak (is the stack up?)"; exit 1; }; \
	fail=0; \
	for cm in $$(find "$(DOCKER_DIR)/openfhir/bootstrap" -name '*_conceptmap.json' | sort); do \
		body=$$(curl -sSk -X POST https://localhost/openfhir/terminology/fhir/ConceptMap \
			-H "Authorization: Bearer $$TOKEN" \
			-H 'Content-Type: application/json' --data-binary @"$$cm" \
			-w '\n%{http_code}'); \
		code=$$(printf '%s' "$$body" | tail -n1); \
		case "$$code" in \
			2*) status="loaded";; \
			*) case "$$body" in \
				*"already exists"*) status="already loaded";; \
				*) status="FAILED (HTTP $$code)"; fail=1;; \
			esac;; \
		esac; \
		printf '  %-46s %s\n' "$$(basename "$$cm")" "$$status"; \
	done; \
	exit $$fail

.PHONY: smoke
smoke: ## Auth matrix against the running stack: data routes must 401 bare / 200 with a Bearer token; health + discovery stay public
	@TOKEN=$$($(MAKE) --no-print-directory token); \
	[ -n "$$TOKEN" ] || { echo "FAIL: no token from Keycloak (is the stack up?)"; exit 1; }; \
	fail=0; \
	for r in fhir/metadata ehrbase/rest/status openfhir/fc/context terminology/fhir/metadata; do \
		no=$$(curl -sk -o /dev/null -w '%{http_code}' "https://localhost/$$r"); \
		ok=$$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $$TOKEN" "https://localhost/$$r"); \
		[ "$$no" = 401 ] && [ "$$ok" = 200 ] && verdict=OK || { verdict=FAIL; fail=1; }; \
		printf '  %-30s bare:%s (want 401)  bearer:%s (want 200)  %s\n' "/$$r" "$$no" "$$ok" "$$verdict"; \
	done; \
	health=$$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/openfhir/health); \
	[ "$$health" = 200 ] && verdict=OK || { verdict=FAIL; fail=1; }; \
	printf '  %-30s bare:%s (want 200, permitAll)  %s\n' "/openfhir/health" "$$health" "$$verdict"; \
	disc=$$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/auth/realms/freshehr/.well-known/openid-configuration); \
	[ "$$disc" = 200 ] && verdict=OK || { verdict=FAIL; fail=1; }; \
	printf '  %-30s %s (want 200)  %s\n' "OIDC discovery" "$$disc" "$$verdict"; \
	exit $$fail

.PHONY: hades-snomed
hades-snomed: ## Import a local SNOMED CT RF2 zip into hades (SNOMED_ZIP=/path/to/SnomedCT_...zip)
	@# Runs the import in a one-off container against the shared hades-data
	@# volume, entrypoint bypassed (a plain `hades import`, no serve). ~4g heap:
	@# a SNOMED import needs far more than the serving default (-Xmx1g).
	@# MLDS/TRUD auto-download variants are documented in the README.
	@test -n "$(SNOMED_ZIP)" || { echo "ERROR: set SNOMED_ZIP=/path/to/SnomedCT_RF2_release.zip"; exit 1; }
	$(COMPOSE) run --rm --no-deps --entrypoint "" \
		-v "$(abspath $(SNOMED_ZIP)):/import/snomed.zip:ro" \
		-e JAVA_OPTS= hades \
		java -Xmx4g -jar /app/hades.jar import /data/snomed.db /import/snomed.zip
	@# serve scans /data/*.db at startup, so a restart picks the new file up.
	$(COMPOSE) restart hades
	@echo "SNOMED imported. Consider raising HADES_JAVA_OPTS to -Xmx2g in docker/.env."

.PHONY: wait
wait: ## Block until every service answers (incl. HAPI, which has no compose healthcheck)
	@bash scripts/wait-healthy.sh

.PHONY: verify
verify: ## Data-plane test suite: templates, mappings, EPS ingest, AQL, tofhir content
	@bash scripts/verify.sh

.PHONY: versions
versions: ## Version drift report: declared pins (compose/Dockerfile/chart) vs running
	@bash scripts/versions.sh

## ── Layer 2: Kubernetes (Helm chart) ─────────────────────────────────────────
## Set ENV=hetzner|scaleway|dev (default hetzner). Local iteration uses values-dev.

.PHONY: helm-lint
helm-lint: ## Lint the chart (default + each values file)
	helm lint $(CHART)
	@for f in hetzner scaleway dev; do echo "── $$f ──"; helm lint $(CHART) -f $(CHART)/values-$$f.yaml; done

.PHONY: helm-render
helm-render: ## Render the chart to stdout (ENV=hetzner|scaleway|dev)
	helm template health-stack $(CHART) -n $(NS) -f $(CHART)/values-$(ENV).yaml

.PHONY: helm-dev
helm-dev: ## Install the chart on kind/minikube (values-dev; placeholder secrets + openfhir-license required)
	helm upgrade --install health-stack $(CHART) -n $(NS) --create-namespace \
		-f $(CHART)/values-dev.yaml

.PHONY: helm-install
helm-install: ## Install the chart (ENV=hetzner|scaleway|dev; needs real Secrets pre-created; set DOMAIN=...)
	helm upgrade --install health-stack $(CHART) -n $(NS) --create-namespace \
		-f $(CHART)/values-$(ENV).yaml $(if $(DOMAIN),--set ingress.host=$(DOMAIN),)
	@echo "Standalone install: create Secrets from $(CHART)/secrets.example.yaml + the openfhir-license Secret."
	@echo "(Via Terraform on Hetzner they are generated for you — see README > Credentials.)"

.PHONY: helm-uninstall
helm-uninstall: ## Uninstall the chart release
	helm uninstall health-stack -n $(NS)

.PHONY: k8s-status
k8s-status: ## Show pods in the health-stack namespace
	kubectl get pods -n $(NS) -o wide

## ── Layer 3: Terraform (per-cloud env) ───────────────────────────────────────
## Hetzner k3s only. Runs in terraform/envs/hetzner.

.PHONY: tf-init
tf-init: ## terraform init
	cd $(TF_ENV) && terraform init

.PHONY: tf-plan
tf-plan: ## terraform plan
	cd $(TF_ENV) && terraform plan

.PHONY: tf-cluster
tf-cluster: ## Phase 1: provision the cluster only (install_apps=false)
	cd $(TF_ENV) && terraform apply -var 'install_apps=false'

.PHONY: tf-apply
tf-apply: ## Phase 2: install add-ons + the health-stack chart (install_apps=true)
	cd $(TF_ENV) && terraform apply

.PHONY: tf-destroy
tf-destroy: ## Tear down all infrastructure
	cd $(TF_ENV) && terraform destroy

.PHONY: tf-fmt
tf-fmt: ## Format all terraform files (shared modules + all envs)
	cd terraform && terraform fmt -recursive

.PHONY: tf-validate
tf-validate: ## Validate the terraform configuration
	cd $(TF_ENV) && terraform validate

## ── Meta ─────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
