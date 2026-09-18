# Documentation

One folder per category. Nothing documentation-shaped lives at the repository
root except the project `README.md` itself.

## Where to start

**Picking the work back up?** Read [plan/roadmap.md](plan/roadmap.md) first.

New to the project — read these in order:

0. **[guide/hands-on-tour.md](guide/hands-on-tour.md)** — about an hour of
   running the project, following real days, and breaking it on purpose to see
   what catches it. The quickest way in.
1. **[guide/project-guide.md](guide/project-guide.md)** — what every file and
   folder does, and a runbook of commands you can run locally. Start here.
2. **[verifier/implementation-notes.md](verifier/implementation-notes.md)** —
   the ambiguity list. 22 places the specification was under-determined and 7
   places it was judged outright wrong. The most useful document here.
3. **[decisions/design-decisions.md](decisions/design-decisions.md)** — every
   non-obvious choice, why it was taken, what was rejected, and the open
   questions.

## Categories

| Folder | Holds | Current contents |
|---|---|---|
| `guide/` | Orientation and runbooks — how to find things and how to run them | `project-guide.md`, `hands-on-tour.md` |
| `decisions/` | The design decision log. Append-only: a reversal gets a new entry marked **Superseded**, never an edit | `design-decisions.md` |
| `spec/` | Specifications. What a thing must do, written so an implementation can be checked against it rather than derived from it | `enforcement-rule.md` |
| `plan/` | Where the work stands and what comes next, in dependency order | `roadmap.md` |
| `verifier/` | Notes on the independent verifier: its assumptions, its ambiguity list, and what it found | `implementation-notes.md` |

Expected next, once the work reaches them: `security/` for the threat model and
security analysis, `evaluation/` for results, gas measurements and the
comparison against transaction-level authorisation.

## Conventions

- **A category folder, never the root.** Add a folder when a genuinely new
  category appears, not for every new file.
- **Descriptive filenames**, not `NOTES.md` or `misc.md`. The filename should
  say what the document is without its folder.
- **Cross-references use the full repository path** — `docs/spec/enforcement-rule.md`
  — so a reference reads the same from a source file, a commit message, or
  another document.
- **`spec/` is normative, `decisions/` is historical.** The spec says what must
  be true now; the decision log says how we got here and never rewrites itself.
