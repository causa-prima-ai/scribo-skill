#!/usr/bin/env python3
"""Minimal mock of the Scribo public API for the skill smoke test.

Implements just enough of /api/v1/* to drive request -> redeem -> create ->
download end to end, plus the failure shapes the scripts must map to exit
codes. Binds 127.0.0.1 on $PORT (default 8799). No external deps.
"""
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

CHALLENGE_ID = "11111111-1111-4111-8111-111111111111"
GOOD_CODE = "234567"
VERIFICATION_TOKEN = "vtok-mock-abcdef"
PDF_BYTES = b"%PDF-1.5\n%mock-invoice\n"


class Handler(BaseHTTPRequestHandler):
    # Counts every POST /api/v1/invoices attempt (regardless of outcome) so the
    # smoke test can prove the verify-then-persist contract: the tokenless path
    # must never hit this endpoint. Class-level — shared across per-request
    # handler instances.
    invoice_post_attempts = 0

    def log_message(self, *_):  # quiet
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _drain(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(n) if n else b""

    def do_GET(self):
        p = self.path
        if p == "/__debug/invoice-post-attempts":
            return self._json(200, {"count": Handler.invoice_post_attempts})
        if p == "/api/v1/jurisdictions":
            return self._json(200, [
                {"jurisdiction": "DE", "formats": ["zugferd_comfort"], "default_format": "zugferd_comfort"},
                {"jurisdiction": "US", "formats": ["plain_pdf"], "default_format": "plain_pdf"},
            ])
        path, _, query = p.partition("?")
        params = dict(kv.split("=", 1) for kv in query.split("&") if "=" in kv)
        if path.startswith("/api/v1/invoices/") and path.endswith("/download"):
            # Signed links only: the token is the whole credential.
            token = params.get("t")
            if token == "expired":
                return self._json(403, {"error": {"code": "download_link_expired", "message": "This download link has expired."}})
            if token != "signed-ok":
                return self._json(403, {"error": {"code": "download_link_invalid", "message": "A signed download link is required."}})
            self.send_response(200)
            self.send_header("Content-Type", "application/pdf")
            self.send_header("Content-Length", str(len(PDF_BYTES)))
            self.end_headers()
            self.wfile.write(PDF_BYTES)
            return
        if path.startswith("/i/") and path.endswith("/download"):
            # Scribo's browser route sends a refused link to an explanation page.
            self.send_response(303)
            self.send_header("Location", "/i/link-unavailable?reason=expired")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path.startswith("/api/v1/invoices/"):
            # Sender-only read: no token is 401, another sender's or an unknown
            # invoice the same 404.
            if self.headers.get("X-Email-Verification-Token") != VERIFICATION_TOKEN:
                return self._json(401, {"error": {"code": "email_verification_required", "message": "Email verification required."}})
            invoice_id = path.rsplit("/", 1)[-1]
            base = "http://127.0.0.1:%s" % os.environ.get("PORT", "8799")
            links = {
                "inv-mock-1": base + "/api/v1/invoices/inv-mock-1/download?t=signed-ok",
                "inv-expired": base + "/api/v1/invoices/inv-expired/download?t=expired",
                "inv-redirect": base + "/i/inv-redirect/download?t=expired",
            }
            if invoice_id not in links:
                return self._json(404, {"error": {"code": "invoice_not_found", "message": "Invoice not found."}})
            return self._json(200, {
                "invoice_id": invoice_id,
                "format": "zugferd_comfort",
                "download_url": links[invoice_id],
                "download_url_expires_at": "2099-01-01T00:15:00Z",
            })
        return self._json(404, {"error": {"code": "not_found", "message": p}})

    def do_POST(self):
        body = self._drain()
        p = self.path
        if p == "/api/v1/scribo/email-verifications":
            # Echo the locale header so the smoke test can prove SCRIBO_LOCALE
            # reaches the API (the real server feeds it into resolveOutboundLocale
            # to pick the verification-email + confirmation-page language).
            return self._json(202, {
                "challenge_id": CHALLENGE_ID,
                "expires_at": "2099-01-01T00:00:00Z",
                "next_request_allowed_at": "2099-01-01T00:00:30Z",
                "received_scribo_locale": self.headers.get("X-Scribo-Locale"),
            })
        if p.startswith("/api/v1/scribo/email-verifications/") and p.endswith("/redeem"):
            try:
                code = json.loads(body or b"{}").get("code")
            except ValueError:
                code = None
            # Only the known challenge + correct code redeems; everything else
            # (wrong code, unknown/expired/revoked challenge) is the uniform
            # verification_invalid, mirroring the real anti-enum behavior.
            if p == "/api/v1/scribo/email-verifications/%s/redeem" % CHALLENGE_ID and code == GOOD_CODE:
                return self._json(200, {"verification_token": VERIFICATION_TOKEN, "expires_at": "2099-01-01T00:30:00Z"})
            return self._json(400, {"error": {"code": "verification_invalid", "message": "Verification challenge invalid, expired, or revoked."}})
        if p == "/api/v1/invoices":
            # Count before the token check so a regression that POSTs without a
            # token (and gets the 401) is still caught by the smoke test.
            Handler.invoice_post_attempts += 1
            token = self.headers.get("X-Email-Verification-Token")
            if not token:
                return self._json(401, {"error": {"code": "email_verification_required", "message": "Email verification required."}})
            return self._json(201, {
                "invoice_id": "inv-mock-1",
                "document_id": "doc-mock-1",
                "format": "zugferd_comfort",
                "download_url": "http://127.0.0.1:%s/api/v1/invoices/inv-mock-1/download?t=signed-ok" % os.environ.get("PORT", "8799"),
                "download_url_expires_at": "2099-01-01T00:15:00Z",
                "validator_summary": {"valid": True, "validator": "mock", "errors": []},
                "received_verification_token": token,
            })
        return self._json(404, {"error": {"code": "not_found", "message": p}})


def main():
    port = int(os.environ.get("PORT", "8799"))
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
