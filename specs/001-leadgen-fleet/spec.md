# Feature Specification: Local Business Lead Generation Fleet

**Feature Branch**: `001-leadgen-fleet`

**Created**: 2026-07-16

**Status**: Draft

**Input**: User description: "Agentic Local Business Research and Lead Generation system for a digital-marketing / AI-voice-assistant agency. Given a business type and geography, discover local businesses, analyze each against the agency's four product lines (web design + SEO, AI voice assistant, ad campaigns incl. AI video, consultation/custom AI), identify and verify decision-makers, score and classify leads, and deliver evidenced, qualified opportunities. Full technical design in docs/superpowers/specs/2026-07-16-leadgen-fleet-design.md (v4)."

## Clarifications

### Session 2026-07-16

- Q: Should the system of record hold human-updated sales status on delivered leads? → A: Yes, lightweight — a human-owned sales status per business (untouched / contacted / in-talks / customer / bad-lead) plus a do-not-contact flag; used by campaign exclusions and SC-009 measurement; the system never sets it and no pipeline-management features are in scope. *(Superseded in part: do-not-contact is now derived solely from active suppression records, not a business flag — see FR-027.)*
- Q: What is the maximum number of businesses a single v1 campaign must carry through analysis? → A: 300. Requests with a volume cap above 300 are rejected at intake with a clear error; SC-001 is verified at 300 businesses / standard depth.
- Q: How many campaigns must run concurrently in v1 without degradation? → A: 3 (any mix of manual, scheduled, API-triggered); all per-campaign guarantees hold under concurrency and SC-001 timing is verified with 3 running.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run an on-demand research campaign (Priority: P1)

An agency team member fills in a short request — what kind of business to research (e.g., "MedSpas"), where (e.g., zip 78613 or "Austin + 25 km"), how deep to go, and a spending limit. The system discovers matching local businesses, analyzes each one against all four agency product lines, and delivers a ranked list of qualified leads. Every lead carries a fit-profile (four product-fit scores), a classification (hot / warm / cold / disqualified), a recommended sales angle, and the concrete evidence behind every point — e.g., "14 recent reviews mention unanswered calls" with the actual quotes and their sources. Note: hot classification requires verified contact data and is completed by the contact-enrichment story (User Story 2); at this story's own checkpoint, top leads carry a hot-candidate flag pending that verification.

**Why this priority**: This is the product. Without it nothing else has value; with it alone, the agency already replaces hours of manual research per lead.

**Independent Test**: Submit one request for a known business type and area; verify a delivered lead list where every score traces to verifiable evidence and obvious mismatches were filtered out.

**Acceptance Scenarios**:

1. **Given** a valid research request for "dental offices" near a given zip, **When** the campaign completes, **Then** the team receives a ranked lead list where every listed business matches the requested type and area, and every lead shows four product-fit scores with linked evidence.
2. **Given** a discovered business whose customer reviews repeatedly complain about unanswered phones, **When** its lead record is delivered, **Then** the voice-assistant fit is scored high and the record quotes real, verifiable review excerpts as evidence.
3. **Given** a discovered business with no website, **When** it is analyzed, **Then** the absence is recorded as a finding that strengthens its web-design fit (not treated as an analysis error).
4. **Given** a lead about to be classified "hot", **When** an automated devil's-advocate check finds the supporting evidence is stale or misattributed, **Then** the affected evidence is re-verified before the classification stands, and unresolved objections are shown alongside the lead.
5. **Given** a claimed review quote that does not exist in the fetched reviews, **When** evidence is validated, **Then** the fabricated quote is rejected and contributes nothing to any score.

---

### User Story 2 - Get verified decision-maker contacts with spend control (Priority: P2)

For leads that score well, the system identifies the right decision-maker (owner, office manager, etc. — depending on the business type), finds their business contact details, and verifies them (does this person really hold this role at this business? is the email deliverable?). Contact lookups cost real money per lead, so they run only for leads that have already earned it, only within the campaign's budget, and — for manually started campaigns — only after a human approves the spend via a secure approval link.

