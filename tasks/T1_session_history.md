# Task 1 — Session history as the chat opening view

When the user runs `:CodeCompanionChat` with no active chat, show the previous chat sessions
in the chat buffer itself. Selecting one restores that session's transcript. Provide a clear
New Chat action. The history list must be visible and navigable with `j`/`k`, Enter, mouse.
Empty history shows an explicit empty state + New Chat.

## Story 1.1 — Session list data aggregation
**Requirement:** Build a function that returns a unified list of sessions from both CodeCompanion
local HTTP session store and ACP agents that advertise `session/list` + `session/load`.
Each entry must include: `kind` ("http" | "acp" | "new"), display label (title + relative time),
stable ID, load capability flag, and source-specific payload (session stem or ACP sessionId).
ACP sessions only appear when the active agent advertises both list and load capabilities.

**Acceptance criteria:**
- `get_entries(chat)` returns a table with exactly one "new" entry at index 1, then all HTTP
  sessions from `sessions.list()`, then all ACP sessions from `connection:session_list()`.
- ACP sessions are absent when `connection:can_list_sessions()` or `can_load_session()` is false.
- Each entry has `{ kind, label, session, load_capable }`.
- Unit test covers: empty history, only HTTP, only ACP, mixed, ACP capability disabled.

**Implementation notes:**
- Function `M.get_entries(chat)` exported from `lua/codecompanion/interactions/chat/session_picker.lua:9`.
- Returns table with index 1 = `{ kind = "new", label = "＋  New Chat", load_capable = false }`.
- Followed by HTTP sessions from `sessions.list()` each with `{ kind = "http", label, session, load_capable = true }`.
- Followed by ACP sessions from `connection:session_list()` each with `{ kind = "acp", label, session, load_capable = true }`, only when `can_list_sessions()` and `can_load_session()` both true.
- Unit tests added in `tests/interactions/chat/test_session_picker.lua` covering empty, HTTP-only, ACP-only, mixed, capability-disabled.
- No drift from requirement. File path exactly as required.

**Status:** ✅ DONE

---

## Story 1.2 — In-buffer session picker UI
**Requirement:** Replace the chat buffer contents with a read-only Markdown list showing the
entries from Story 1.1. Header line "## Recent Chats", helper line with key hints. Current line
highlighted via `cursorline`. Non-modifiable buffer. `j`/`k` move cursor; Enter or left-mouse
selects; `n` starts new chat; `q`/`Esc` restores original composer. Temporary keymaps use
`keymaps.Override` so original Enter mapping returns when picker closes.

**Acceptance criteria:**
- Opening `:CodeCompanionChat` with no messages shows the picker (not the intro message).
- Cursor starts on first selectable session (not header/helper lines).
- Enter on "New Chat" closes picker and leaves empty composer.
- Enter on HTTP session loads it via `sessions.load()` and closes starter chat.
- Enter on ACP session calls `restore_acp_session()` and closes picker.
- `q`/`Esc`/`n` restore composer and fire `CodeCompanionChatOpened`.
- Mouse click on any entry selects it.
- No keymap leaks after picker closes (original chat keymaps restored).

**Implementation notes:**
- Function `M.open(chat)` exported from `lua/codecompanion/interactions/chat/session_picker.lua:83`.
- Replaces chat buffer contents with read-only Markdown list: header "## Recent Chats", helper line, then entries.
- Sets `modifiable = false` after writing lines; `cursorline = true` on chat window.
- Temporary keymaps via `keymaps.Override.new(bufnr)` for `<CR>`, `<LeftMouse>`, `n`, `q`, `<Esc>`.
- `restore_composer()` restores original lines and calls `composer_controls.open(chat)` which fires `CodeCompanionChatOpened` autocmd.
- Cursor positioned on first session entry via `#lines - #entries + 1` (New Chat is first entry).
- All 8 acceptance criteria verified by existing tests in `test_session_picker.lua`.
- No drift from requirement.

**Status:** ✅ DONE

---

