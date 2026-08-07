#!/usr/bin/env bash
# Verify SpecSage setup. Safe to run at any point — every check is read-only.
#
# Each failure names the runbook step to go back to, so this doubles as a progress tracker
# while working through docs/RUNBOOK.md §1–§3.
#
#   ./scripts/verify-setup.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -t 1 ]]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; D=""; N=""
fi

PASS=0; FAIL=0; WARN=0

pass() { printf '  %s✓%s %s\n' "$G" "$N" "$1"; PASS=$((PASS + 1)); }
fail() { printf '  %s✗%s %s\n    %s→ %s%s\n' "$R" "$N" "$1" "$D" "$2" "$N"; FAIL=$((FAIL + 1)); }
warn() { printf '  %s!%s %s\n    %s→ %s%s\n' "$Y" "$N" "$1" "$D" "$2" "$N"; WARN=$((WARN + 1)); }
section() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# Load .env.local if present, without clobbering an already-exported value.
if [[ -f .env.local ]]; then
  set -a; source .env.local; set +a
fi
export AWS_PROFILE="${AWS_PROFILE:-specsage}"

printf '%sSpecSage setup verification%s\n' "$B" "$N"
printf '%sprofile=%s  region=%s%s\n' "$D" "$AWS_PROFILE" "${AWS_REGION:-us-east-1}" "$N"

# --------------------------------------------------------------------- toolchain
section "Toolchain  (RUNBOOK §0.2)"

check_cmd() {
  local cmd=$1 label=$2 hint=$3
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "$label — $($cmd --version 2>&1 | head -1)"
  else
    fail "$label not found" "$hint"
  fi
}

check_cmd git       "git"       "brew install git"
check_cmd uv        "uv"        "curl -LsSf https://astral.sh/uv/install.sh | sh"
check_cmd aws       "aws cli"   "brew install awscli"
check_cmd docker    "docker"    "brew install --cask docker"
check_cmd terraform "terraform" "brew install terraform"

if command -v terraform >/dev/null 2>&1; then
  tf_ver=$(terraform --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  tf_major=${tf_ver%%.*}; tf_minor=${tf_ver##*.}
  if (( tf_major > 1 || (tf_major == 1 && tf_minor >= 10) )); then
    pass "terraform >= 1.10 (S3 native state locking available)"
  else
    fail "terraform $tf_ver is too old for use_lockfile" "brew upgrade terraform — see D-006"
  fi
fi

# --------------------------------------------------------------------- credentials
section "AWS credentials  (RUNBOOK §1.5)"

if ! grep -q '^\[specsage\]' ~/.aws/credentials 2>/dev/null; then
  fail "no [specsage] section in ~/.aws/credentials" "RUNBOOK §1.5"
else
  pass "[specsage] profile section present"

  # Catch the two formatting mistakes that produce misleading errors.
  if awk '/^\[specsage\]/{f=1;next} /^\[/{f=0} f' ~/.aws/credentials | grep -q 'export '; then
    fail "credentials contain shell 'export' prefixes" "strip them — RUNBOOK §1.5"
  fi
  if awk '/^\[specsage\]/{f=1;next} /^\[/{f=0} f' ~/.aws/credentials | grep -qE '=[[:space:]]*"'; then
    fail "credential values are quoted" "remove surrounding quotes — RUNBOOK §1.5"
  fi
fi

IDENTITY=$(aws sts get-caller-identity --output json 2>&1)
if echo "$IDENTITY" | grep -q '"Account"'; then
  ACTUAL_ACCOUNT=$(echo "$IDENTITY" | grep -o '"Account": *"[0-9]*"' | grep -o '[0-9]\{12\}')
  ACTUAL_ARN=$(echo "$IDENTITY" | grep -o '"Arn": *"[^"]*"' | cut -d'"' -f4)
  pass "credentials resolve — $ACTUAL_ARN"

  if [[ "$ACTUAL_ARN" == *"assumed-role/AWSReservedSSO"* ]]; then
    fail "this is an SSO role, not the personal IAM user" "export AWS_PROFILE=specsage — see D-014"
  fi

  if [[ -z "${SPECSAGE_ACCOUNT_ID:-}" ]]; then
    warn "SPECSAGE_ACCOUNT_ID not set (account guard inactive)" "create .env.local — RUNBOOK §2.3"
  elif [[ "$SPECSAGE_ACCOUNT_ID" != "$ACTUAL_ACCOUNT" ]]; then
    fail "account mismatch: resolved $ACTUAL_ACCOUNT, expected $SPECSAGE_ACCOUNT_ID" "RUNBOOK §2.3"
  else
    pass "account matches SPECSAGE_ACCOUNT_ID ($ACTUAL_ACCOUNT)"
  fi
else
  msg=$(echo "$IDENTITY" | tail -1)
  case "$msg" in
    *InvalidClientTokenId*) fail "InvalidClientTokenId" "usually quoted values in the credentials file — RUNBOOK §1.5" ;;
    *ExpiredToken*)         fail "ExpiredToken" "you're on a temporary-credential profile — export AWS_PROFILE=specsage" ;;
    *Unable\ to\ locate*)   fail "credentials not found or unparseable" "RUNBOOK §1.5" ;;
    *)                      fail "sts:GetCallerIdentity failed" "$msg" ;;
  esac
