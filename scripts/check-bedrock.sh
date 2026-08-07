#!/usr/bin/env bash
# Prove Bedrock model access by actually invoking each model.
#
# `list-foundation-models` shows models regardless of whether you can call them, so it can
# report success while every invocation fails. This script makes a real (tiny) call — a few
# input tokens and a 16-token cap, well under a cent for all three models combined.
#
# It also resolves the inference-profile question automatically: several Bedrock models reject
# the bare model ID for on-demand throughput and require a cross-region inference profile
# (`us.anthropic.…`). Rather than guess which, this tries the bare ID and retries with the
# `us.` prefix on that specific error, then tells you which form worked — that is the ID to
# pin in config.
#
#   ./scripts/check-bedrock.sh

set -uo pipefail

if [[ -t 1 ]]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; D=$'\033[2m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; D=""; N=""
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
[[ -f .env.local ]] && { set -a; source .env.local; set +a; }

export AWS_PROFILE="${AWS_PROFILE:-specsage}"
REGION="${AWS_REGION:-us-east-1}"

# Sonnet 4.6, not Sonnet 5 — this account is denied access to the 4.7+/5-family models
# (verified 2026-08-02, see D-028). Sonnet 4.6 is the working teacher, not a placeholder;
# re-run this script periodically to see if Sonnet 5 access clears, but nothing waits on it.
MODELS=(
  "anthropic.claude-sonnet-4-6|teacher synthesis (M6, M9)"
  "anthropic.claude-haiku-4-5-20251001-v1:0|graph extraction, LLM-as-judge (M4, M7)"
)
EMBED_MODEL="amazon.titan-embed-text-v2:0"

# Newest-generation models this account has been denied. Checked but not required — a green
# run here would mean Sonnet 5 access cleared and is worth revisiting for M9's comparison.
WATCH_MODELS=(
  "anthropic.claude-sonnet-5"
  "anthropic.claude-opus-5"
)

FAIL=0
RESOLVED=()

printf '%sBedrock invocation check%s\n' "$B" "$N"
printf '%sprofile=%s  region=%s%s\n\n' "$D" "$AWS_PROFILE" "$REGION" "$N"

IDENTITY=$(aws sts get-caller-identity --query Arn --output text 2>&1)
if [[ "$IDENTITY" != arn:* ]]; then
  printf '  %s✗%s credentials not usable: %s\n' "$R" "$N" "$IDENTITY"
  printf '    %s→ RUNBOOK §1.5%s\n' "$D" "$N"
  exit 1
fi
printf '  %s·%s calling as %s\n\n' "$D" "$N" "$IDENTITY"

# --- text models via the Converse API ---------------------------------------------------
invoke() {
  aws bedrock-runtime converse \
    --region "$REGION" \
    --model-id "$1" \
    --messages '[{"role":"user","content":[{"text":"Reply with exactly: OK"}]}]' \
    --inference-config '{"maxTokens":16}' \
    --query 'output.message.content[0].text' --output text 2>&1
}

