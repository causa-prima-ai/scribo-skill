<img width="3840" height="1920" alt="A2 _ Claude Skill" src="https://github.com/user-attachments/assets/e3d5067e-b72f-41fe-bf2f-0c8584ac64f5" />

# Scribo Skill
> Free, AI-native e-invoicing — from Claude, ChatGPT & Codex.

## Contents

- [What is Scribo?](#what-is-scribo)
- [What is the Scribo skill?](#what-is-the-scribo-skill)
  - [Demo](#demo)
- [Getting started](#getting-started)
  - [Quickstart](#quickstart)
  - [Setup & prerequisites](#setup--prerequisites)
- [Usage](#usage)
  - [How it works](#how-it-works)
  - [Examples](#examples)
- [Compliance](#compliance)
- [FAQ](#faq)
- [Resources](#resources)
- [License](#license)

## What is Scribo?

Scribo is a free, conversational e-invoicing tool. Describe an invoice in plain language — "bill Acme GmbH €2,400 for May design work" — and it drafts a structured invoice for you to review, download and send directly.

Just ask your AI agent about Scribo: it ships as an MCP server, a CLI, and a Claude/Codex skill, alongside a public HTTP API and a web app. Free forever — no credit card. You just need a sender email.

**Built by Causa Prima** — Scribo is built by [**Causa Prima**](https://causaprima.ai/), a company building agentic AI for the CFO office. It's our first freely available skill — an early glimpse of what we're building.

## What is the Scribo skill?

The Scribo skill teaches your AI assistant to create invoices for you. Add it once, then just ask — _"draft an invoice for 3 days of consulting at €1,200/day"_ — and your assistant gathers the details and hands back a finished, compliant invoice in the chat, ready to download and send. No new app to learn, no forms to fill in.

It works wherever you already work: **Claude** (Claude.ai, Claude Code, Claude Desktop), **ChatGPT**, and the **OpenAI Codex CLI**. Free, no signup — your email is all you need.

### Demo

https://github.com/user-attachments/assets/b6603478-4702-4941-bf01-bf4c04bbb098

## Getting started

### Quickstart

If you use **Claude Code**, you're two commands away:

```sh
/plugin marketplace add causa-prima-ai/scribo-skill
/plugin install scribo-skill@scribo-skill
```

Then just ask:

> Draft an invoice from Example GmbH to Acme GmbH for 3 days of consulting at €1,200/day, 19% VAT.

The skill triggers automatically, asks for anything it's missing, verifies your sender email once (a 6-digit code arrives by email), and returns a downloadable invoice.

On Claude.ai, Claude Desktop, ChatGPT, or Codex CLI instead? Use the matching install method below.

### Setup & prerequisites

**Prerequisites.** Hosted assistants (Claude.ai, Claude Desktop, ChatGPT) need nothing installed. For local installs (Claude Code, Codex CLI) you'll need `bash` 4+, `curl`, and `jq` on your machine (`openssl` optional).

Pick the method that matches how you run your assistant:

| Method | Works with |
|---|---|
| **Plugin install** | Claude Code |
| **`.zip` upload** | Claude.ai, Claude Desktop, ChatGPT |
| **`git clone`** | OpenAI Codex CLI, manual Claude Code |

**Plugin install — Claude Code**

```sh
/plugin marketplace add causa-prima-ai/scribo-skill
/plugin install scribo-skill@scribo-skill
```

The skill activates as `/scribo-skill:scribo` and triggers automatically when you ask to draft an invoice.

**`.zip` upload — Claude.ai, Claude Desktop, ChatGPT**

1. Download `scribo-skill.zip` from the [latest release](https://github.com/causa-prima-ai/scribo-skill/releases/latest).
2. Upload it:
   - **Claude.ai / Claude Desktop** — Settings → Customize → Skills → **Upload skill**.
   - **ChatGPT** — **New skill → Upload from your computer**.

One upload covers new chats on that account.

**`git clone` — Codex CLI, manual Claude Code**

Clone once, then copy the inner `skills/scribo` folder into your assistant's skills directory:

```sh
git clone https://github.com/causa-prima-ai/scribo-skill /tmp/scribo-skill
cp -r /tmp/scribo-skill/skills/scribo ~/.codex/skills/scribo     # Codex CLI
# or  .claude/skills/scribo     (Claude Code — this project)
# or  ~/.claude/skills/scribo   (Claude Code — all projects)
```

`SKILL.md` must end up at `…/scribo/SKILL.md`. Restart your assistant afterward.

**Verify.** Ask your assistant: _"list the jurisdictions Scribo supports."_ You should get back a list of supported countries.

Full install detail (Cowork, team installs, troubleshooting): [scribo.causaprima.ai/docs/skill](https://scribo.causaprima.ai/docs/skill).

## Usage

### How it works

You don't fill in a form — you describe the invoice and your assistant does the rest. When you ask for an invoice, it:

1. **Gathers the details** in a short back-and-forth — who's billing (your business name, address, tax/VAT ID, and the email the invoice is sent from), who's being billed (their name, address, and billing email), and the line items, amounts, and currency.
2. **Confirms the tax treatment** with you — standard-rated, reverse-charge, exempt, and so on. Scribo never guesses your VAT category; you decide.
3. **Verifies your email once.** The first time you invoice from a new sender address, Scribo emails a 6-digit code that you paste back to confirm the address is yours. It's reused for ~30 minutes, so you're not asked again on every invoice.
4. **Generates and validates** the invoice against EN 16931, then hands back a download link — a PDF with the matching e-invoice XML embedded — and emails you a copy.
5. **Explains anything missing** in plain language — if a required detail is absent, it tells you what to add rather than failing silently.

You stay in the conversation the whole time; there's no separate app or dashboard.

### Examples

Things you can say to your assistant once the skill is installed:

**German B2B invoice (ZUGFeRD)**

> Invoice Beispiel GmbH for 12 hours of web development at €110/hour, 19% VAT. I'm Example GmbH, VAT ID DE123456789.

Returns a ZUGFeRD invoice — a PDF a human can read, with EN 16931 XML embedded for the recipient's accounting system.

**German public-sector invoice (XRechnung)**

> Same client, but it's for the City of Munich — the Leitweg-ID is 04011000-1234512345-06.

A Leitweg-ID tells Scribo this is a B2G invoice, so it produces XRechnung, the format German public authorities require.

**US invoice (plain PDF)**

> Bill Acme Inc. $4,000 for a brand strategy workshop.

A clean PDF invoice — no e-invoice XML, since the US has no e-invoicing mandate.

**Re-download a past invoice**

> Send me the download link for the invoice I made for Beispiel GmbH last week.

Scribo returns a fresh download link for an invoice you've already generated, once you confirm the sender email. The link is valid for 15 minutes.

## Compliance

Scribo emits invoices conforming to **EN 16931**, the European e-invoicing standard, with the relevant national CIUS. Every EN 16931 output (ZUGFeRD, XRechnung) is validated against the **Invopop**-hosted validator at generate-time — output that fails the rule set never reaches the user. US plain PDFs carry no EN 16931 XML and are rendered directly.

**Supported formats**

| Jurisdiction | Format | Status |
|---|---|---|
| Germany (B2B) | **ZUGFeRD** COMFORT (PDF/A-3 hybrid + CII XML) | ✅ Live |
| Germany (B2G) | **XRechnung** (UBL / CII) | ✅ Live |
| United States | Plain PDF (no XML, no e-invoice claim) | ✅ Live |
| France | **Factur-X** EN 16931 | 🔜 Coming soon |
| Spain | **Facturae** | 🔜 Coming soon |
| Belgium / NL / LU / AT | **Peppol BIS 3.0** UBL | 🔜 Coming soon |

*Disclaimer: Scribo generates and validates compliant invoice documents. It is **not tax or legal advice** — Scribo does not determine your tax obligations, VAT treatment, or filing requirements.*

## FAQ

<details>
<summary><strong>Is Scribo really free?</strong></summary>

Yes — free forever. No credit card, no subscription, no paywall before your first invoice. You just need a sender email.

</details>

<details>
<summary><strong>Do I need an account or signup?</strong></summary>

No signup form. On your first invoice, Scribo verifies the sender email — a 6-digit code (or one-click link) arrives at that address; one verification covers ~30 minutes of invoicing. The same email doubles as your magic-link login for re-downloads later.

</details>

<details>
<summary><strong>Which countries and formats are supported?</strong></summary>

Live today: **Germany** — ZUGFeRD (B2B) and XRechnung (B2G) — and the **United States** (plain PDF). Coming next: **France** (Factur-X), **Spain** (Facturae), and **Belgium / NL / LU / AT** (Peppol BIS 3.0).

</details>

<details>
<summary><strong>What does "EN 16931-compliant" actually mean here?</strong></summary>

Every EN 16931 output (ZUGFeRD, XRechnung) is validated against the **EN 16931-1:2017** rule set (via the Invopop-hosted validator) before it's returned. Output that fails validation never reaches you. US plain PDFs carry no EN 16931 XML, so no schematron validation applies.

</details>

<details>
<summary><strong>Is the US version compliant?</strong></summary>

Yes. There is no US e-invoicing mandate, so Scribo produces a fully compliant plain PDF.

</details>

<details>
<summary><strong>Does Scribo give tax or legal advice?</strong></summary>

No. Scribo generates and validates compliant invoice *documents*. It does not determine your tax obligations, VAT treatment, or filing requirements.

</details>

<details>
<summary><strong>How do AI agents / LLMs use Scribo?</strong></summary>

Scribo is built to be operated by an agent. It ships as an **MCP server**, a **CLI**, and a **Claude/Codex skill**, plus a public **HTTP API** and a **web app** — all on the same backend. An agent can discover Scribo, create an invoice, and return the file on a user's behalf.

</details>

<details>
<summary><strong>Who builds Scribo?</strong></summary>

[Causa Prima](https://causaprima.ai/) — a company building agentic AI for the CFO office. Operated by Causa Prima Germany GmbH, Munich.

</details>

## Resources

- **Web app** — [scribo.causaprima.ai](https://scribo.causaprima.ai)
- **Documentation** — [scribo.causaprima.ai/docs](https://scribo.causaprima.ai/docs)
- **Compliance & trust** — [scribo.causaprima.ai/compliance](https://scribo.causaprima.ai/compliance)
- **Causa Prima** — [causaprima.ai](https://causaprima.ai)

**Other Scribo surfaces**

- Skill (Claude / Codex) — [`scribo-skill`](https://github.com/causa-prima-ai/scribo-skill) · [docs](https://scribo.causaprima.ai/docs/skill)
- MCP server — [`scribo-mcp`](https://github.com/causa-prima-ai/scribo-mcp) · [docs](https://scribo.causaprima.ai/docs/mcp)
- CLI — [`scribo-cli`](https://github.com/causa-prima-ai/scribo-cli) · [docs](https://scribo.causaprima.ai/docs/cli)
- HTTP API — [`scribo-api-docs`](https://github.com/causa-prima-ai/scribo-api-docs) · [docs](https://scribo.causaprima.ai/docs/api)
- Brand hub — [`scribo`](https://github.com/causa-prima-ai/scribo)

## License

Proprietary — `UNLICENSED`. © Causa Prima Germany GmbH. All rights reserved. Distributed for use against the public Scribo API; not open-source. See [LICENSE](./LICENSE).

