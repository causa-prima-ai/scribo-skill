# Troubleshooting

All Scribo errors share the envelope:

```json
{
  "error": {
    "code": "...",
    "message": "...",
    "details": {} | []
  }
}
```

The helper scripts exit with sysexits-style codes:

| Exit code | Meaning |
|---|---|
| `0` | OK |
| `10` | Verification required — `create_invoice.sh` was called without a token; it requested a challenge and printed `verification_required`. Collect the code, redeem, retry. |
| `11` | Verification code rejected (`verification_invalid`, from `redeem_verification.sh`) — wrong/expired/revoked code. Re-prompt the user and retry. |
| `64` | Invalid input / bad usage (4xx with `code` in the `invalid_input` family, or missing CLI arguments) |
| `65` | Data validation failed (`validator_failed`) |
| `70` | Server error (5xx) |
| `75` | Rate-limited (429) |

## Email verification (Scribo-03)

Invoice creation requires proof the caller owns `sender.contact_email`. You orchestrate it — see the **Verification** section of `SKILL.md` for the worked sequence. The error codes:

### `verification_required` (from `create_invoice.sh`, exit 10)

Not a server error — `create_invoice.sh` was run without a `verification_token`. It has requested a challenge and printed `{ status: "verification_required", challenge_id, email_hint, next_step }`. Ask the user for the 6-digit code emailed to `email_hint`, run `redeem_verification.sh <challenge_id> <code>`, then re-run `create_invoice.sh` with `SCRIBO_VERIFICATION_TOKEN` set (or `--verification-token`).

### `email_verification_required` (401, from `/api/v1/invoices`)

The create reached the API without a valid `X-Email-Verification-Token` (or the token expired). Re-run the verification flow to mint a fresh token. (In normal use `create_invoice.sh` prevents this by requesting a challenge before it ever calls `/api/v1/invoices`.)

### `verification_email_mismatch` (403, from `/api/v1/invoices`)

The verified email doesn't match `sender.contact_email`. The token is bound to the exact email it was issued for — you can't verify one address and invoice as another. Re-run verification for the **same** email that's in `sender.contact_email`, or correct the payload.

### `verification_invalid` (400, from `redeem_verification.sh`, exit 11)

Uniform error for a wrong, expired, already-used, or revoked code — there's no signal which. Ask the user to re-check the code and try again. After 5 wrong attempts the challenge is revoked; re-run `create_invoice.sh` (no token) to mint a fresh challenge and a new code email.

## `rate_limited` (429)

Response body:

```json
{
  "error": {
    "code": "rate_limited",
    "message": "Rate limit exceeded",
    "retry_after_seconds": 3600,
    "reset_at": "2026-05-11T15:00:00Z",
    "limit_code": "ip" | "tenant" | "email_domain"
  }
}
```

What to tell the user:

- `limit_code: "ip"` — too many requests from this network. Wait `retry_after_seconds` or try from a different network.
- `limit_code: "tenant"` — this sender email has generated 50 invoices in the last 24h. Wait or contact support.
- `limit_code: "email_domain"` — the sender's email domain has hit the soft-block threshold. Use a different domain or contact support.

## `turnstile_required` (401)

Turnstile (CAPTCHA) gates **only the Scribo web chat**. The public `/api/v1/*` API and these scripts are **never** CAPTCHA-gated, so a correctly-routed skill call never gets `turnstile_required`. If you do see it (a 401 *with* a JSON `error` body), the request hit the web-chat route by mistake — use the `/api/v1/*` endpoints the scripts already target. Re-verifying or visiting the web UI does not help: web verification yields a browser session, not a `verification_token` the scripts can reuse.

## Bare `403` with no JSON `error` envelope

Every error Scribo itself emits is JSON. A `403 Forbidden` whose body is a short HTML page (not the `{ "error": … }` envelope) did **not** come from Scribo — the request was blocked **before** it reached the app:

- a **network egress proxy** — some sandboxed agent runtimes (e.g. Claude Cowork) only allow outbound HTTPS to allow-listed hosts; or
- a **WAF / load balancer** in front of the API — a free-text field shaped like SQL, HTML, or a path traversal can trip it.