## Story 1.3 — HTTP session restore
**Requirement:** Selecting an HTTP session calls `sessions.load(stem, { buffer_context })`.
If the restored chat has no user messages, close the starter chat buffer. Restored session
shows full transcript with correct roles, reasoning folds, tool folds.

**Acceptance criteria:**
- `sessions.load()` returns truthy; chat buffer shows all prior messages.
- No duplicate buffers left open.
- Folds (reasoning, tool) render correctly on restored messages.
- `chat.id` and `chat.session_id` are new; original session file unchanged.

**Implementation notes:**
- Implemented in `select_current()` at `lua/codecompanion/interactions/chat/session_picker.lua:155-163`.
- Calls `sessions.load(entry.session.stem, { buffer_context = chat.buffer_context })`.
- If `restored` is truthy and chat has no user messages (`has_user_message`), closes starter chat via `chat:close()`.
- `sessions.load()` creates a new chat buffer with new `chat.id` and `chat.session_id`; original session file unchanged.
- Folds render via existing UI builder/folds system when messages are restored.
- Verified by test "restores a saved HTTP session and closes the empty starter chat" in `test_session_picker.lua`.
- No drift from requirement.

**Status:** ✅ DONE

---

## Story 1.4 — ACP session restore
**Requirement:** Selecting an ACP session calls `connection:load_session(sessionId)` with an
`on_session_update` callback collecting updates, then `acp.render.restore_session(chat, updates)`.
Sets chat title from session. Fires `ACPChatRestored` event.

**Acceptance criteria:**
- ACP session loads without creating a new agent session (deferred session already active).
- Transcript renders with user/assistant messages, tool calls, reasoning.
- `chat.title` matches session title.
- `ACPChatRestored` event fires with correct `bufnr`, `id`, `session_id`, `title`.

**Implementation notes:**
- Implemented in `restore_acp_session()` at `lua/codecompanion/interactions/chat/session_picker.lua:42-68`.
- Calls `chat.acp_connection:load_session(entry.session.sessionId, { on_session_update = ... })` to collect updates.
- Links buffer to session via `acp.commands.link_buffer_to_session(chat.bufnr, session_id)`.
- Restores transcript via `acp.render.restore_session(chat, updates)`.
- Sets `chat.title` from `entry.session.title`.
- Fires `ACPChatRestored` event with `{ bufnr, id, session_id, title }`.
- Verified by test "loads a selectable ACP session into the current chat" in `test_session_picker.lua`.
- No drift from requirement.

**Status:** ✅ DONE
**Requirement:** When no sessions exist (no HTTP, ACP can't list), show "No previous chats yet."
with New Chat still selectable. Handle stale/deleted sessions gracefully (skip or show error
toast). Handle adapter switch mid-picker (close picker, re-open with new adapter's sessions).
Preserve draft composer content when opening/closing picker.

**Acceptance criteria:**
- Empty history renders "No previous chats yet." and New Chat works.
- Deleted HTTP session file → skipped with warning toast, not crash.
- ACP `session_list` error → toast, picker stays open with HTTP sessions only.
- Switch adapter (`ga`) while picker open → picker closes, new picker opens with correct sessions.
- Type in composer, open picker (`q`), close picker → draft preserved.

**Implementation notes:**
- Empty state "No previous chats yet." rendered when `#entries == 1` (only New Chat entry).
- New Chat selection verified by test "keeps the fresh chat when New Chat is selected".
- Deleted/corrupted HTTP session files → skipped with warning toast via `utils.notify()`, not crash (added `pcall` wrapping `sessions.list()`).
- ACP `session_list` errors → error toast via `utils.notify()`, picker stays open with HTTP sessions only (added `pcall` wrapping `connection:session_list()`).
- Switch adapter (`ga`) while picker open → picker closes and re-opens with new adapter's sessions (added autocmd listener for `ChatAdapter` user event fired by `Chat:change_adapter()`).
- Draft preservation: `q`/`Esc` calls `restore_composer()` which restores original buffer lines via `picker.original_lines`, preserving any typed content.
- All 5 acceptance criteria implemented and verified by tests in `test_session_picker.lua`.
- No drift from requirement.

**Status:** ✅ DONE