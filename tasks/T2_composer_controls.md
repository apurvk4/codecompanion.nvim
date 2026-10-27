# Task 2 — Persistent bottom composer and its controls

The active agent chat must have a prompt text box at the bottom for entering and sending user
messages. Immediately above/below it, model and effort/agent-mode selectors. Drafts preserved
while menus are open. Submission must continue through CodeCompanion's real chat/session path.

## Story 2.1 — Composer window open/close/update
**Requirement:** Manage the bottom composer window with exact height 4, anchored SW, full chat
width, border rounded, title " Composer ". Open on chat activation, close on hide/closed. Update
on WinResized/VimResized/TabEnter. Preserve draft content in chat buffer.

**Acceptance criteria:**
- [x] Composer opens as floating window at bottom of chat UI buffer on `:CodeCompanionChat`.
- [x] Window height is exactly 4 lines, width = chat buffer width, anchor = "SW".
- [x] `M.close(chat)` closes window, sets `chat.composer = nil`.
- [x] `M.open(chat)` recreates window preserving draft.
- [x] `M.update(chat)` re-positions on window resize; re-renders controls.
- [x] Composable via `chat.composer` field (`{ bufnr, winnr }`).
- [x] Focus returns to chat buffer after close; cursor position preserved.

**Implementation notes:**
- Implemented in `lua/codecompanion/interactions/chat/composer_controls.lua`.
- Floating window is relative to the chat window, anchor `SW`, row `chat height - 1`, full chat width, height `4`, rounded border, title ` Composer `.
- State lives on `chat.composer = { bufnr, winnr }`. `M.close` saves the draft to `chat._composer_draft` and `M.open` restores it into the new buffer.
- Autocmds cover `CodeCompanionChatOpened`, `WinResized`, `VimResized`, `TabEnter`, `WinClosed`, `BufWinLeave`, `CodeCompanionChatClosed` and `CodeCompanionChatHidden`.
- No drift from the window geometry requirement.

**Status:** ✅ DONE

---

## Story 2.2 — Submit, send, draft preservation
**Requirement:** Composer must support send via `<C-s>` and `<CR>` (normal), multiline via
Shift+Enter, Escape clears draft without sending. Empty prompt is a no-op. Draft preserved across
open/close. Submission copies composer lines into chat buffer at `chat.header_line` then calls
`chat:submit()`.

**Acceptance criteria:**
- [x] `<C-s>` and `<CR>` (normal mode) both call `M.submit(chat)`.
- [x] `<C-s>` in insert mode calls `M.submit(chat)`.
- [x] Shift+Enter inserts newline; Escape clears without sending.
- [x] Empty prompt → no submission, draft retained.
- [x] Non-empty → `nvim_buf_set_lines(chat.bufnr, chat.header_line, -1, false, lines)` then `chat:submit()`.
- [x] Draft preserved: `M.close` → `M.open` restores same content.
- [x] Submit blocked when `chat.current_request` is in flight.

**Implementation notes:**
- Composer buffer-local keymaps: `<C-s>` in normal and insert mode, `<CR>` in normal mode, `<S-CR>` and `<S-Enter>` in insert mode for a newline, `<Esc>` in normal and insert mode to clear the draft.
- Empty drafts return before touching the chat buffer. Non-empty drafts are written at `chat.header_line` and sent with `chat:submit()`.
- Submission is blocked while `chat.current_request` is set. The composer clears only when a request actually starts, so a submission stopped by a callback keeps the draft.
- Draft preservation is covered by the `chat._composer_draft` save/restore in Story 2.1.
- No drift from the requirement.

**Status:** ✅ DONE

---

## Story 2.3 — Model selector
**Requirement:** Immediately above prompt line, show `[Model: X]  ▾ ga`. Model choices from adapter
schema (HTTP) or `connection:get_models().currentModelId` (ACP). Select via `ga` or the ▾ glyph.

**Acceptance criteria:**
- [x] Model label line rendered in composer virt_lines when `composer_controls = true`.
- [x] HTTP: label = `adapter_utils.model(adapter) or adapter.formatted_name`.
- [x] ACP: label = `connection:get_models().currentModelId`.
- [x] Selection updates via `chat:change_model({ model = ... })`.
- [x] UI updates to reflect new model immediately.