fi

# --------------------------------------------------------------------- bedrock
section "Bedrock  (RUNBOOK §1.6)"

REGION="${AWS_REGION:-us-east-1}"

# Everything below needs working credentials. Without them these checks all fail for the
# same upstream reason, which buries the one failure that actually matters.
if [[ -z "${ACTUAL_ACCOUNT:-}" ]]; then
  warn "skipped — no working credentials" "fix the credentials section above first"
else
WANTED=(
  "anthropic.claude-haiku-4-5-20251001-v1:0"
  "anthropic.claude-sonnet-5"
  "amazon.titan-embed-text-v2:0"
)

MODELS=$(aws bedrock list-foundation-models --region "$REGION" \
  --query 'modelSummaries[].modelId' --output text 2>&1)

if [[ "$MODELS" == *"AccessDenied"* || "$MODELS" == *"not authorized"* ]]; then
  fail "cannot list Bedrock models" "check the IAM policy allows bedrock:ListFoundationModels"
elif [[ "$MODELS" == *"Could not connect"* || "$MODELS" == *"EndpointConnectionError"* ]]; then
  fail "cannot reach Bedrock in $REGION" "check the region — RUNBOOK §1.6"
else
  for m in "${WANTED[@]}"; do
    if [[ "$MODELS" == *"$m"* ]]; then
      pass "$m visible"
    else
      fail "$m not visible in $REGION" "RUNBOOK §1.6"
    fi
  done
  warn "visibility != access" "list-foundation-models ignores access status; the real test is the first InvokeModel at M3"
fi
fi

# --------------------------------------------------------------------- billing
section "Cost controls  (RUNBOOK §1.7, §1.8)"

if [[ -z "${ACTUAL_ACCOUNT:-}" ]]; then
  warn "skipped — no working credentials" "fix the credentials section above first"
else
  BUDGETS=$(aws budgets describe-budgets --account-id "$ACTUAL_ACCOUNT" \
    --query 'Budgets[].BudgetName' --output text 2>&1)
  if [[ "$BUDGETS" == *"specsage"* ]]; then
    pass "budget alarm configured"
  elif [[ "$BUDGETS" == *"AccessDenied"* || "$BUDGETS" == *"not authorized"* ]]; then
    warn "cannot read budgets" "billing permissions may need enabling for IAM users"
  else
    fail "no budget named 'specsage-*' found" "RUNBOOK §1.7"
  fi

  TAGS=$(aws ce list-cost-allocation-tags --status Active \
    --query 'CostAllocationTags[].TagKey' --output text 2>&1)
  if [[ "$TAGS" == *"Project"* ]]; then
    pass "'Project' cost allocation tag is active"
  else
    warn "'Project' cost allocation tag not active yet" \
         "expected until the first tagged resource exists (up to 24h) — RUNBOOK §1.8"
  fi
fi

# --------------------------------------------------------------------- repo
section "Repository  (RUNBOOK §2)"

[[ -d .venv ]] && pass "Python environment synced" \
  || fail "no .venv" "make install"

if [[ -f .env.local ]]; then
  pass ".env.local present"
else
  warn "no .env.local" "RUNBOOK §2.3 — the account guard needs SPECSAGE_ACCOUNT_ID"
fi

if [[ -d .venv ]]; then
  if uv run ruff check . >/dev/null 2>&1 && uv run ruff format --check . >/dev/null 2>&1; then
    pass "lint clean"
  else
    fail "lint failing" "make fmt"
  fi

  if uv run lint-imports >/dev/null 2>&1; then
    pass "import boundaries intact (retrieval has no agent-framework dependency)"
  else
    fail "import boundary violated" "see D-002 — move the import into agents/"
  fi

  # No extra -q: pyproject already sets it, and -qq suppresses the summary line we parse.
  if TEST_OUT=$(uv run pytest -m "not smoke and not integration" 2>&1); then
    pass "unit tests — $(echo "$TEST_OUT" | grep -oE '[0-9]+ passed' | head -1)"
  else
    fail "unit tests failing" "make test"
  fi
fi

if git rev-parse HEAD >/dev/null 2>&1; then
  pass "git history present ($(git rev-parse --short HEAD))"
else
  warn "no commits yet" "/health will report git_sha=unknown until you commit — RUNBOOK §3.1"
fi

# --------------------------------------------------------------------- summary
printf '\n%s────────────────────────────────────%s\n' "$D" "$N"
printf '%s%d passed%s' "$G" "$PASS" "$N"
(( WARN )) && printf '  %s%d warning%s%s' "$Y" "$WARN" "$([[ $WARN -eq 1 ]] || echo s)" "$N"
(( FAIL )) && printf '  %s%d failed%s' "$R" "$FAIL" "$N"
printf '\n'

if (( FAIL )); then
  printf '\nFix the failures above, then re-run. Warnings are fine to defer.\n'
  exit 1
fi
printf '\nSetup verified. Next: docs/plans/M0-plan.md §8.\n'
