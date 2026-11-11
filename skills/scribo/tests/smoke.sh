#!/usr/bin/env bash
# End-to-end smoke test for the Scribo skill scripts against a local mock API
# (tests/mock-server.py). Exercises request -> redeem -> create -> download
# plus the failure exit codes.
#
# Runs the skill scripts under "$BASH_BIN" (default: bash) so CI can pin an old
# interpreter — set BASH_BIN=/bin/bash on macOS to exercise bash 3.2, where the
# `set -u` empty-array expansion bug lived. Requires: python3, curl, jq.
#
# Exits 0 if every assertion passes, 1 on the first failure.

set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scripts="$root/scripts"
bash_bin="${BASH_BIN:-bash}"
port="${PORT:-8799}"
export PORT="$port"
export SCRIBO_BASE_URL="http://127.0.0.1:$port"
unset SCRIBO_API_KEY SCRIBO_VERIFICATION_TOKEN 2>/dev/null || true

pass=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cleanup; exit 1; }
ok()   { printf 'ok: %s\n' "$*"; pass=$((pass + 1)); }

mock_pid=""
cleanup() { [ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null; return 0; }
trap cleanup EXIT

printf 'bash under test: '; "$bash_bin" --version | head -1
jq --version >/dev/null || fail "jq not found"

# 0. Static guard: no script may reference the removed legacy post-persist
# magic-link endpoint (/v1/sessions/magic-link/redeem). The current
# verify-then-persist flow uses /api/v1/scribo/email-verifications/:id/redeem
# and the magic_link_sent field (underscore), so neither pattern false-positives.
if grep -REn 'sessions/magic-link|magic-link/redeem' "$scripts" >/tmp/smoke.legacy 2>/dev/null; then
  fail "script references the removed legacy magic-link endpoint: $(cat /tmp/smoke.legacy)"
fi
ok "no legacy /v1/sessions/magic-link/redeem reference in scripts"

# Boot the mock and wait for it to accept connections.
python3 "$root/tests/mock-server.py" &
mock_pid=$!
curl -s --retry 30 --retry-delay 1 --retry-connrefused -m 10 -o /dev/null \
  "$SCRIBO_BASE_URL/api/v1/jurisdictions" || fail "mock server never came up"

# Helper: run a skill script under $bash_bin, capture stdout + exit code.
run() { script="$1"; shift; out="$("$bash_bin" "$scripts/$script" "$@" 2>/tmp/smoke.err)"; rc=$?; }

payload='{"sender":{"legal_name":"Example GmbH","country_code":"DE","address_line1":"A 1","postcode":"10115","city":"Berlin","tax_id":"DE123456789","contact_email":"smoke@example.com"},"recipient":{"legal_name":"Acme GmbH","country_code":"DE","address_line1":"H 1","postcode":"10117","city":"Berlin","tax_id":"DE136695976","contact_email":"ap@acme.example"},"line_items":[{"description":"Consulting","quantity":"1","unit_code":"DAY","unit_price":"1000.00","tax_rate":"19","tax_category_code":"S"}],"currency":"EUR"}'

# 1. list_jurisdictions
run list_jurisdictions.sh
[ "$rc" -eq 0 ] || fail "list_jurisdictions exit=$rc"
printf '%s' "$out" | jq -e 'map(.jurisdiction) | index("DE")' >/dev/null || fail "list_jurisdictions missing DE"
ok "list_jurisdictions"

# 2. create without a token -> verification_required, exit 10
out="$(printf '%s' "$payload" | "$bash_bin" "$scripts/create_invoice.sh" 2>/tmp/smoke.err)"; rc=$?
[ "$rc" -eq 10 ] || fail "tokenless create exit=$rc (want 10); stderr: $(cat /tmp/smoke.err)"
[ "$(printf '%s' "$out" | jq -r .status)" = "verification_required" ] || fail "tokenless create status"
challenge="$(printf '%s' "$out" | jq -r .challenge_id)"
[ -n "$challenge" ] && [ "$challenge" != "null" ] || fail "no challenge_id"
ok "create (no token) -> verification_required / exit 10"

# 2b. verify-then-persist: the tokenless create must NOT have persisted an
# invoice. Assert it returned no invoice id and never hit POST /api/v1/invoices.
printf '%s' "$out" | jq -e 'has("invoice_id") or has("document_id")' >/dev/null 2>&1 \
  && fail "tokenless create returned an invoice id (must not persist before verification)"
n="$(curl -s "$SCRIBO_BASE_URL/__debug/invoice-post-attempts" | jq -r .count)"
[ "$n" = "0" ] || fail "tokenless create hit POST /api/v1/invoices ($n times); must verify before persist"
ok "tokenless create did NOT POST /api/v1/invoices (verify-then-persist)"

# 2c. SCRIBO_LOCALE round-trips as the X-Scribo-Locale header (controls the
# verification-email + confirmation-page language). Run request_verification.sh
# directly so we exercise the standalone send path, not just create's.
out="$(SCRIBO_LOCALE=de-DE "$bash_bin" "$scripts/request_verification.sh" smoke@example.com 2>/tmp/smoke.err)"; rc=$?
[ "$rc" -eq 0 ] || fail "request_verification with locale exit=$rc; stderr: $(cat /tmp/smoke.err)"
[ "$(printf '%s' "$out" | jq -r .received_scribo_locale)" = "de-DE" ] || fail "X-Scribo-Locale did not round-trip"
ok "SCRIBO_LOCALE -> X-Scribo-Locale header round-trips"

# 3. create without contact_email -> exit 64
out="$(printf '%s' '{"sender":{"legal_name":"X"},"recipient":{},"line_items":[],"currency":"EUR"}' | "$bash_bin" "$scripts/create_invoice.sh" 2>/tmp/smoke.err)"; rc=$?
[ "$rc" -eq 64 ] || fail "create missing contact_email exit=$rc (want 64)"
ok "create (no contact_email) -> exit 64"

# 4. redeem with the right code -> token, exit 0
run redeem_verification.sh "$challenge" 234567
[ "$rc" -eq 0 ] || fail "redeem exit=$rc"
token="$(printf '%s' "$out" | jq -r .verification_token)"
[ -n "$token" ] && [ "$token" != "null" ] || fail "no verification_token"
ok "redeem (good code) -> token / exit 0"

# 5. redeem with a wrong code -> verification_invalid, exit 11
run redeem_verification.sh "$challenge" 999999
[ "$rc" -eq 11 ] || fail "redeem wrong code exit=$rc (want 11)"
ok "redeem (wrong code) -> exit 11"

# 6. create with the token via env var -> invoice; header round-trips
out="$(SCRIBO_VERIFICATION_TOKEN="$token" bash -c 'printf "%s" "$1" | "$2" "$3/create_invoice.sh"' _ "$payload" "$bash_bin" "$scripts" 2>/tmp/smoke.err)"; rc=$?
[ "$rc" -eq 0 ] || fail "create with token exit=$rc; stderr: $(cat /tmp/smoke.err)"
[ "$(printf '%s' "$out" | jq -r .invoice_id)" = "inv-mock-1" ] || fail "no invoice_id"
[ "$(printf '%s' "$out" | jq -r .received_verification_token)" = "$token" ] || fail "X-Email-Verification-Token did not round-trip"
invid="$(printf '%s' "$out" | jq -r .invoice_id)"
ok "create (env-var token) -> invoice; header round-trips"

# 6b. verify-then-persist: exactly one POST /api/v1/invoices total — none on the
# tokenless leg (step 2b), one here after redeeming the verification token.
n="$(curl -s "$SCRIBO_BASE_URL/__debug/invoice-post-attempts" | jq -r .count)"
[ "$n" = "1" ] || fail "expected exactly 1 invoice POST after verification, got $n"
ok "invoice persisted exactly once, only after verification"

# 7. get is sender-only: no token and no email -> exit 64; --email -> a code
# and verification_required / exit 10; a stale token -> exit 10.
run get_invoice.sh "$invid"
[ "$rc" -eq 64 ] || fail "get without verification exit=$rc (want 64)"
run get_invoice.sh "$invid" --email smoke@example.com
[ "$rc" -eq 10 ] || fail "get --email exit=$rc (want 10); stderr: $(cat /tmp/smoke.err)"
[ "$(printf '%s' "$out" | jq -r .status)" = "verification_required" ] || fail "get --email status"
SCRIBO_VERIFICATION_TOKEN=stale run get_invoice.sh "$invid"
[ "$rc" -eq 10 ] || fail "get with a stale token exit=$rc (want 10)"
ok "get without valid verification -> 64 / 10"

# 7b. get with the token -> a signed download_url; an unknown id -> 404 / exit 64.
SCRIBO_VERIFICATION_TOKEN="$token" run get_invoice.sh "$invid"
[ "$rc" -eq 0 ] || fail "get with token exit=$rc; stderr: $(cat /tmp/smoke.err)"
printf '%s' "$out" | jq -r .download_url | grep -q '[?&]t=' || fail "download_url is not signed"
SCRIBO_VERIFICATION_TOKEN="$token" run get_invoice.sh inv-unknown
[ "$rc" -eq 64 ] || fail "get unknown id exit=$rc (want 64)"
ok "get (token) -> signed download_url; unknown id -> 64"

# 8. download -> %PDF bytes through the signed link, exit 0 (exercises
# download_invoice.sh's own curl on bash 3.2)
rm -f /tmp/smoke.pdf
SCRIBO_VERIFICATION_TOKEN="$token" run download_invoice.sh "$invid" -o /tmp/smoke.pdf
[ "$rc" -eq 0 ] || fail "download exit=$rc; stderr: $(cat /tmp/smoke.err)"
head -c 5 /tmp/smoke.pdf | grep -q '%PDF' || fail "download did not write a PDF"
ok "download -> %PDF / exit 0"

# 8b. a refused link (expired 403, or Scribo's 303 to the explanation page)
# -> exit 66 and nothing written; no verification -> exit 64.
for id in inv-expired inv-redirect; do
  rm -f /tmp/smoke-refused.pdf
  SCRIBO_VERIFICATION_TOKEN="$token" run download_invoice.sh "$id" -o /tmp/smoke-refused.pdf
  [ "$rc" -eq 66 ] || fail "download $id exit=$rc (want 66); stderr: $(cat /tmp/smoke.err)"
  [ ! -e /tmp/smoke-refused.pdf ] || fail "download $id wrote a file"
done
run download_invoice.sh "$invid" -o /tmp/smoke-refused.pdf
[ "$rc" -eq 64 ] || fail "download without verification exit=$rc (want 64)"
ok "download refused link -> 66, no file; no verification -> 64"

printf '\nALL %s CHECKS PASSED (bash: %s)\n' "$pass" "$("$bash_bin" --version | head -1)"