**Implementation notes:**
- Rendered as the first control line below the prompt: `Model: <name> ▾ ga`.
- HTTP label uses `adapter_utils.model(adapter) or adapter.formatted_name`; ACP uses `connection:get_models().currentModelId`.
- `ga` opens the existing adapter/model picker and calls `chat:change_model({ model = ... })`. `chat:update_metadata()` re-renders the composer immediately.
- Drift: the `▾` is a visual hint. Neovim virtual lines don't receive mouse events, so the glyph itself isn't clickable; use `ga`.

**Status:** ✅ DONE

---

## Story 2.4 — Effort / reasoning selector
**Requirement:** Show `[Effort: X] ▾` for effort/reasoning choices supported by active adapter.
Source: adapter schema choices (HTTP) or ACP config options (ACP) filtered to effort/reasoning.

**Acceptance criteria:**
- [x] Effort selector visible only when adapter/agent supports effort.
- [x] HTTP: choices from `adapter.schema[key_name].choices` (function or table).
- [x] ACP: choices from `connection:get_config_options()` type="select".
- [x] Selection applies to current session's request settings.
- [x] Hidden for adapters that cannot support effort.

**Implementation notes:**
- HTTP: `composer_controls.effort_options()` scans the adapter schema for keys containing `effort` or `reasoning` that expose `choices` (table or function). Each is rendered as `Effort: <value> ▾ gO` or `Reasoning: <value> ▾ gO`.
- ACP: select options from `connection:get_config_options()` are rendered with their advertised name and current value.
- `gO` chooses a value. HTTP writes the key into `chat.settings` and calls `chat:apply_settings()`; ACP calls `connection:set_config_option()`.
- The control is absent when the adapter or agent advertises no matching options.
- Drift: when `display.chat.show_settings = true`, the YAML settings block in the chat buffer wins on the next submit, so a composer change can be overwritten.

**Status:** ✅ DONE

---

## Story 2.5 — Agent mode selector (Plan / Ask / Agent)
**Requirement:** When ACP agent advertises mode options, show `[Agent mode: X] ▾`. Modes drawn
only from agent's advertised config options; never hard-coded.

**Acceptance criteria:**
- [x] Agent mode selector appears only for ACP adapters with advertised modes.
- [x] Options sourced from `connection:get_config_options()` type="select".
- [x] Selection applies via `connection:set_config_option`.
- [x] Current selection marked.
- [x] Non-advertised modes never shown.

**Implementation notes:**
- The same `gO` action lists every select option advertised by `connection:get_config_options()`, so modes such as Plan or Ask appear with their agent-provided names.
- The current value is marked with `* ` in the picker. Selecting a value calls `connection:set_config_option(option.id, value)` and refreshes metadata.
- No values are hard-coded; non-advertised modes never appear.
- No drift from the requirement.

**Status:** ✅ DONE

---

## Story 2.6 — Permission dropdown
**Requirement:** Below the prompt box, dropdown with `Default / Ask`, `Auto-approve safe actions`,
`Allow all`. Current choice visible; selecting persists per-chat via `approvals:set_mode`.

**Acceptance criteria:**
- [x] Dropdown rendered in composer virt_lines below prompt line.
- [x] Labels: "Default / Ask", "Auto-approve safe actions", "Allow all".
- [x] Current mode marked with `*`.
- [x] Selection calls `approvals:set_mode(chat.bufnr, { mode = ... })`.
- [x] "Allow all" shows warning toast.
- [x] Default mode = "Ask" for new chats.

**Implementation notes:**
- Rendered as a virtual line below the prompt: `Permissions: <label> ▾ gty`.
- Labels are `Default / Ask`, `Auto-approve safe actions` and `Allow all`. The current mode is shown in the composer and marked with `*` in the `gty` picker.
- Selection calls `approvals:set_mode(chat.bufnr, { mode = ... })`. Choosing `Allow all` shows a warning notification.
- New chats inherit `interactions.chat.tools.opts.approval_mode`, which defaults to `ask`.
- Drift: the picker is the existing `vim.ui.select` approval menu rather than an inline dropdown widget.

**Status:** ✅ DONE