**Why this priority**: A qualified lead without a reachable buyer is a dead end, but contact data is the most expensive step — it must be gated, not universal.

**Independent Test**: Run a campaign with a small budget cap and approval required; verify that only above-threshold leads get contact enrichment, the cap is never exceeded, unverifiable contacts are marked as such, and nothing was spent before approval.

**Acceptance Scenarios**:

1. **Given** a lead whose opportunity score is below the enrichment threshold, **When** the campaign proceeds, **Then** no paid contact lookup is performed for that lead and it is delivered marked "not enriched — below threshold".
2. **Given** a manually started campaign requiring approval, **When** analysis finishes but no approval is given, **Then** no contact spending occurs, and after the configured waiting period the campaign completes without contact data rather than hanging forever.
3. **Given** a campaign budget cap, **When** cumulative spending reaches it, **Then** remaining paid steps are skipped and marked accordingly, and the campaign still completes with what it has.
4. **Given** a found "owner" whose cited source actually refers to a different business, **When** verification runs, **Then** the contact is marked unverified and contributes nothing to the lead's contactability.
5. **Given** an email address on the agency's do-not-contact list, **When** enrichment encounters it, **Then** it is suppressed and never delivered as an outreach-usable contact.

---

### User Story 3 - Standing campaigns and system integration (Priority: P3)

The agency defines standing ideal-customer profiles (in a shared sheet) that run automatically on a schedule, and external systems can trigger campaigns through an authenticated API call. Businesses already known from earlier campaigns are recognized, not duplicated — their existing records are refreshed and re-scored with current evidence. Retried or duplicate submissions of the same request never create duplicate campaigns.

**Why this priority**: Turns a research tool into an always-warm pipeline, but only matters once on-demand campaigns (P1/P2) produce trusted results.

**Independent Test**: Define one standing profile, let two scheduled runs execute, and verify the second run links and refreshes previously discovered businesses instead of duplicating them; replay the same API request twice and verify exactly one campaign exists.

**Acceptance Scenarios**:

1. **Given** a standing profile in the shared sheet, **When** its schedule fires, **Then** a campaign runs with the profile's parameters without any human involvement, and scheduled campaigns skip the human approval gate by design.
2. **Given** a business discovered by an earlier campaign, **When** a new campaign rediscovers it, **Then** the existing record is linked and re-assessed with fresh evidence — and the older campaign's delivered results remain unchanged.
3. **Given** an API caller submits the same request twice due to a retry, **When** both arrive, **Then** exactly one campaign exists and both submissions receive the same campaign reference.
4. **Given** an unauthenticated or over-budget API request, **When** it is received, **Then** it is rejected with a clear error and no campaign is created.

---

### User Story 4 - Live visibility and delivery surfaces (Priority: P4)

While campaigns run, the team can watch progress on a live dashboard — leads appearing, analyses completing in any order, scores converging as evidence arrives. Key moments arrive as notifications (campaign started, first hot lead with its headline evidence, campaign complete). Each finished campaign delivers a digest of hot leads with their evidence and any unresolved devil's-advocate objections, plus a snapshot export of the full result set.

**Why this priority**: Transparency and delivery polish — valuable, but only once there is something worth watching.

**Independent Test**: Run a campaign and verify dashboard updates appear while it runs (not only at the end), notifications fire at the defined milestones, and the digest lists exactly the hot leads with their evidence and objections.

**Acceptance Scenarios**:

1. **Given** a running campaign, **When** any analysis step finishes, **Then** the affected lead's visible status and scores update without waiting for the whole campaign.
2. **Given** a campaign that finishes with some analyses failed, **When** it completes, **Then** the digest states overall result quality (healthy / partial / degraded) and affected leads are flagged as incomplete rather than silently dropped.
3. **Given** a completed campaign, **When** the digest is produced, **Then** every hot lead shows its recommended sales angle, top evidence, and any unresolved contrarian objection, and the business details shown are those observed during this campaign (not later changes).

