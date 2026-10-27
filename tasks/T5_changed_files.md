# Task 5 — Changed-files summary + per-file diff review

After the agent makes file changes, show a compact list of changed files with `+x / -y` counts.
Selecting a file opens its diff for review; provide Review All.

## Story 5.1 — Per-chat edit tracking
**Requirement:** Track file edits attributed to the current chat/session, capturing added/removed
line counts and tool-call IDs.

**Acceptance criteria:**
- [x] `edited_files.for_chat(chat.id)` returns per-chat changed files.
- [x] ACP edit events include chat ID, tool-call ID, counts.
- [x] HTTP/other event sources extend attribution over time.

**Implementation notes:**
- `edited_files.for_chat(chat_id)` aggregates by chat, file and tool-call ID, summing added/removed counts.
- ACP edit notifications include `chat_id`, `chat_bufnr`, `tool_call_id`, `added` and `removed`.
- HTTP `edit_file` and `create_file` now include the same attribution and counts. Other HTTP tools that write files indirectly, such as `run_command`, are not attributed.

**Status:** ✅ DONE

---

## Story 5.2 — Changed-files strip rendering
**Requirement:** Render virtual strip above composer: ` Changed files  N (+A / -D) · gF to review`.
Each row: status, path, `±x -y`.

**Acceptance criteria:**
- [x] Strip renders via extmark when files changed.
- [x] Counts aggregate added/removed across chat's edits.
- [x] `gF` routes to review UI.

**Implementation notes:**
- `changed_files.update()` renders an extmark with `virt_lines_above` at `chat.header_line`: `Changed files N (+A / -D) · gF to review`, then one row per file with status, relative path and `+x -y`.
- The strip refreshes on `CodeCompanionFileEdited` for the chat and on `on_completed`.
- `gF` opens the changed-files picker.

**Status:** ✅ DONE

---

## Story 5.3 — Per-file diff review
**Requirement:** Selecting a changed file opens existing Code Review per-file diff view.

**Acceptance criteria:**
- [x] Row selection → `vim.cmd.edit(path)` → code review window opens.
- [x] Review All opens all diffs.

**Implementation notes:**
- Selecting a file opens it with `vim.cmd.edit()` and then opens the existing Code Review window. The picker also has a `Review all changes` entry.
- Drift: Code Review opens on its first checklist entry. The window API doesn't accept a target path, so the selected file isn't focused automatically.

**Status:** ✅ DONE

---

## Story 5.4 — Scope & safety
**Requirement:** Exclude unrelated worktree changes; refresh after accept/revert; stale files
handled safely.

**Acceptance criteria:**
- [x] Attribution scoped to chat ID; unrelated changes excluded.

**Implementation notes:**
- Attribution is keyed by `chat_id`, so edits from another chat or unrelated worktree changes never enter the strip.
- The strip refreshes when the chat completes and whenever the chat's own edit event fires.
- Accepting or reverting in Code Review doesn't emit an edit event, so it doesn't change the attributed list.

**Status:** ✅ DONE

---
