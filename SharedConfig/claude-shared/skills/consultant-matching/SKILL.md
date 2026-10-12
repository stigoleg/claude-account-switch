---
name: consultant-matching
description: Match consultants or candidates against a customer request, tender, or role requirements: analyze CVs and profiles, rank candidates against requirements, identify strengths, weaknesses, and gaps, and produce customer-facing candidate summaries or a presentation. Use for staffing requests, team composition for bids, recruitment shortlisting, or any comparison of CVs against a requirement spec.
---

# Consultant and candidate matching

An orchestration procedure. Fact extraction is delegated; scoring and selection
stay with the orchestrator.

> **Check for workplace tooling first.** If a plugin provides staffing or CV
> tooling for this organization (staffing, CV database, competence or
> reference skills), use it for the data and follow its house rules; this skill
> supplies the surrounding process.

## 1. Structure the requirements

Turn the request into an explicit requirement matrix before looking at any CV:

| Field | Notes |
|---|---|
| Must-have | Absolute filters — technology, certification, clearance, language |
| Should-have | Weighted, scored |
| Nice-to-have | Tie-breakers |
| Role & seniority | Architect, lead, senior/mid, expected autonomy |
| Domain | Industry experience where it actually matters |
| Practicalities | Start date, scope (%), location/on-site, language, duration |
| Evaluation criteria | If the customer states weighting or scoring rules, use theirs |

If the request is ambiguous about a must-have, ask before ranking — a wrong
filter silently removes the best candidate.

## 2. Gather candidate material

Sources, in order of reliability: the customer-supplied requirement document;
CV files provided by the user; CV databases reachable through available plugin
tools (for example a CV-database plugin, when present);
internal notes and references the user supplies. Check what tooling is actually
available in the session rather than assuming.

## 3. Extract normalized profiles (delegate)

With more than about three candidates, dispatch parallel subagents — one per
candidate, or one per small batch. Each mandate: extract facts, do not score.
Write the requirement matrix to `<scratchpad>/handoffs/<task>.md` and pass the
path, so every agent works from the same matrix. Each returns its profile
inline; copy the profiles verbatim into the handoff file for later steps.
Use `general-purpose` agents for this; `code-scout` maps source code and is the
wrong tool for CVs and documents.

Each agent returns a normalized profile:

- Roles held, with duration and recency
- Technologies and tools, with years and most recent use
- Industries and domains
- Certifications and education
- Languages
- **Evidence per requirement**: for each requirement in the matrix, the concrete
  CV passage that supports it, cited by project or section — or "not found"
- Anything notable: gaps in timeline, very short assignments, unusually broad
  claims without project backing

Recency and *depth of evidence* matter more than a skills list. A skill listed
in a tag cloud but absent from every project description is not evidence.

## 4. Score and rank (orchestrator)

Scoring is judgment and stays in the main session, where the whole field is
visible. Apply must-have filters first, then score should-haves against the
weighting. Produce a comparison table: candidates as rows, requirements as
columns, with a short evidence note per cell. Rank, and state explicitly what
separates the top candidates from each other — a ranking without a stated
discriminator is not a recommendation.

For each shortlisted candidate, write: strengths (with evidence), gaps against
the requirements, and how a gap could be mitigated (team composition, ramp-up,
pairing) — mitigations are for internal use unless the customer asked.

## 5. Produce output

**Internal**: ranked table, per-candidate strengths/gaps, recommendation with
reasoning, and who you are deliberately not proposing and why.

**Customer-facing**: one summary per proposed candidate. Norwegian bokmål via
`norwegian-business-writing` unless another language is requested. Every claim
must be verifiable in the CV — no adjectives the CV does not support, no
inflated seniority, no invented domain experience. If the customer will see it,
assume they will check it.

Before customer-facing output leaves the session, have `verifier` check every
claim against the CVs (pass it the handoff file with matrix and profiles).

### Candidate one-pager structure

1. Name, role, years of experience, availability
2. Two-to-three sentence summary aimed at *this* request
3. Relevance to the requirements — bulleted, mapped to the customer's wording
4. Selected assignments (2–4): customer/domain, role, technologies, outcome
5. Certifications, education, languages
6. Optional: short reference or quote, if provided

## 6. Presentation

If a deck is requested, hand over to the `deliverable-production` skill and the
`document-skills` plugin (pptx). Standard structure: understanding of the
request → proposed team → one slide per candidate → why this team → practical
terms (availability, price if requested, start date).

## Discipline

- Do not oversell. A customer-facing profile that overstates is a liability.
- Keep facts and assessment separate; label assessment as assessment.
- Say when no candidate meets a must-have, rather than promoting the least-bad
  fit silently.
- Handle CV data as personal data: use it for this assessment, do not spread it
  further than the request needs.
