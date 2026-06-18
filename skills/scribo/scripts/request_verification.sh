#!/usr/bin/env bash
# Request an email-ownership verification challenge (Scribo-03).
#
# Usage:
#   request_verification.sh EMAIL
#
# POSTs to /api/v1/scribo/email-verifications. Scribo emails a magic link
# AND a 6-digit code (alphabet {2,3,4,5,6,7,8,9}) to EMAIL. For this headless
# skill the user reads the code from their inbox; pass it to
# redeem_verification.sh to obtain a verification_token, then create the
# invoice with create_invoice.sh --verification-token <token>.
#
# The endpoint always returns 202 with the same shape regardless of whether
# the email is new, returning, or blocked (anti-enumeration). Prints the JSON
# response { challenge_id, expires_at, next_request_allowed_at } to stdout.
#
# Exit codes (sysexits-style):
#   0  ok (challenge minted or reused)
#   64 invalid input / other 4xx (a bare 403 from a WAF/egress proxy lands here)
#   70 server / network error
#   75 rate-limited (429)

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$script_dir/_common.sh"

scribo_require curl jq

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  printf 'scribo: usage: request_verification.sh EMAIL\n' >&2
  exit 64
fi

email="$1"
request_body="$(jq -nc --arg email "$email" '{ email: $email }')"

scribo_request POST /api/v1/scribo/email-verifications \
  -H "Content-Type: application/json" \
  --data-binary "$request_body"
