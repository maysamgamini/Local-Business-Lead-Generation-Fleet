# Local Business Lead Generation Fleet

An agentic lead-research system for a digital-marketing / AI-voice-assistant agency, built as a **choreographed fleet of n8n workflows over a PostgreSQL transactional core**. Given a business type and geography, it discovers local businesses, analyzes each against four product lines (web/SEO, AI voice assistant, ads/AI video, consulting) with verifiable evidence, identifies and verifies decision-makers under hard budget caps, and delivers scored, classified, evidence-backed leads.

**Design principle**: n8n owns behavior, Postgres owns correctness. Every state mutation goes through SECURITY DEFINER SQL functions (fenced work queue, transactional outbox, max-billable budget authorization); every score traces to verified evidence; LLM critics challenge hot leads before they ship.

## Documentation map

| Artifact | Path |
|---|---|
| Technical design (v4 + addendum, 4 review rounds) | `docs/superpowers/specs/2026-07-16-leadgen-fleet-design.md` |
| Feature spec (user stories, FRs, success criteria) | `specs/001-leadgen-fleet/spec.md` |
| Implementation plan | `specs/001-leadgen-fleet/plan.md` |
| Decisions & rationale | `specs/001-leadgen-fleet/research.md` |
| Data model | `specs/001-leadgen-fleet/data-model.md` |
| Contracts (request, SQL API, services, scoring defaults) | `specs/001-leadgen-fleet/contracts/` |
| Validation guide | `specs/001-leadgen-fleet/quickstart.md` |
| Task breakdown (63 tasks, 7 phases) | `specs/001-leadgen-fleet/tasks.md` |

## Status

Spec kit package complete and cross-audited; implementation not yet started (Phase 1 begins with the repository skeleton and database core).

## Stack

Self-hosted n8n (queue mode, external task runners) · PostgreSQL 16 (`leadgen_db`) · Google Places · SerpAPI · Apify · Apollo · Hunter · PageSpeed Insights · Claude / GPT / Gemini (cross-family critics) · Airtable (read-only dashboard) · Slack

> Note: `.mcp.json` is intentionally untracked (contains live credentials). Copy `.mcp.json` from a teammate or recreate it locally to use the n8n MCP server.