---

### Edge Cases

- **Zero discoveries**: campaign completes explicitly with "no results" — not an error, not a hang.
- **Multi-location brands / franchises**: locations sharing a website are linked as related — never automatically merged, and never automatically assumed to have independent buying authority. The system preserves each location and recommends the likely target level (location / franchisee / regional / headquarters). 2–10 location businesses are a primary target, not an edge case.
- **Budget exhausted mid-run**: remaining paid work is skipped and labeled; completed work is preserved; spending never exceeds the cap.
- **Campaign canceled mid-run**: pending work stops; already-started paid operations settle honestly (spend history is never erased); the campaign is marked canceled.
- **A score drops after it opened the gate to paid enrichment**: the gate is re-checked at spending time; no new paid step starts on stale justification.
- **New evidence arrives while a lead is being scored**: the final delivered assessment always reflects the latest evidence; a known-stale assessment is never presented as current.
- **Review platform temporarily unavailable**: affected analysis retries; if it ultimately fails, the lead ships with partial evidence and reduced confidence, flagged as such.
- **The same fact reported through two paths** (e.g., phone complaints feeding both review analysis and phone-presence analysis): counted once, not twice.
- **Approval link leaked or reused**: links are single-use and expiring; a second use or late use is rejected.
- **Identical duplicate events or submissions** (retries anywhere in the system): never create duplicate records, duplicate spending, or double-counted evidence.

## Requirements *(mandatory)*

### Functional Requirements

**Intake & campaign lifecycle**

- **FR-001**: The system MUST accept research requests through three channels — an interactive form, a schedule driven by standing profiles in a shared sheet, and an authenticated API call — all producing the same canonical request (business type, geography, depth, volume cap, budget cap, approval requirement, exclusions).
- **FR-002**: The system MUST deduplicate submissions by caller-provided request identity: replays map to the existing campaign.
- **FR-003**: The system MUST enforce per-campaign volume caps and budget caps (v1: USD only; other currencies rejected with a clear error), with spending guaranteed never to exceed the cap. The v1 system maximum is 300 businesses per campaign; requests exceeding it are rejected at intake with a clear error.
- **FR-004**: The system MUST support campaign cancellation: pending work stops, in-flight paid operations settle honestly, spend history is preserved.
- **FR-005**: A campaign MUST always reach a defined end state — including explicit outcomes for zero discoveries, exhausted budget, denied or expired approval, and excessive analysis failures (reported as quality: healthy / partial / degraded / unusable).

**Discovery**

- **FR-006**: The system MUST discover businesses matching the requested type and geography from at least two public listing sources, merge and deduplicate results, and filter hard mismatches (wrong category, out of area, on exclusion or suppression lists, or human-marked as already engaged per FR-027) before any analysis spend.
- **FR-007**: The system MUST record each business's local search visibility (ranking for its own category and area) as evidence for search-optimization fit.
- **FR-008**: The system MUST recognize previously known businesses across campaigns — linking and refreshing them rather than duplicating — while never altering an earlier campaign's delivered results.
- **FR-009**: The system MUST represent multi-location relationships (same brand, franchise, shared platform) explicitly, with confidence and supporting evidence, including guidance on whether to target the location or the parent.

**Analysis & evidence**

