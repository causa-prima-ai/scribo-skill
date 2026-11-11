#!/usr/bin/env bash
# Fetch a previously generated invoice's metadata + a fresh signed download URL.
#
# Usage:
#   get_invoice.sh INVOICE_ID [--verification-token TOKEN] [--email EMAIL]
#
# Only the invoice's sender can read it: supply the sender's verification
# token, preferably via the SCRIBO_VERIFICATION_TOKEN env var (or
# --verification-token TOKEN), and it is sent as the X-Email-Verification-Token
# header. The token comes from redeem_verification.sh and covers ~30 minutes.
# Another sender's invoice and an unknown id both return 404 (exit 64).
#
# The returned download_url is signed and expires 15 minutes later
# (download_url_expires_at). Use it as-is; never build a download URL yourself.
#
# Without a token but with --email EMAIL, this script emails a verification
# code to EMAIL, prints a verification_required object and exits 10, exactly
# like create_invoice.sh. Then redeem_verification.sh <challenge_id> <code>,
# and re-run with the token. Without either, it exits 64.
#
# Prints the JSON response to stdout. Exit codes: 0 ok, 10 verification
# required (no token, or an expired or mismatched one), 64 invalid input or
# not found, 70 server or network error, 75 rate-limited.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$script_dir/_common.sh"

scribo_require curl jq

invoice_id=""
verification_token="${SCRIBO_VERIFICATION_TOKEN:-}"
sender_email=""

while [ $# -gt 0 ]; do
  case "$1" in
    --verification-token)
      verification_token="${2:-}"
      shift 2 ;;
    --verification-token=*)
      verification_token="${1#--verification-token=}"
      shift ;;
    --email)
      sender_email="${2:-}"
      shift 2 ;;
    --email=*)
      sender_email="${1#--email=}"
      shift ;;
    -h|--help)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*)
      printf 'scribo: unknown argument: %s\n' "$1" >&2
      exit 64 ;;
    *)
      if [ -z "$invoice_id" ]; then
        invoice_id="$1"
      else
        printf 'scribo: unexpected positional argument: %s\n' "$1" >&2
        exit 64
      fi
      shift ;;
  esac
done

if [ -z "$invoice_id" ]; then
  printf 'scribo: usage: get_invoice.sh INVOICE_ID [--verification-token TOKEN] [--email EMAIL]\n' >&2
  exit 64
fi

if [ -z "$verification_token" ]; then
  if [ -z "$sender_email" ]; then
    printf 'scribo: reading an invoice needs its sender'"'"'s verification. Set SCRIBO_VERIFICATION_TOKEN (or pass --verification-token), or pass --email with the address the invoice was issued from to receive a code.\n' >&2
    exit 64
  fi
  challenge_response="$(scribo_request POST /api/v1/scribo/email-verifications \
    -H 'Content-Type: application/json' \
    --data-binary "$(jq -cn --arg email "$sender_email" '{ email: $email }')")"
  challenge_id="$(printf '%s' "$challenge_response" | jq -r '.challenge_id // empty')"
  if [ -z "$challenge_id" ]; then
    printf 'scribo: verification request did not return a challenge_id\n' >&2
    exit 70
  fi
  email_hint="$(scribo_mask_email "$sender_email")"
  jq -n \
    --arg challenge_id "$challenge_id" \
    --arg email_hint "$email_hint" \
    --arg expires_at "$(printf '%s' "$challenge_response" | jq -r '.expires_at // empty')" \
    --arg next_step "Ask the user for the code emailed to ${email_hint}, then run: redeem_verification.sh ${challenge_id} <code> to get a verification_token, and re-run get_invoice.sh ${invoice_id} with SCRIBO_VERIFICATION_TOKEN set to it." \
    '{ status: "verification_required", challenge_id: $challenge_id, email_hint: $email_hint, expires_at: $expires_at, next_step: $next_step }'
  exit 10
fi

scribo_request GET "/api/v1/invoices/$invoice_id" \
  -H "X-Email-Verification-Token: $verification_token"
