# CodeCompanion Chat — VS Code-Style Chat UX Implementation Plan

All changes go in `lua/codecompanion/interactions/chat/`. This folder contains the ordered
implementation tasks and stories. Each task is self-contained: completing Story N of Task N
requires nothing from Story N+1 of the same task or any other task.

## Task Index

| Task | Title | File | Stories |
|------|-------|------|---------|
| T1 | Session history as the chat opening view | `T1_session_history.md` | S1.1 – S1.5 |
| T2 | Persistent bottom composer + controls (model, effort, agent mode, permission) | `T2_composer_controls.md` | S2.1 – S2.6 |
| T3 | Inspectable running agent activity, accordions, terminal/background, allow-deny | `T3_running_activity.md` | S3.1 – S3.6 |
| T4 | Context attachment menu (`+` button) | `T4_context_attachment.md` | S4.1 – S4.3 |
| T5 | Changed-files summary + per-file diff review | `T5_changed_files.md` | S5.1 – S5.4 |
| T6 | Hardening, formatting, tests, release | `T6_hardening.md` | S6.1 – S6.4 |
| T7 | ACP terminal capability and live command output | `T7_acp_terminal.md` | S7.1 – S7.5 |

## How to read a story

Each story has:
- **Requirement** — what the user-facing behavior must be.
- **Acceptance criteria** — verifiable checks.
- **Implementation notes** — what was actually built, including any drift from the
  requirement (must be filled in by the implementer).

Stories are ordered so that Story N of Task N never depends on Story N+1 of Task N or any
Story of Task N+1. Tasks may be done in any order, but the natural progression is T1 → T2 → T4 →
T5 → T3 → T6 → T7, because T1 establishes the session picker, T2 establishes the composer surface
that T4/T5/T3 all build on, T6 is the release gate and T7 depends on T3's activity cards.