for entry in "${MODELS[@]}"; do
  model_id="${entry%%|*}"
  purpose="${entry##*|}"
  printf '%s%s%s\n  %s%s%s\n' "$B" "$model_id" "$N" "$D" "$purpose" "$N"

  out=$(invoke "$model_id")
  used="$model_id"

  # Some models refuse the bare ID and require a cross-region inference profile.
  if [[ "$out" == *"on-demand throughput isn"* || "$out" == *"inference profile"* ]]; then
    printf '  %s·%s bare ID rejected, retrying via inference profile…\n' "$D" "$N"
    used="us.${model_id}"
    out=$(invoke "$used")
  fi

  case "$out" in
    *AccessDeniedException*|*"not authorized"*)
      printf '  %s✗%s access not granted\n    %s→ Bedrock console → Model access → request it. RUNBOOK §1.6%s\n' \
        "$R" "$N" "$D" "$N"; FAIL=1 ;;
    *ResourceNotFoundException*|*ValidationException*)
      printf '  %s✗%s %s\n' "$R" "$N" "$(echo "$out" | tail -1)"; FAIL=1 ;;
    *ThrottlingException*)
      printf '  %s!%s throttled — access works, quota is tight. Retry.\n' "$Y" "$N" ;;
    *"Could not connect"*|*EndpointConnectionError*)
      printf '  %s✗%s cannot reach Bedrock in %s\n' "$R" "$N" "$REGION"; FAIL=1 ;;
    *OK*)
      printf '  %s✓%s invoked successfully — model replied %s\n' "$G" "$N" "$(echo "$out" | tr -d '\n' | head -c 40)"
      RESOLVED+=("$used") ;;
    *)
      printf '  %s!%s unexpected response: %s\n' "$Y" "$N" "$(echo "$out" | tail -1 | head -c 200)" ;;
  esac
  printf '\n'
done

# --- embeddings via InvokeModel (Converse is chat-only) ----------------------------------
printf '%s%s%s\n  %sembeddings (M3)%s\n' "$B" "$EMBED_MODEL" "$N" "$D" "$N"
tmp=$(mktemp)
out=$(aws bedrock-runtime invoke-model \
  --region "$REGION" \
  --model-id "$EMBED_MODEL" \
  --content-type application/json \
  --accept application/json \
  --body "$(printf '{"inputText":"hello"}' | base64)" \
  "$tmp" 2>&1)

if [[ $? -eq 0 ]] && grep -q 'embedding' "$tmp" 2>/dev/null; then
  dims=$(python3 -c "import json,sys; print(len(json.load(open('$tmp'))['embedding']))" 2>/dev/null || echo "?")
  printf '  %s✓%s invoked successfully — %s dimensions\n' "$G" "$N" "$dims"
  RESOLVED+=("$EMBED_MODEL")
else
  case "$out" in
    *AccessDenied*|*"not authorized"*)
      printf '  %s✗%s access not granted\n    %s→ RUNBOOK §1.6%s\n' "$R" "$N" "$D" "$N" ;;
    *) printf '  %s✗%s %s\n' "$R" "$N" "$(echo "$out" | tail -1 | head -c 200)" ;;
  esac
  FAIL=1
fi
rm -f "$tmp"

# --- watch list: not required, informational only -----------------------------------------
printf '\n%sWatching for newer-model access (not required)%s\n' "$D" "$N"
for m in "${WATCH_MODELS[@]}"; do
  out=$(invoke "$m")
  [[ "$out" == *"on-demand throughput isn"* || "$out" == *"inference profile"* ]] && out=$(invoke "us.$m")
  case "$out" in
    *OK*) printf '  %s✓ %s is now accessible%s — worth switching to for the M9 comparison\n' "$G" "$m" "$N" ;;
    *)    printf '  %s·%s %s still denied\n' "$D" "$N" "$m" ;;
  esac
done

# --- summary ------------------------------------------------------------------------------
printf '\n%s────────────────────────────────────%s\n' "$D" "$N"
if (( FAIL )); then
  printf '%sSome models are not invokable.%s See RUNBOOK §1.6 and §9.\n' "$R" "$N"
  exit 1
fi

printf '%sAll models invokable.%s Pin these exact IDs in config:\n\n' "$G" "$N"
for id in "${RESOLVED[@]}"; do printf '  %s\n' "$id"; done
printf '\n'
if printf '%s\n' "${RESOLVED[@]}" | grep -q '^us\.'; then
  printf '%sNote:%s an ID above is prefixed `us.` — that is a cross-region inference profile,\n' "$Y" "$N"
  printf 'required because the bare model ID rejects on-demand throughput. Record it in\n'
  printf 'docs/DECISION-LOG.md D-028; the prefixed form is what the code must use.\n'
fi
