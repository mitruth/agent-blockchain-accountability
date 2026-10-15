# Documentation

One folder per category. Nothing documentation-shaped lives at the repository
root except the project `README.md` itself.

## Where to start

Read these in order.

1. **[guide/project-guide.md](guide/project-guide.md)**: what the project
   contains today, how an order and a configuration change flow through the
   gate, what every file does, what the tests prove, and how to run everything.
2. **[decisions/design-decisions.md](decisions/design-decisions.md)**: every
   decision taken while building, step by step, with the reason and what was
   rejected. Ends with the decisions still open.
3. **[spec/policy-spec-v0.1.md](spec/policy-spec-v0.1.md)**: what must be
   built, all six steps. Marked notes show what has been amended or built since
   it was written.
4. **[plan/roadmap.md](plan/roadmap.md)**: status per step and what comes next.

## Categories

| Folder | Holds | Current contents |
|---|---|---|
| `guide/` | Orientation and runbooks: how to find things and how to run them | `project-guide.md` |
| `decisions/` | The design decision log, numbered by build step. Append-only: a reversal gets a new entry marked **Superseded**, never an edit | `design-decisions.md` |
| `spec/` | Specifications. What a thing must do, written so an implementation can be checked against it | `policy-spec-v0.1.md` |
| `plan/` | Where the work stands and what comes next | `roadmap.md` |
| `analysis/` | Comparisons and studies that inform a decision, with sources | `delegation-architecture.md`: the gate against Smart Sessions, MetaMask's Delegation Framework and Coinbase Spend Permissions, the checks run, and the decision on D1 (section 10); `market-structure.md`: how Dan's P2P market is ported behind the gate |
| `reports/` | Results of runs worth keeping, dated, written by the tools themselves and annotated after | `mutation-2026-10-15.md`: the step 3 mutation run, every mutant and its verdict |
| `earlier-design/` | The project that came before this one: a rolling cap on daily energy spend, settled after the fact. Kept for reference, no longer maintained | Its guide, hands-on tour, decision log, spec, verifier notes and roadmap |

Expected next, once the work reaches them: `security/` for the threat model and
security analysis, `evaluation/` for results, gas measurements and the
comparison against the baselines.

## Conventions

- **A category folder, never the root.** Add a folder when a new category
  appears, not for every new file.
- **Descriptive filenames**, not `NOTES.md` or `misc.md`. The filename should
  say what the document is without its folder.
- **Cross-references use the full repository path**, for example
  `docs/spec/policy-spec-v0.1.md`, so a reference reads the same from a source
  file, a commit message or another document.
- **`spec/` is normative, `decisions/` is historical.** The spec says what must
  be true; the decision log says how we got here and never rewrites itself.
- **Two numbering schemes for decisions.** D1 to D21 are rows of the spec's
  Section 7. Numbers like 1.4 are entries of the decision log, by build step.
