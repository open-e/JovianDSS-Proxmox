# Design Documents — Format & Conventions

This folder holds the **design documents** for the JovianDSS Proxmox plugin: the
detailed "how and why" of non-trivial changes — the mechanism, the reasoning,
the risks, and what would (or did) change. This README describes how those
documents are written so a new one reads like the existing ones.

It is itself the one non-numbered file here; everything else is a numbered
design document.

## What a design document is (and is not)

- **Design document** (this folder) — a thorough treatment of *one* change: the
  problem, the mechanism, the alternatives, the risks, the file-level impact. It
  is a thinking artifact first and a record second; it evolves from proposed to
  implemented in place.
- **ADR** (`../adr/`, e.g. `0001-add-chap-auth.md`) — a short *decision* record:
  what was chosen and why, accepted at a point in time. A design document
  references its ADR when one exists (see `0002-chap-auth-design.md` →
  `../adr/0001-add-chap-auth.md`); the ADR says *decide to do X*, the design
  document says *here is exactly how X works*.
- **User / operator docs** (`../*.md` — Quick-Start, Plugin-configuration, …) —
  how to *use* the plugin. Not design documents; different audience.

## Filename & numbering

```
NNNN-<kebab-slug>.md
```

- **`NNNN`** — a 4-digit, zero-padded, strictly sequential number
  (`0001`…`0008`). The next document takes the next integer; numbers are never
  reused or reordered.
- **`<kebab-slug>`** — a short lowercase-hyphenated topic
  (`password-resolution-through-ctx`, `sensitive-data-transfer-control`).
- **`-design` suffix** — common but not universal: `0001-cluster-lock-storage-design.md`
  and `0002-chap-auth-design.md` carry it; `0003-jdssc-target-sessions.md`,
  `0005-password-resolution-through-ctx.md`, `0007-volume-activation-with-reactivation.md`
  do not. Prefer including it for new documents for consistency, but it is not
  required.

To pick the next number: `ls docs/design/` and add one to the highest.

## Status lifecycle

A document moves through — and records — these states:

| Status | Meaning |
|---|---|
| `PROPOSED` | Under consideration; no code written. Recommends an approach; may leave the decision open. (`0008`) |
| `ACCEPTED` | Approach signed off; may or may not be built yet. (`0004`, `0006`, `0007`) |
| `IMPLEMENTED` | Landed in the tree. Often combined: `(ACCEPTED, IMPLEMENTED)`. (`0003`, `0005`) |

Status appears in **two** places:

1. **In the title**, parenthesised:
   `# Volume Activation with Reactivation — Design Document (ACCEPTED)`.
   A document with no explicit status (e.g. `0001`, `0002`) is understood to
   describe implemented behavior.
