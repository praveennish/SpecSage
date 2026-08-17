.DEFAULT_GOAL := help
SHELL := /bin/bash

# Every AWS-touching target pins the profile and asserts the account ID before running.
# Guardrail rationale: DECISION-LOG D-015, D-016.
export AWS_PROFILE ?= specsage
AWS_REGION        ?= us-east-1
TF_DIR            ?= infra/environments/dev

GIT_SHA := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# --------------------------------------------------------------------------- local

.PHONY: install
install: ## Sync the Python 3.12 environment
	uv sync --all-groups

.PHONY: lint
lint: ## ruff check + format check + import boundaries
	uv run ruff check .
	uv run ruff format --check .
	uv run lint-imports

.PHONY: fmt
fmt: ## Auto-fix formatting and lint issues
	uv run ruff check --fix .
	uv run ruff format .

.PHONY: test
test: ## Unit tests only (no network, no cloud)
	uv run pytest -m "not smoke and not integration"

.PHONY: test-all
test-all: ## Every test, including smoke (needs a deployed environment)
	uv run pytest

.PHONY: run-local
run-local: ## FastAPI on localhost:8000 with reload
	GIT_SHA=$(GIT_SHA) uv run uvicorn service.main:app --reload --port 8000

.PHONY: docker-build
docker-build: ## Build the Lambda container image locally
	docker build --build-arg GIT_SHA=$(GIT_SHA) -t specsage:$(GIT_SHA) -t specsage:latest .

# --------------------------------------------------------------------------- aws guard

.PHONY: check-aws
check-aws: ## Verify credentials resolve to the expected account
	@if [ -z "$$SPECSAGE_ACCOUNT_ID" ]; then \
		echo "SPECSAGE_ACCOUNT_ID is not set. Export it or add it to .env.local"; exit 1; fi
	@actual=$$(aws sts get-caller-identity --query Account --output text 2>/dev/null); \
	if [ "$$actual" != "$$SPECSAGE_ACCOUNT_ID" ]; then \
		echo "WRONG ACCOUNT: profile '$(AWS_PROFILE)' resolves to $$actual, expected $$SPECSAGE_ACCOUNT_ID"; \
		exit 1; fi; \
	echo "account $$actual via profile $(AWS_PROFILE) — ok"

.PHONY: verify-setup
verify-setup: ## Check toolchain, credentials, Bedrock visibility, and the repo (read-only)
	./scripts/verify-setup.sh

.PHONY: check-bedrock
check-bedrock: ## Prove Bedrock access by invoking each model (costs a fraction of a cent)
	./scripts/check-bedrock.sh

# --------------------------------------------------------------------------- lifecycle
#
# The persistent/disposable seam (D-013, D-017). `data` owns the public URL and every
# durable artifact; `compute` is created and destroyed freely. The two are joined by one
# variable — data's `lambda_function_url` — so neither layer's state references the other.
#
#   make up     compute up   -> attach origin    (~4 min)
#   make down   detach origin -> compute destroy (~4 min, back to ~$1.30/mo)

ECR_REGISTRY := $(SPECSAGE_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
ECR_REPO     := $(ECR_REGISTRY)/specsage-api
TF_COMPUTE   := terraform -chdir=infra/compute
TF_DATA      := terraform -chdir=infra/data

.PHONY: up
up: check-aws ## Stand up compute and point CloudFront at it
	@echo "==> applying compute layer (image_tag=$(GIT_SHA))"
	$(TF_COMPUTE) apply -auto-approve -input=false -var="image_tag=$(GIT_SHA)"
	@echo "==> attaching Lambda as the CloudFront origin"
	$(TF_DATA) apply -auto-approve -input=false \
		-var="lambda_function_url=$$($(TF_COMPUTE) output -raw function_url)"
	@echo "==> waiting for CloudFront to propagate"
	@aws cloudfront wait distribution-deployed \
		--id $$($(TF_DATA) output -raw cloudfront_distribution_id)
	@echo "==> live at $$($(TF_DATA) output -raw public_url)"
	@$(MAKE) --no-print-directory smoke

.PHONY: down
down: check-aws ## Detach the origin, then destroy compute
	@echo "==> detaching origin (CloudFront falls back to the paused page)"
	$(TF_DATA) apply -auto-approve -input=false -var="lambda_function_url="
	@echo "==> destroying compute layer"
	$(TF_COMPUTE) destroy -auto-approve -input=false -var="image_tag=$(GIT_SHA)"
	@$(MAKE) --no-print-directory verify-empty

# NOTE: from M3 onward this target must snapshot Qdrant and export Neo4j to the artifacts
# bucket BEFORE destroying. Rebuilding the M4 graph costs one LLM call per chunk (D-013).

.PHONY: verify-empty
verify-empty: check-aws ## List any billable resource still running
	@echo "==> checking for leftovers"
	@fns=$$(aws lambda list-functions --query 'Functions[?starts_with(FunctionName,`specsage`)].FunctionName' --output text); \
	tasks=$$(aws ecs list-clusters --query 'clusterArns[?contains(@,`specsage`)]' --output text 2>/dev/null); \
	if [ -n "$$fns$$tasks" ]; then \
		echo "  STILL RUNNING: $$fns $$tasks"; exit 1; \
	else \
		echo "  clean — only the data layer remains (~\$$1.30/mo)"; \
	fi

.PHONY: deploy
deploy: check-aws ## Build, push, and roll the function to the current commit
	@echo "==> building $(GIT_SHA) for linux/arm64"
	aws ecr get-login-password --region $(AWS_REGION) \
		| docker login --username AWS --password-stdin $(ECR_REGISTRY)
	docker buildx build --platform linux/arm64 \
		--provenance=false --sbom=false \
		--build-arg GIT_SHA=$(GIT_SHA) \
		-t $(ECR_REPO):$(GIT_SHA) --push .
	@echo "==> rolling the function"
	$(TF_COMPUTE) apply -auto-approve -input=false -var="image_tag=$(GIT_SHA)"
	@aws lambda wait function-updated-v2 --function-name specsage-api
	@$(MAKE) --no-print-directory smoke

# --provenance=false --sbom=false is load-bearing, not stylistic: attestations make buildx
# publish an OCI image index and put the tag on it, leaving the real image as an untagged
# child that the ECR lifecycle policy will eventually delete. See D-028.

.PHONY: smoke
smoke: ## Smoke-test the live URL and assert the deployed SHA
	@url=$$($(TF_DATA) output -raw public_url 2>/dev/null); \
	if [ -z "$$url" ]; then echo "no public_url — is the data layer applied?"; exit 1; fi; \
	SPECSAGE_URL=$$url EXPECTED_GIT_SHA=$(GIT_SHA) uv run pytest -m smoke
