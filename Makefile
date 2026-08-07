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
# Targets below fill in as the Terraform layers land. See DECISION-LOG D-013, D-017.

.PHONY: up
up: check-aws ## Apply the compute layer and restore snapshots
	@echo "not yet implemented — lands with infra/modules/compute"

.PHONY: down
down: check-aws ## Snapshot stateful services, then destroy the compute layer
	@echo "not yet implemented — lands with infra/modules/compute"

.PHONY: verify-empty
verify-empty: check-aws ## List any billable resource still running after 'make down'
	@echo "not yet implemented — lands with infra/modules/compute"

.PHONY: deploy
deploy: check-aws ## Build, push to ECR, update the Lambda function
	@echo "not yet implemented — lands with infra/modules/compute"

.PHONY: smoke
smoke: ## Run smoke tests against the deployed URL
	uv run pytest -m smoke