2. **In a leading blockquote callout** immediately under the title, which
   records the detail — what landed, what is deferred, branch names, how it was
   verified, forward pointers, and optionally dates (a document may prefer the
   timeless *current*/*proposed* framing instead — see
   [Guiding principles](#guiding-principles); `0008`):

   ```markdown
   > **Status: accepted (2026-07-03) — implemented (2026-07-03): all Table 3
   > changes landed, unit tests added (…), verified end to end against the live
   > Pool-2 appliance. Deferred to the jdssc-lock work: …
   ```

   For partially-landed work the callout is where "what is done vs deferred"
   lives, with links to the sections and other documents that carry the rest
   (see `0005`'s callout).

## Document structure

Sections are drawn from the menu below. **Core** sections appear in almost every
document; **optional** ones are used when the change warrants them. Order
generally follows this list.

### Core

- **Overview** — one or two paragraphs: what the change is and why, in plain
  terms. State the layers it spans if it crosses Perl / jdssc / REST
  (`0002` opens by naming its three layers).
- **Problem** (or **Background**) — the current state and precisely what is
  wrong with it, with `file:line` evidence. On evolving documents, resolved
  bullets are kept and struck through (see [House style](#house-style)).
- **Design** — the core. Subsection it (`### …`) per mechanism. Show the shape
  with short code blocks; explain *why* the shape is what it is, not just what it
  is.
- **Consequences** — what becomes true once this lands (behavioral and
  structural), good and neutral.
- **Risks & Backward Compatibility** — often split into **Preserved (low risk)**
  and **Risks** (numbered, most-severe first). Each risk: the concrete failure,
  why it is or is not a problem, and the guard. This is the section reviewers
  read first; do not thin it.
- **Files That Would Change** (or **… That Change**) — a table, one row per
  file, describing the edit. Include this document's own row. Use the conditional
  ("would change") while proposed; switch to present/past once implemented, and
  annotate landed rows.

### Optional (use when they earn their place)

- **Table of Contents** — anchored links, on longer documents (`0005`–`0008`).
  Skip on short ones (`0001`, `0002`, `0004`).
- **Key Observation** — the single insight the design pivots on, called out
  before the Design so the mechanism reads as obvious (`0005`); for a hardening
  design it also carries the linkable catalog of sensitive data and exposure
  vectors (`0008`).
- **Function / Interface / Signature Changes**, **New Functions**,
  **Obsolete Functions** — for changes that reshape the code surface (`0005`).
- **Alternatives Considered** — approaches weighed and **rejected**, each with the
  reason (`0008`'s stdin / fd). Record the *worked* alternative, not a strawman.
  Genuinely-viable alternatives instead go in **Design** as co-equal variants (see
  [Guiding principles](#guiding-principles)).
- **Testing** — unit / e2e / live plan, and which existing testcases move
  (`0008`).
- **Relationship to Other Designs / Other Work** — cross-links to the documents
  this one depends on, enables, or sits beside (`0005` ↔ `0006`).
- **Open Questions** — unresolved decisions, numbered. As they close, keep the
  entry and mark it resolved (see below), so the document doubles as a decision
  record.

## Guiding principles

Cross-cutting habits distilled from writing these documents (`0008` exemplifies
most):

- **Overview states purpose; Design states mechanism.** The Overview says *why* —
  the problem and the boundaries it spans — and, while `PROPOSED`, does not commit
  to the chosen mechanism, so it survives a change of approach.
- **Frame a cross-component change by its boundaries.** When a secret or a call
  crosses Perl ↔ jdssc ↔ third-party software, name those boundaries and organize
  the problem and the fixes around them.
- **Lead a hardening design with a catalog.** Enumerate the sensitive data and the
  exposure vectors up front as *linkable* headings, and reference them from the
  rest of the document instead of re-describing them. When a security review feeds
  the catalog, give each site a **severity** and its **provenance** — which finding
  it ties to — in a table (`0008`'s exposure-vector *Severity* / *Finding*
  columns), so the rating travels with the evidence.
- **Draft genuine alternatives in full, then choose.** If two approaches are both
  viable, write **both** as co-equal drafts (Variant A / Variant B), factor the
  shared contract out once, and add a *Choosing between them* comparison with a
  recommendation. *Alternatives Considered* then holds only options actually
  rejected.
- **Factor shared from variant-specific.** State the common contract once; each
  variant, risk, or file row then carries only its delta, tagged where it applies.
- **Mark scope boundaries.** A related fix that is designed but ships on its own is
  **implementation-separable** — say so and cross-link it, rather than dropping or
  fully merging it.
- **Enumerate each fact once, at one granularity.** Two sections listing the same
  things either differ by granularity (concrete `file:line` sites vs. a vector
  taxonomy) or merge — never three overlapping tables.
- **Make recurring concepts linkable.** A concept referenced from several places (a
  secret, a vector, a mechanism) is a heading with an anchor, defined once and
  linked to — not restated.
- **Prefer timeless framing.** Describe code as **current** vs **proposed**, not by
  date or commit; keep any dates in the status callout only.
- **State claims precisely and consistently.** "Closes the *`jdssc`-path* exposure
  of A2", not "closes A2" — and the same wording across the callout, Consequences,
  and Risks.
- **Reconcile dependent claims when the catalog grows.** A review that adds a site
  invalidates every count or completeness claim keyed to the old set — "the *only*
  … site", "closes A2", a Consequences tally. Re-check each wherever it appears
  (`0008`: a newly-found `self.args` log dump falsified an "only `jdssc`-side log
  site" claim, and Consequences and the corollary had to follow).
- **Restructure hygiene.** When a section moves or a heading changes level, fix the
  ToC, the `---` rules, sub-heading levels, and directional references (prefer
  named links over "above/below"), then verify every internal anchor resolves.

## House style

- **Evidence by `file:line`, as clickable links.** Cite the exact code site as a
  **relative** GitHub link so the reader can jump to it — keep the backtick inside
  the link text so it stays monospace *and* clickable:

  ```markdown
  [`Common.pm:1238`](../../OpenEJovianDSS/Common.pm#L1238)
  [`targets.py:94-97`](../../jdssc/jdssc/targets.py#L94-L97)   (range: #L<a>-L<b>)
  [`:2159`](../../OpenEJovianDSS/Common.pm#L2159)              (bare continuation, same file)
  ```

  Relative — not an absolute `github.com` URL — so the link resolves to the code at
  whatever commit the doc is viewed at; doc and code stay in sync with no branch or
  SHA to rot. Plain `file:line` stays readable and is what `0001`–`0007` use, but
  new docs link (`0008`). Stay plain where a link cannot reach: filename-only
  mentions with no line, and files in another repo (a `pve-testing` testcase). This
  is what makes the documents auditable.
- **Tables for enumerations** — files that change, risks, semantics matrices,
  vector/site lists. Prose for reasoning, tables for inventories.
- **Short code blocks** — `perl` / `python` fragments that show the *shape* of a
  function or command, not full implementations. Illustrate, don't transcribe.
- **Cross-references** — link other design documents by relative path
  (`[chap-auth-design](0002-chap-auth-design.md)`) and ADRs into `../adr/`.
  Forward- and back-link related work.
- **Vim-navigable section anchors.** Every heading is followed by a bare
  self-anchor line whose link text is an **underscore token** — the heading with
  spaces and hyphens joined by `_` — and the ToC uses that same token:

  ```markdown
  ## Log content
  [Log_content](#log-content)
  ```

  The token is a single vim *word* (underscores are keyword characters), so `*` or
  `/Log_content` jumps between the ToC entry and the section — no browser needed to
  follow the anchor. In-body cross-references stay natural-language and clickable
  (`[log content](#log-content)`); only the ToC and the per-heading self-anchor
  carry the token. (`0007` originated this; `0008` follows.)
- **The strike-through-resolved pattern** — in **Problem** and **Open
  Questions**, an item that later gets resolved is *kept* and struck through with
  the resolution appended, e.g.:

  ```markdown
  - ~~**Duplicated credential code.**~~ **(Resolved.)** … now retired; …
  ```

  or, for open questions: `1. ~~**Write path**~~ — **resolved**: …`. The
  document thereby carries its own history rather than deleting it.
- **Tense tracks status** — a `PROPOSED` document uses the conditional ("would
  change", "would break"); an `IMPLEMENTED` one uses present/past and annotates
  what landed. When a document is updated post-implementation, convert the tense
  rather than rewriting.
- **Em dashes** (`—`) for asides; **bold** for the load-bearing term in a
  sentence; blockquote (`>`) only for the status callout and scope notes.

## Skeleton template

Copy this into `NNNN-<slug>.md` and delete what a given change does not need.

```markdown
# <Title> — Design Document (PROPOSED)

> **Status: proposed (YYYY-MM-DD).** <one-paragraph: what this recommends, what
> it closes, what is explicitly out of scope and tracked elsewhere.>

## Table of Contents
<only if the document is long>

## Overview
<what and why, in a paragraph or two; name the layers if it spans several>

## Problem
<the current state and what is wrong, with file:line evidence; a table if there
are several sites/vectors>

## Key Observation
<the single insight the design pivots on — optional but powerful>

## Design
### <mechanism 1>
<the shape (code block) and, more importantly, why this shape>
### <mechanism 2>

## Alternatives Considered
<worked alternatives and the reason each was not chosen>

## Consequences
<what becomes true once this lands>

## Risks & Backward Compatibility
1. **<risk>.** <failure → why (not) a problem → guard.>

## Files That Would Change
| File | Change |
|---|---|
| … | … |
| docs/design/NNNN-<slug>.md | this document |

## Testing
<unit / e2e / live; which existing testcases move>

## Relationship to Other Work
<links to the documents this depends on / enables / sits beside>

## Open Questions
1. <decision not yet made>
```

## Adding a new document — checklist

1. Pick the next `NNNN` (`ls docs/design/`), name it `NNNN-<kebab-slug>.md`.
2. Open with the title + `(STATUS)` and the status callout.
3. Lead with **Problem** grounded in `file:line`, then **Design**; put the real
   thinking in **Key Observation** / **Alternatives** / **Risks**.
4. Include a **Files That Would Change** table with this document's own row.
5. Cross-link related design documents and any ADR.
6. If it decides something a future reader will ask "why", either write the ADR
   in `../adr/` and reference it, or capture the decision in **Open Questions**
   as resolved.
7. Keep the document as it evolves: strike-through-resolve rather than delete,
   and convert tense when it moves from proposed to implemented.