- **FR-010**: The system MUST assess every discovered lead against all four product lines — website/search presence, phone answering and scheduling pain, advertising/creative presence, and overall automation opportunity — producing a four-part fit-profile.
- **FR-011**: Every finding MUST be stored as verifiable evidence with source, date, and a typed value; customer-review quotes MUST be verified to exist in the fetched source before they can influence any score, and fabricated or unverifiable quotes MUST be rejected.
- **FR-012**: Derived findings MUST be linked to the findings they came from, and the same underlying fact MUST NOT be counted twice in a score.
- **FR-013**: Cheap analysis MUST precede expensive analysis: paid deep steps run only for leads whose earlier signals justify them (evidence buys evidence).
- **FR-014**: Review analysis MUST use the most recent reviews (bounded window: newest 200), read oldest-to-newest for trend detection, and summarize recurring problems tied to the product lines — not just the star rating.

**Scoring & qualification**

- **FR-015**: Scoring MUST be deterministic and explainable: identical inputs and configuration always produce identical scores, and every point of every score is traceable to a specific weighted evidence item.
- **FR-016**: The system MUST keep three separate qualification dimensions — opportunity strength, contact reachability, and evidence confidence. **Hot is independently AND-gated on all three dimensions; warm and cold are opportunity-based classifications that display contactability and confidence separately.** Strong contact data MUST NOT compensate for a weak opportunity (or vice versa).
- **FR-017**: Before a lead is first classified "hot", an automated contrarian review MUST challenge the supporting evidence; challenged evidence is re-verified through the original verification method (the contrarian reviewer itself can never alter scores or verification outcomes), and unresolved objections are delivered visibly with the lead.
- **FR-018**: Scoring and qualification rules MUST be versioned and frozen per campaign, so past campaigns remain exactly reproducible after rules change.

**Contact enrichment**

- **FR-019**: Contact identification MUST target the decision-maker role appropriate to the business type, and MUST distinguish and record separately: identity match, role attestation (source really says this person holds this role at this business, recently), and channel deliverability (the email/phone actually works).
- **FR-020**: Contact verification MUST expire; expired verifications no longer count toward reachability.
- **FR-021**: An explicit "decision-maker not found" MUST be an accepted, recorded outcome — the system MUST NOT fabricate contacts under pressure to always answer.
- **FR-022**: Suppression lists MUST be enforced at every level (email, phone, person, business, domain) before contact data is stored as outreach-usable; per-campaign approval (when required) MUST be granted through a single-use, expiring, tamper-proof approval link before any contact spending.

**Delivery & records**

- **FR-023**: The system MUST maintain a durable, authoritative system of record of all campaigns, businesses, leads, evidence, assessments, contacts, and spending — the single source of truth that all delivery surfaces mirror — subject to configured retention, suppression, deletion, and legal policies (see FR-026 and the Assumptions on contact-data retention).
- **FR-024**: Each completed campaign MUST produce its authoritative result set and digest content (hot leads with sales angle, top evidence, unresolved objections, spend summary) as a condition of completion. Secondary deliveries — snapshot export, dashboard mirroring, and milestone notifications (started, first hot lead, complete) — are retried and reported independently; their failure MUST NOT invalidate campaign completion.
- **FR-025**: Delivered campaign results MUST show business details as observed during that campaign, even if the business's current details change later.
- **FR-027**: The system of record MUST carry human-owned sales state at two levels, both set only by humans through an authenticated action (never via the dashboard mirror): (a) an audited per-business sales status (untouched / contacted / in-talks / customer / bad-lead) governing future-campaign eligibility — new campaigns exclude contacted, in-talks, customer, and bad-lead businesses unless the request explicitly overrides; and (b) a per-delivered-lead disposition (accepted / rejected / not-reviewed) which is the data source for SC-009. Do-not-contact is derived from an active suppression record, is always excluded, and MUST NOT be overridable by any ordinary campaign parameter.

**Data rights & retention**

- **FR-026**: The system MUST NOT permanently warehouse third-party review corpora or re-host third-party images; it stores its own derived analysis, short referenced excerpts, and rights-labeled asset references (nothing marked reusable without an explicit rights basis).

### Key Entities

