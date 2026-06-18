# Shared helpers for the Scribo skill scripts.
# Sourced by create_invoice.sh, get_invoice.sh, download_invoice.sh, list_jurisdictions.sh.
# Not executable on its own.

set -euo pipefail

SCRIBO_BASE_URL="${SCRIBO_BASE_URL:-https://scribo.causaprima.ai}"
SCRIBO_API_KEY="${SCRIBO_API_KEY:-}"
# BCP-47 UI-language tag (e.g. de-DE). When set, sent as X-Scribo-Locale on
# every request, so Scribo's outbound emails — the verification message (with
# its confirmation page) and the "invoice ready" notification — render in this
# language. Set it to the language of the conversation. Unsupported values
# fall back to English on the server, so a wrong value fails safe.
SCRIBO_LOCALE="${SCRIBO_LOCALE:-}"

scribo_require() {
  local missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    printf 'scribo: missing required commands: %s\n' "${missing[*]}" >&2
    exit 64
  fi
}

scribo_sha256() {
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -hex | awk '{print $NF}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    printf 'scribo: no sha256 implementation found (need openssl, sha256sum, or shasum)\n' >&2
    exit 64
  fi
}

# Mask an email for display in the verification_required hint, e.g.
# alice@example.com -> a***@e***.com. Mirrors the MCP server's email_hint
# so the LLM can prompt the user without echoing the full address.
scribo_mask_email() {
  local email="$1" local_part domain tld
  case "$email" in
    *@*.*)
      local_part="${email%@*}"
      domain="${email#*@}"
      tld="${domain##*.}"
      printf '%s***@%s***.%s' "${local_part:0:1}" "${domain:0:1}" "$tld" ;;
    *)
      # No domain / no TLD — degrade gracefully rather than leak the raw value.
      printf '%s***' "${email:0:1}" ;;
  esac
}

# Map an error envelope to a sysexits-style exit code.
# Args: <http_status> <body_file>
scribo_exit_for_error() {
  local status="$1" body_file="$2"
  local code=""
  if [ -s "$body_file" ]; then
    code="$(jq -r '.error.code // empty' <"$body_file" 2>/dev/null || true)"
  fi
  case "$status" in
    429) return 75 ;;
    4*)
      case "$code" in
        validator_failed) return 65 ;;
        # verification_invalid (wrong/expired/revoked code, from the redeem
        # endpoint) gets its own code so a caller can distinguish "ask the user
        # for the code again" from a generic malformed request. Pairs with the
        # exit 10 that create_invoice.sh emits for verification_required.
        verification_invalid) return 11 ;;
        *) return 64 ;;
      esac
      ;;
    5*) return 70 ;;
    *) return 70 ;;
  esac
}

# Print a useful error message from a response body to stderr.
scribo_print_error() {
  local status="$1" body_file="$2"
  if [ -s "$body_file" ] && jq -e '.error' <"$body_file" >/dev/null 2>&1; then
    {
      printf 'scribo: HTTP %s\n' "$status"
      jq -r '
        "  code:    \(.error.code // "unknown")",
        "  message: \(.error.message // "")"
      ' <"$body_file"
      if jq -e '.error.details' <"$body_file" >/dev/null 2>&1; then
        printf '  details: '
        jq -c '.error.details' <"$body_file"
      fi
    } >&2
  else
    {
      printf 'scribo: HTTP %s (no JSON error envelope)\n' "$status"
      # A non-2xx with no Scribo error envelope was blocked BEFORE reaching the
      # app — by a network egress proxy (some sandboxed agent runtimes only
      # allow allow-listed hosts) or a WAF/load balancer in front of the API —
      # not by Scribo. A bare 403 is the classic shape; it is NOT Turnstile and
      # NOT email verification, so re-verifying does not help.
      if [ "$status" = "403" ]; then
        printf 'scribo: a bare 403 with no Scribo error envelope means the request was blocked upstream (a network egress proxy or a WAF in front of the API), not by Scribo. Not Turnstile, not verification — re-verifying will not help. See references/troubleshooting.md.\n'
      fi
      if [ -s "$body_file" ]; then
        head -c 2000 <"$body_file"
        printf '\n'
      fi
    } >&2
  fi
}

# Run curl with the standard headers and capture status + body separately.
# Args: <method> <path> [curl-extra-args...]
# Writes body to stdout; sets SCRIBO_STATUS env var to the HTTP status.
scribo_request() {
  local method="$1" path="$2"
  shift 2
  local body_file status_file
  body_file="$(mktemp)"
  status_file="$(mktemp)"
  local -a headers=()
  if [ -n "$SCRIBO_API_KEY" ]; then
    headers+=(-H "Authorization: Bearer $SCRIBO_API_KEY")
  fi
  if [ -n "$SCRIBO_LOCALE" ]; then
    headers+=(-H "X-Scribo-Locale: $SCRIBO_LOCALE")
  fi
  set +e
  # NB: "${headers[@]+...}" guard — under `set -u`, expanding an empty array as
  # "${headers[@]}" is an "unbound variable" error on bash 3.2 (the default
  # /usr/bin/env bash on macOS). The guard expands to nothing when no API key
  # set a header, and to the elements otherwise.
  curl -sS \
    -X "$method" \
    "${headers[@]+"${headers[@]}"}" \
    "$@" \
    -o "$body_file" \
    -w '%{http_code}' \
    "${SCRIBO_BASE_URL}${path}" \
    >"$status_file"
  local curl_exit=$?
  set -e
  if [ "$curl_exit" -ne 0 ]; then
    printf 'scribo: curl failed (exit %s) calling %s %s\n' "$curl_exit" "$method" "$path" >&2
    rm -f "$body_file" "$status_file"
    exit 70
  fi
  SCRIBO_STATUS="$(cat "$status_file")"
  rm -f "$status_file"
  if [ "${SCRIBO_STATUS:0:1}" != "2" ]; then
    scribo_print_error "$SCRIBO_STATUS" "$body_file"
    local rc=0
    scribo_exit_for_error "$SCRIBO_STATUS" "$body_file" || rc=$?
    rm -f "$body_file"
    exit "$rc"
  fi
  cat "$body_file"
  rm -f "$body_file"
}
