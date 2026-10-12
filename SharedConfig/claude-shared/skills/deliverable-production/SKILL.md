---
name: deliverable-production
description: End-to-end process for producing polished business deliverables — reports, decision memos, meeting-preparation packs, proposals, tender responses, presentations, spreadsheets. Use when a document, deck, or spreadsheet is the final deliverable and quality matters: research, outline, draft, build with document tooling, verify.
---

# Producing business deliverables

The deliverable is the product. Research and drafting are delegated; structure,
judgment, and the final read-through stay with the orchestrator.

> **Branded templates win over generic output.** If a plugin provides the
> organization's template or document workflow (for example a skill for decks
> on the corporate template, or for editing .docx files), use it instead of
> generic generation. This skill supplies the process around it.

## 1. Clarify the brief

Before producing anything, pin down: purpose, audience, the decision or action
sought, format, language, length, and deadline. If the user has not said which
decision the document should enable, that is the first question — most weak
deliverables are weak because this was never settled.

## 2. Research first

Dispatch research in parallel before drafting:

- `doc-researcher` for external facts — market, vendors, standards, pricing,
  documentation
- `code-scout` or `Explore` for internal repositories and existing material
- Files the user supplied: read them directly

Brief each agent per the handoff protocol in CLAUDE.md (goal and why, context,
scope, deliverable, done when). Write the clarified brief from step 1 to
`<scratchpad>/handoffs/<task>.md` and pass the path. Research agents return
their findings inline; copy them verbatim into that file when later steps need
them.

Collect facts with sources. Every number that will appear in the deliverable
needs a traceable origin.

## 3. Outline before drafting

Get agreement on the structure, then write. For decision material use a
recognizable structure:

**Situation → Options → Assessment → Recommendation → Consequences**

For a deck, write the **storyline first**: one message per slide, expressed as a
full sentence. If the sentences read in order do not make the argument, no amount
of slide design will fix it. Only then decide what each slide shows.

## 4. Draft in markdown

Draft content as markdown before touching any document tooling. Content review
is much cheaper before formatting, and restructuring a deck after it is built is
expensive. Show the draft to the user when the deliverable is substantial.

## 5. Build the artifact

Use the `document-skills` plugin: `pptx` for presentations, `docx` for
documents, `xlsx` for spreadsheets and models, `pdf` for reading, extracting, or
producing PDFs. Prefer it over hand-rolled generation.

Formatting rules that hold regardless of tool: one consistent type hierarchy;
no more than two accent colors; tables over paragraphs for comparisons; every
chart labelled with its unit and source; no slide that needs the speaker to be
comprehensible if the deck will be sent rather than presented.

Norwegian audiences get bokmål — load `norwegian-business-writing` for the prose.

## 6. Verify

Dispatch `verifier` — a deliverable always counts as non-trivial. Pass it the
brief path (with the research findings in it) and the draft or file, not a
summary.
It checks:

- every factual claim against its source
- internal consistency — numbers that appear twice must match, terminology is
  stable, the recommendation follows from the assessment
- completeness against the original request
- for decks: that the storyline holds when read without a speaker

Fix what comes back before delivering. Do not deliver with known open errors.

## 7. Deliver

Hand over the file with a one-paragraph summary: what was produced, which
sources it rests on, which assumptions you made, and any open questions the user
needs to close.

## Templates

**Decision memo**: Bakgrunn → Alternativer → Vurdering → Anbefaling →
Konsekvenser (cost, risk, resources, timeline) → Beslutning som bes tatt.

**Meeting-preparation pack**: objective of the meeting → participants and their
interests → agenda with time budget → talking points and supporting facts →
anticipated objections with responses → risks → desired outcome and fallback.

**Slide-deck storyline checklist**:
- One message per slide, written as a sentence
- The sentences read in order form the argument
- Executive summary slide up front for decks over ~10 slides
- Every claim slide is backed by a data or evidence slide, or drops the claim
- Closing slide states the ask, not a thank-you