This is not Turnstile and not email verification, so re-verifying won't fix it. If it's a sandbox egress limit, use the hosted MCP server at `https://scribo.causaprima.ai/mcp` (invoked server-side, so it needs no sandbox network access).

## `idempotency_key_mismatch` (422)

The script auto-mints `Idempotency-Key` from a SHA-256 of the payload, so same-payload retries return the cached response. If the user supplied an `--idempotency-key` explicitly and the payload changed, you'll see:

```json
{
  "error": {
    "code": "idempotency_key_mismatch",
    "message": "Idempotency key already used with different inputs",
    "details": { "diff": [ { "path": "...", "old": "...", "new": "..." } ] }
  }
}
```

Either keep the original payload, or use a fresh idempotency key (or let the script auto-mint one).

## `validator_failed` (400 or 201 with `valid: false`)

Two shapes:

1. **Pre-generation rejection** (400) — required field missing or format-specific constraint violated before Invopop is even called.
2. **Schematron failure** (201, but `validator_summary.valid == false`) — Invopop generated the invoice but the validator flagged rule violations. The PDF/XML is still returned but **the recipient's tax authority may reject it**. The `validator_summary.errors` array has `[ { path, rule, message } ]`.

Common rules:

| Rule | Trigger | Fix |
|---|---|---|
| `BR-E-10` / `GOBL-EU-EN16931-TAX-COMBO-06` | `tax_category_code: "E"` line without a VATEX code | Add `tax_exemption_code` to the line. `VATEX-EU-79-C` for Kleinunternehmer § 19 UStG, `VATEX-EU-132` for Art. 132 (health/education), etc. |
| `BR-DE-1` / `GOBL-DE-XRECHNUNG-BILL-INVOICE-17` | XRechnung-resolved invoice without `payment_means` | Add `payment_means: { type: "credit_transfer", iban: "DE…" }`. BIC + account_name are optional. |
| `BR-DE-5` / `BR-DE-6` | XRechnung sender missing `contact_name` / `contact_phone` | Add them to `sender.contact_name` / `sender.contact_phone`. |
| `BR-DE-14` | XRechnung with all-outside-scope (O) lines | All-O XRechnung is unrepresentable (BR-DE-14 needs BT-119 percent; O has no percent). Switch the lines to `AE` (§ 13b reverse charge) or `G` (free export), or drop the leitweg / xrechnung_* override and let ZUGFeRD carry them. |
| `BR-CO-09` | Sender VAT ID country prefix doesn't match `sender.country_code` | Correct the prefix or the country code |
| `BR-CO-27` | Sum of line totals doesn't match `unit_price * quantity - discount` | Recompute the line totals client-side |
| `BR-AE-01..10` | `AE` (reverse charge) without recipient VAT ID, or other AE constraints | Provide recipient VAT ID; verify the supply qualifies (cross-border EU service, or § 13b UStG domestic) |
| `BR-IC-01..12` | `K` (intra-community) constraints violated | Recipient must be in a different EU member state with valid VAT ID |
| `BR-O-02` | Outside-scope (O) invoice carrying any VAT identifier | Server-side: Scribo strips all VAT IDs automatically when every line is O. If you see this rule fire, an intermediate party is somehow forwarding stale IDs. |
| `BR-S-08` | `S` line total tax amount doesn't match the BT-118 grouped tax breakdown | Float precision; the script forwards strings — make sure unit_price is a decimal string |

Surface the `path` and `rule` to the user verbatim. Don't try to rewrite the payload silently — the user needs to know which field they got wrong.

## `unsupported_jurisdiction` (400)

The country chain didn't resolve to a supported jurisdiction. Phase 1 supports **DE and US only**. Call `list_jurisdictions.sh` to confirm the live list and re-ask the user.

## Over 500 line items — `invalid_input` (400)

Scribo caps `line_items` at 500 entries. Anything more is surfaced as a standard `invalid_input` response with the path `line_items` and the message `"Array must contain at most 500 element(s)"`. Split into multiple smaller invoices.

*(A dedicated `413 payload_too_large` status is reserved for future revisions — today the cap surfaces as `400 invalid_input`.)*

## Generic 5xx

`error.code: "internal_error"`. Retry with the same idempotency key. If it persists, the response includes a `correlation_id` — pass it to support.
