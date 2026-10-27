# Task 4 — Context attachment menu

VS Code-style `+` button above the composer. Attaches the currently open Neovim buffer, or all
eligible open buffers. Attachments shown as removable chips before sending.

## Story 4.1 — Plus button: attach current buffer
**Requirement:** `+` action above prompt box opens context menu with options: "Attach current
buffer" and "Attach all open buffers".

**Acceptance criteria:**
- [x] `+` action rendered above composer prompt line (virt_lines_above).
- [x] Clicking opens selection of context sources.
- [x] Current buffer attaches via `editor_context` (buffer content).
- [x] Draft preserved when menu open.

**Implementation notes:**
- `composer_controls` renders `＋ Attach context  g+` as `virt_lines_above` on the first composer line.
- `g+` opens a `vim.ui.select` menu with `Attach current buffer` and `Attach all open buffers`. The current buffer inserts the native `#{buffer}` editor-context marker into the draft.
- Drift: Neovim virtual lines don't receive mouse events, so the `+` line isn't clickable. Use `g+` or the composer keymap.

**Status:** ✅ DONE

---

## Story 4.2 — Attach all open buffers
**Requirement:** Second option in menu attaches all eligible open buffers (excluding special
buffers per config).

**Acceptance criteria:**
- [x] All-buffers option attaches each eligible buffer as context item.
- [x] Ineligible buffers (binary/size/config) skipped with clear reason.
- [x] Duplicate attachments prevented.

**Implementation notes:**
- The all-buffers option inserts `#{buffers}`. The existing `buffers` editor context applies the configured excluded buffer types, filetypes, binary and size rules at submit time.
- Duplicate exact tokens are rejected with an info notification.
- Drift: skipped buffers are reported by the shared editor-context logger, not as a per-buffer toast in the composer.

**Status:** ✅ DONE

---

## Story 4.3 — Attachment chips + removal + send behavior
**Requirement:** Attached context items appear as removable chips above prompt. User can remove
before sending. Context is included in request payload.

**Acceptance criteria:**
- [x] Chips render for current chat context items.
- [x] Removal updates context before submit.
- [x] Context attaches with unsaved content; sync behavior clear.
- [x] Context items cleared per prompt or persist per session per design decision.

**Implementation notes:**
- `attached_context()` scans the composer draft for `#{buffer...}` and `#{buffers}` tokens and renders them as `[buffer: ...]` / `[all open buffers]` chips above the prompt.
- Opening `g+` while context is attached adds a `Remove ...` entry per chip. Removing deletes the token from the draft before submission.
- Context reaches the request through the existing editor-context path, so unsaved buffer content is included and the existing sync rules apply.
- Context is consumed from the prompt at submit and remains in `chat.context_items` for the existing live-sync behaviour.
- No drift from the requirement.

**Status:** ✅ DONE

---
