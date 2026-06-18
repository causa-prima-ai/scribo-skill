#!/usr/bin/env bash
# Generate a Scribo invoice via POST /api/v1/invoices.
#
# Usage:
#   create_invoice.sh [--from FILE] [--idempotency-key KEY] [--verification-token TOKEN]
#
# Reads a JSON payload from stdin by default, or from FILE if --from is given.
# Prints the JSON response to stdout. Sets exit code by sysexits:
#   0  ok
#   10 verification required — a code was emailed to sender.contact_email; see below
#   64 invalid input / 4xx (other than validator_failed and rate_limited)
#   65 validator_failed (Invopop schematron rejected the invoice)
#   70 server error / network error
#   75 rate-limited (429)
#
# Email verification (Scribo-03): /api/v1/invoices requires proof that the
# caller owns sender.contact_email. Supply the verification_token via
# --verification-token TOKEN (or the SCRIBO_VERIFICATION_TOKEN env var) and it
# is sent as the X-Email-Verification-Token header. One token covers several
# invoices for the same sender within its ~30-minute TTL.
#
# If no token is supplied, this script does NOT create the invoice. Instead it
# requests a verification challenge for sender.contact_email (Scribo emails a
# 6-digit code), prints a verification_required object, and exits 10. Then:
#   1. Ask the user for the 6-digit code from the email.
#   2. redeem_verification.sh <challenge_id> <code>   → verification_token
#   3. re-run: create_invoice.sh --verification-token <token>   (same payload)

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$script_dir/_common.sh"

scribo_require curl jq

input_file=""
idempotency_key=""
verification_token="${SCRIBO_VERIFICATION_TOKEN:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --from)
      input_file="${2:-}"
      shift 2 ;;
    --from=*)
      input_file="${1#--from=}"
      shift ;;
    --idempotency-key)
      idempotency_key="${2:-}"
      shift 2 ;;
    --idempotency-key=*)
      idempotency_key="${1#--idempotency-key=}"
      shift ;;
    --verification-token)
      verification_token="${2:-}"
      shift 2 ;;
    --verification-token=*)
      verification_token="${1#--verification-token=}"
      shift ;;
    -h|--help)
      sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      printf 'scribo: unknown argument: %s\n' "$1" >&2
      exit 64 ;;
  esac
done

payload_file="$(mktemp)"
trap 'rm -f "$payload_file"' EXIT

if [ -n "$input_file" ]; then
  if [ ! -r "$input_file" ]; then
    printf 'scribo: cannot read --from file: %s\n' "$input_file" >&2
    exit 64
  fi
  cp "$input_file" "$payload_file"
else
  cat >"$payload_file"
fi

if ! jq -e . <"$payload_file" >/dev/null 2>&1; then
  printf 'scribo: payload is not valid JSON\n' >&2
  exit 64
fi

# Scribo-03: without a verification token we cannot create the invoice. Request
# a challenge for the sender email, then emit a verification_required object so
# the caller knows to collect the code and retry. (Mirrors the MCP server's
# create_invoice -> verification_required -> verify_email_code orchestration.)
if [ -z "$verification_token" ]; then
  sender_email="$(jq -r '.sender.contact_email // empty' <"$payload_file")"
  if [ -z "$sender_email" ]; then
    printf 'scribo: sender.contact_email is required (it is the address Scribo verifies and your login)\n' >&2
    exit 64
  fi

  request_body="$(jq -nc --arg email "$sender_email" '{ email: $email }')"
  # scribo_request prints the error and exits non-zero on a 4xx/5xx (e.g. a
  # 429 rate-limit, or a bare 403 from a WAF/egress proxy in front of the API);
  # set -e then propagates here.
  challenge_response="$(scribo_request POST /api/v1/scribo/email-verifications \
    -H "Content-Type: application/json" \
    --data-binary "$request_body")"

  challenge_id="$(printf '%s' "$challenge_response" | jq -r '.challenge_id // empty')"
  expires_at="$(printf '%s' "$challenge_response" | jq -r '.expires_at // empty')"
  email_hint="$(scribo_mask_email "$sender_email")"

  if [ -z "$challenge_id" ]; then
    printf 'scribo: verification request did not return a challenge_id\n' >&2
    printf '%s\n' "$challenge_response" >&2
    exit 70
  fi

  jq -nc \
    --arg challenge_id "$challenge_id" \
    --arg email_hint "$email_hint" \
    --arg expires_at "$expires_at" \
    --arg next_step "Ask the user for the 6-digit code emailed to ${email_hint}, then run: redeem_verification.sh ${challenge_id} <code> to get a verification_token, and re-run create_invoice.sh --verification-token <token> with the same payload." \
    '{ status: "verification_required", challenge_id: $challenge_id, email_hint: $email_hint, expires_at: $expires_at, next_step: $next_step }'
  exit 10
fi

if [ -z "$idempotency_key" ]; then
  idempotency_key="$(jq -cS . <"$payload_file" | scribo_sha256)"
fi

scribo_request POST /api/v1/invoices \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $idempotency_key" \
  -H "X-Email-Verification-Token: $verification_token" \
  --data-binary "@$payload_file"