- **Campaign**: one research request and its lifecycle — parameters, frozen rule versions, budget state, approval state, quality outcome, deliverables.
- **Business**: the current identity of a real-world business (location-level), durable across campaigns; relationships link multi-location brands; carries the human-owned sales status (FR-027). Do-not-contact is not a business flag — it derives solely from an active suppression record (single source of truth).
- **Lead**: one business's participation in one campaign — its per-campaign classification, priority, and assessment history; the same business can be a lead in many campaigns with different outcomes.
- **Evidence item**: one immutable, dated, sourced finding with a typed value; linked to what it was derived from; verified or rejected by recorded verification events.
- **Assessment**: a point-in-time scoring of a lead — fit-profile, three qualification dimensions, per-point score breakdown; supersedable, never silently overwritten.
- **Contact**: a person, their roles at businesses, their channels — each with separately verified, expiring attestations; subject to suppression.
- **Budget transaction**: one reserved-then-settled (or released) unit of spending, attributable to the exact operation that incurred it.
- **Approval**: a single-use, expiring authorization for a campaign's paid enrichment.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A standard-depth campaign of up to 300 businesses for a common business type in a metro area goes from request to delivered digest in under 2 hours at the 95th percentile on the pinned reference deployment (approval waiting time excluded), without human intervention beyond an optional approval click.
- **SC-002**: Manual research effort is reduced from roughly 1–2 hours per qualified lead to under 5 minutes of human review time per delivered hot lead.
- **SC-003**: 100% of delivered scores are explainable: for any lead, a reviewer can see every point, its weight, and the specific evidence behind it.
- **SC-004**: 100% of quoted review evidence in delivered leads is verifiable in the cited source; zero fabricated quotes reach a digest.
- **SC-005**: No campaign ever spends beyond its budget cap — measured across all campaigns, including crashes and retries.
- **SC-006**: 100% of delivered outreach-usable emails passed deliverability verification, and zero delivered contacts appear on any suppression list.
- **SC-007**: Deterministic replay — recomputing any lead's assessment from its stored evidence, stored verification state, and frozen rules reproduces exactly identical score components, scores, and classification. (Fresh re-research of the same businesses is a separate regression check with tolerance bands, since the outside world changes.)
- **SC-008**: Within a single campaign, duplicate business entities in the delivered list are below 2%. Across repeated campaigns over the same territory, at least 98% of rediscovered businesses attach to their existing business record instead of creating a new one.
- **SC-009**: At least 60% of *reviewed* delivered hot leads are accepted by the sales team as worth pursuing — accepted ÷ (accepted + rejected) from per-lead dispositions (FR-027); not-yet-reviewed leads enter neither numerator nor denominator. Measured during the pilot period.
- **SC-010**: A campaign whose analyses partially fail still delivers its completed portion, correctly labeled — zero campaigns hang indefinitely or end in an undefined state.
- **SC-011**: Three campaigns (any mix of manual, scheduled, API-triggered) run concurrently with every per-campaign guarantee intact — budget isolation, no cross-campaign interference, correct completion — and SC-001's timing holds while three are running.

## Assumptions

- Target businesses are US-based local SMBs; reviews and websites are predominantly English; budgets are USD-only in v1.
- Scope ends at qualified, evidenced, contactable leads — outreach (emailing, calling, sequencing) is a separate future project consuming this system's output.
- Phone-answering analysis in v1 uses passive signals only (reviews, booking capability, hours); an active probe-caller is a future drop-in upgrade behind the same interface, pending its own compliance review.
- Asset collection in v1 gathers rights-labeled references only; automated image tagging is a future upgrade.
- The agency operates the paid data-provider accounts (business listings, contact discovery, email verification) and LLM provider accounts this system draws on; per-unit costs are configured, not discovered.
- The complete technical design (architecture, data model, transactional guarantees, security model) is maintained separately in `docs/superpowers/specs/2026-07-16-leadgen-fleet-design.md` (v4) and governs implementation planning.
- Contact-data retention periods will be set per target-geography requirements during implementation.
