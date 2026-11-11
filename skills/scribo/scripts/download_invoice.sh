#!/usr/bin/env bash
# Download an invoice's bytes.
#
# Usage:
#   download_invoice.sh INVOICE_ID [-o FILE] [--verification-token TOKEN] [--email EMAIL]
#
# Calls get_invoice.sh (same sender verification: SCRIBO_VERIFICATION_TOKEN,
# --verification-token or --email; exit 10 when verification is needed), then
# downloads the signed download_url it returns, as-is. The link is valid for
# 15 minutes, so each run fetches a fresh one.
#
# What you get depends on the invoice's resolved format:
#   - ZUGFeRD COMFORT / BASIC -> PDF/A-3 with EN 16931 CII XML embedded
#     (the legally binding artifact is the PDF; the XML lives inside it)
#   - XRechnung UBL / CII     -> raw UBL/CII XML (KoSIT / Peppol / federal
#     procurement consume the XML directly; no PDF is returned)
#   - plain_pdf               -> bare PDF
#
# Writes to FILE (default: invoice-INVOICE_ID.pdf — rename to .xml after
# download if the invoice is XRechnung) and prints the absolute path of
# the written file to stdout. Exit 66 when the link was refused (expired,
# revoked or not valid): re-run to fetch a fresh one.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_common.sh
. "$script_dir/_common.sh"

scribo_require curl jq

invoice_id=""
output_file=""
declare -a get_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output)
      output_file="${2:-}"
      shift 2 ;;
    --output=*)
      output_file="${1#--output=}"
      shift ;;
    --verification-token|--email)
      get_args+=("$1" "${2:-}")
      shift 2 ;;
    --verification-token=*|--email=*)
      get_args+=("$1")
      shift ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
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
  printf 'scribo: usage: download_invoice.sh INVOICE_ID [-o FILE] [--verification-token TOKEN] [--email EMAIL]\n' >&2
  exit 64
fi

if [ -z "$output_file" ]; then
  output_file="invoice-${invoice_id}.pdf"
fi

# A verification_required object (exit 10) or any error passes straight through.
set +e
invoice_json="$("$BASH" "$script_dir/get_invoice.sh" "$invoice_id" "${get_args[@]+"${get_args[@]}"}")"
get_exit=$?
set -e
if [ "$get_exit" -ne 0 ]; then
  [ -n "$invoice_json" ] && printf '%s\n' "$invoice_json"
  exit "$get_exit"
fi

download_url="$(printf '%s' "$invoice_json" | jq -r '.download_url // empty')"
if [ -z "$download_url" ]; then
  printf 'scribo: the invoice response carried no download_url\n' >&2
  exit 70
fi

body_file="$(mktemp)"
status_file="$(mktemp)"
trap 'rm -f "$body_file" "$status_file"' EXIT

set +e
# No -L: a refused link on the Scribo domain answers 303 to an explanation
# page, which must never be saved as the invoice. No API key either: the
# signed link is the whole credential.
curl -sS \
  -o "$body_file" \
  -w '%{http_code}' \
  "$download_url" \
  >"$status_file"
curl_exit=$?
set -e

if [ "$curl_exit" -ne 0 ]; then
  printf 'scribo: curl failed (exit %s)\n' "$curl_exit" >&2
  exit 70
fi

status="$(cat "$status_file")"

if [ "${status:0:1}" = "3" ]; then
  printf 'scribo: HTTP %s: the download link was refused (expired, revoked or not valid). Re-run download_invoice.sh to fetch a fresh one.\n' "$status" >&2
  exit 66
fi

if [ "${status:0:1}" != "2" ]; then
  scribo_print_error "$status" "$body_file"
  rc=0
  scribo_exit_for_error "$status" "$body_file" || rc=$?
  exit "$rc"
fi

mv "$body_file" "$output_file"
trap 'rm -f "$status_file"' EXIT

if command -v realpath >/dev/null 2>&1; then
  realpath "$output_file"
else
  printf '%s\n' "$output_file"
fi
