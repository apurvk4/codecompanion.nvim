# Current Agent Handoff: CodeCompanion Chat UI Migration

**Updated:** 2026-10-20  
**Workspace:** `/home/apurvk/Documents/Programming/Projects/nvim-opencode`  
**Repository:** CodeCompanion.nvim fork, checked out as `main`  
**Fork remote:** `origin` → `https://github.com/apurvk4/codecompanion.nvim.git`  
**Upstream remote:** `upstream` → `https://github.com/olimorris/codecompanion.nvim.git`  
**Base commit:** `86118411` (`refactor(http): curl lib (#3477)`)  
**Runtime:** Neovim 0.12+ required by current CodeCompanion; this machine has Neovim 0.13.0-dev installed at `/usr/local/bin/nvim`.

> This file is the current handoff. `AGENT_HANDOFF.md` is retained as a historical document for the removed `copilot-flow.nvim` implementation and describes architecture that is no longer active.

## Product direction

The **main product requirement** is a Copilot/VS Code-style agent chat experience entirely inside CodeCompanion Chat. All product changes belong in the CodeCompanion Chat flow. Extend the existing CodeCompanion fork and reuse its chat, ACP, sessions, approvals, editor context, tools, folds, and Code Review systems; do not add another ACP client or agent runtime.

### Primary UX requirements

These requirements take priority over implementation convenience. The implementation should match the behavior below; if a detail is blocked by an agent capability or CodeCompanion architecture, expose the limitation clearly rather than silently omitting it or showing a control that does nothing.

1. **Session history is the chat's opening view.** When the user opens CodeCompanion Chat, show the previous chat sessions in the chat UI. Selecting a session opens and restores that session's actual chat history. Provide a clear New Chat action. Do not use a numbered `vim.ui.select` menu that requires typing `1`, `2`, etc. The history list should be visible and navigable with cursor/keyboard and, where supported, mouse. An empty history should still show an explicit empty state and New Chat action.
2. **Persistent bottom composer.** In an active session, keep a prompt text box at the bottom for entering and sending user messages. Immediately above/below it, provide the session's model and related configuration selectors, including effort/reasoning level where supported. Allow choosing agent type/mode such as Plan or Ask when the active agent advertises equivalent options. Preserve drafts while opening menus or changing controls. Submission must continue through CodeCompanion's real chat/session path.
3. **Permission selector adjacent to the composer.** Provide a dropdown with at least Default/Ask, Auto-approve safe actions, and Allow All. Make the current choice visible. Default asks the user before protected tool/command execution; Auto approves only actions covered by safe rules and asks for risky/unknown actions; Allow All requires explicit selection and warning. Respect the distinct permission semantics of HTTP tools and ACP agents, including agent-provided one-time versus persistent choices. Never imply a mode applies if the adapter cannot honor it.
4. **Inspectable running agent work.** While the agent is active, show tool calls and commands as inspectable activities with status and expandable output. For a command whose process/terminal handle is genuinely available, let the user open its associated terminal and send the process to the background. Background work must remain discoverable and stoppable. Do not offer terminal/background actions for an external ACP process unless CodeCompanion has a real handle and protocol support; show captured output and explain the limitation otherwise.
5. **Collapsible activity accordions.** Use a consistent accordion/collapse interaction for model-supplied thinking summaries, submodels/subagents, tool calls, and command output. Update an activity in place by stable ID; keep active work visible and allow completed details to collapse. Show only reasoning or summaries explicitly supplied by the model/agent and permitted by its contract; do not fabricate or expose hidden chain-of-thought. Nest subagent work only when the backend supplies reliable parent/child identifiers.
6. **Context attachment menu.** Put a `+` action above the composer. It must let the user attach the currently open Neovim buffer and provide a separate action to attach all eligible open buffers. Show attached context and allow removal before sending. Include unsaved buffer contents and make snapshot/live-sync behavior clear. Respect CodeCompanion's excluded-buffer, binary, size, and privacy rules and explain skipped buffers.
7. **Changed-files summary and review.** After agent edits, show a compact list of files changed by the active chat above the composer, with status/path and per-file line counts (`+x/-y`). Selecting a file opens that file's diff for review; provide a review-all action. Attribute edits to the correct chat/session and exclude unrelated worktree changes. Reuse CodeCompanion Code Review and its safe accept/revert behavior instead of creating a second diff engine.

### Target layout

```text
┌ CodeCompanion Chat ─────────────────────────────── [New] ┐
│ Recent sessions (initial view) OR selected transcript     │
│ User / assistant messages                                 │
│   ▸ Thinking / plan                                       │
│   ▸ Tool or command activity                              │
│   ▸ Subagent activity                                     │
│                                                          │
│ Changed files  (+x / -y)                                  │
│   M path/to/file.lua  +4 -2  [open diff]                  │
│ [+ Context: current buffer | all buffers]                │
│ ┌ User prompt… ────────────────────────────────────────┐ │
│ └──────────────────────────────────────────────────────┘ │
│ [Model] [Effort] [Agent mode] [Permissions: Ask] [Send]  │
└──────────────────────────────────────────────────────────┘
```

The layout describes user-facing behavior, not a requirement to build four independent buffers. Preserve CodeCompanion's message state and submission lifecycle. A separate persistent composer is desirable, but must be implemented without duplicating the transcript or bypassing chat APIs.

### Required behavior when sessions close

- Starting a new chat and closing it before the first user prompt must not save or leave an empty session in either CodeCompanion history or the ACP agent's history.
- For ACP, connecting/authenticating to populate supported history is distinct from creating a session. Defer `session/new` until the first prompt; if an agent creates a session earlier, explicitly delete/discard it on close if the protocol supports that.
- Persist/resume only through the session owner: CodeCompanion storage for supported HTTP chats and the agent's ACP list/load capabilities for ACP history. Do not present unsupported persistence as if it worked.

The detailed phases, API mapping, safety notes, and acceptance gates remain in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md). Treat the seven items above as the source of truth for what the product must ultimately do.

The detailed requirements and phased plan are in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

## Current repository state

- Local `main` tracks `origin/main`; `origin/main` and `upstream/main` were both at `86118411` when inspected.
- No migration commits have been created yet. Changes listed below are local modifications/untracked files.
- The historical Copilot Flow documentation has been preserved: [AGENT_HANDOFF.md](AGENT_HANDOFF.md), [COPILOT_FLOW_LEGACY_README.md](COPILOT_FLOW_LEGACY_README.md), and [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).
- User's local Neovim config uses the workspace as the CodeCompanion source and configures the OpenCode ACP adapter at `/home/apurvk/.opencode/bin/opencode`. New Alacritty shells should resolve `/usr/local/bin/nvim` / Neovim 0.13; the previous `~/.local/bin/nvim` is backed up as `nvim-0.10.4-backup`.

## Implemented changes so far

### Session-first chat list

- Added [lua/codecompanion/interactions/chat/session_picker.lua](lua/codecompanion/interactions/chat/session_picker.lua).
- A fresh, prompt-free `:CodeCompanionChat` can display a **read-only session list in the chat buffer itself**, rather than a numeric `vim.ui.select` picker.
- The list includes New Chat, locally persisted HTTP sessions, and ACP sessions when the active agent advertises list/load capabilities.
- It has an explicit empty-history state. `j`/`k` move through rows; Enter or mouse selects; `n` starts a new chat; `q` or Esc exits the list and restores the normal composer buffer contents.
- Temporary keymaps use CodeCompanion's keymap override/restore helper so the chat's original Enter mapping returns when the list closes.
- Selecting an HTTP session loads it through CodeCompanion's existing session loader and closes the empty starter chat. ACP history restores through ACP `session/load` and existing renderer code.

### Avoid empty ACP sessions

- Chat startup and ACP adapter switching now connect/authenticate with `defer_session = true`; they do not call `session/new` just because the chat opened.
- ACP prompt handling still calls `ensure_session()` before sending the first prompt. Therefore, opening then closing an untouched chat should not create an agent session.
- ACP command switching also uses deferred session creation.
- The behavior is covered by a test case in [tests/interactions/chat/test_session_picker.lua](tests/interactions/chat/test_session_picker.lua), but that test has not been confirmed by a fresh full-suite run after the latest edits.

### Chat controls and context

- Added chat keymaps in [lua/codecompanion/interactions/chat/keymaps/init.lua](lua/codecompanion/interactions/chat/keymaps/init.lua):
  - `g+`: choose current buffer or all open buffers; inserts CodeCompanion's native editor-context marker.
  - `gO`: choose an option advertised by the active ACP agent, such as model/mode/effort when available.
  - `gF`: choose files changed by this chat or review all changes using CodeCompanion Code Review.
  - `gty`: existing approval mode menu, with labels updated to Default / Ask, Auto-approve safe actions, and Allow all.
  - `ga`: existing adapter/model selection.
- Model and effort values are not hard-coded. ACP options are only displayed from the active agent's advertised configuration options. HTTP effort options come from adapter schema keys with `choices`. Settings continue through existing CodeCompanion APIs.

### Persistent composer

- Added [lua/codecompanion/interactions/chat/composer_controls.lua](lua/codecompanion/interactions/chat/composer_controls.lua).
- A floating composer window sits at the bottom of the chat window: anchor `SW`, chat width, height 4, rounded border, title ` Composer `.
- Shows `Model`, HTTP effort or ACP agent options, approval mode, `＋ Attach context`, and the changed-files hint.
- `<C-s>` sends in normal and insert mode, `<CR>` sends in normal mode, Shift+Enter inserts a newline, and Escape clears the draft.
- Drafts survive close/open through `chat._composer_draft`.
- `g+` attaches the current buffer or all open buffers and renders removable chips above the prompt.
- Approval labels are `Default / Ask`, `Auto-approve safe actions` and `Allow all`; choosing Allow all shows a warning.

### Changed-file summary

- ACP and HTTP `edit_file`/`create_file` edit events now include chat ID, chat buffer, tool-call ID, and diff-derived added/removed line counts.
- [lua/codecompanion/interactions/shared/edited_files.lua](lua/codecompanion/interactions/shared/edited_files.lua) retains existing global edit tracking and adds per-chat aggregation.
- Other HTTP tools that write files indirectly, such as `run_command`, aren't attributed yet.
- Added [lua/codecompanion/interactions/chat/changed_files.lua](lua/codecompanion/interactions/chat/changed_files.lua) to render virtual summary lines above the chat's current prompt section. `gF` routes to the existing Code Review UI.
- This attribution/count path has targeted behavior coverage in [tests/interactions/chat/test_ui_controls.lua](tests/interactions/chat/test_ui_controls.lua) and ACP event assertions in [tests/interactions/chat/acp/test_handler.lua](tests/interactions/chat/acp/test_handler.lua).

### Running activity cards

- Added [lua/codecompanion/interactions/chat/ui/activity.lua](lua/codecompanion/interactions/chat/ui/activity.lua). A card is one summary line plus virtual lines for captured output and nested children, so expanding or collapsing never moves the transcript.
- Cards are keyed by stable backend IDs. HTTP tools use the tool call's `id`; ACP uses `toolCallId`. Repeated events update the same card instead of appending.
- Running cards stay expanded. Successful cards collapse; error and cancelled cards stay expanded until toggled. Collapsed errors still show their first output line.
- Cards without a usable ID fall back to append-only rendering and log why.
- ACP `execute` cards show captured output and explain that no terminal or background handle exists for an agent-owned command. They also offer a read-only snapshot of the command and the output the agent reports.
- ACP tool-call content of type `terminal` attaches the real terminal buffer to the card, and `gA` offers Open terminal while that buffer is alive.
- `gA` opens an action menu for the card under the cursor. It only lists actions backed by a valid terminal buffer, snapshot buffer, job or handler.
- Nesting is driven only by an explicit `parent_id`. Unknown parents render at the top level and log why. No timing, order or title heuristics are used.
- ACP reasoning continues to use the existing reasoning accordion; a new test covers repeated tool-call IDs, missing IDs and the reasoning fold created when a tool call leaves a reasoning block.
- `Chat:close()` and `Chat:clear()` clear the buffer's activity registry and virtual-line namespace, and delete any snapshot buffers.
- Targeted coverage lives in [tests/interactions/chat/ui/test_activity.lua](tests/interactions/chat/ui/test_activity.lua), [tests/interactions/chat/acp/test_handler.lua](tests/interactions/chat/acp/test_handler.lua) and [tests/interactions/chat/tools/test_orchestrator.lua](tests/interactions/chat/tools/test_orchestrator.lua).

### Terminal sessions

- Added [lua/codecompanion/interactions/chat/terminal.lua](lua/codecompanion/interactions/chat/terminal.lua). It keeps one interactive shell per `term_id` in a scratch buffer, shown in a `botright` split of height 15.
- `Terminal.run_command({ cmd = ..., term_id = ... })` reuses a live session, focuses a window already showing it, or starts a fresh shell when the buffer has gone. It then sends the command to the shell, scrolls to the bottom and enters insert mode.
- `Terminal.create()` runs an agent command in a hidden terminal through `vim.fn.termopen`, returns a `terminal_id` immediately, and tracks its rendered output, exit status, waiters and owner.
- `Terminal.output()`, `wait_for_exit()`, `kill()`, `release()`, `buffer()` and `release_for_owner()` back the ACP terminal methods and the activity card.
- `Terminal.switch()` lists live session IDs with `vim.ui.select()` and sets the chosen buffer.
- Each session buffer maps `<Esc><Esc>` in terminal mode to `<C-\><C-n>`.
- Coverage lives in [tests/interactions/chat/test_terminal.lua](tests/interactions/chat/test_terminal.lua).

### ACP terminal capability

- Added `terminal/create`, `terminal/output`, `terminal/wait_for_exit`, `terminal/kill` and `terminal/release` to [lua/codecompanion/acp/init.lua](lua/codecompanion/acp/init.lua) and [lua/codecompanion/acp/methods.lua](lua/codecompanion/acp/methods.lua).
- `Connection:prepare_adapter()` injects `clientCapabilities.terminal = true` with `vim.tbl_deep_extend("keep", ...)`, so an adapter that sets `false` still wins. All ACP adapters now advertise the capability without per-adapter edits.
- `terminal/create` rejects a `cwd` outside `vim.fn.getcwd()`, then applies the active approval mode: `yolo` allows, `auto` allows a safe command, otherwise the user chooses Allow once, Allow always or Reject.
- `Connection:disconnect()`, `Chat:close()` and `Chat:clear()` release the chat's terminals.
- `tests/acp/test_acp.lua` drives all five methods and asserts the capability injection.

### Test runner safety

- [scripts/minimal_init.lua](scripts/minimal_init.lua) now checks for Neovim 0.12+ and the Tree-sitter CLI, fails early with actionable messages, and limits parser compilation concurrency to two jobs.
- [Makefile](Makefile) accepts `NVIM` and `TREE_SITTER` overrides and runs `check_test_env` before `make test` / `make test_file`.
- Test configuration disables the interactive history view in [tests/config.lua](tests/config.lua) and [tests/helpers.lua](tests/helpers.lua), so headless lifecycle tests do not wait for UI selection.
- In the prior test setup, the Tree-sitter CLI was missing. The CLI was subsequently installed by the user; tests reported all parsers installed on the latest run.

## Verification status

- A fresh `make test` run on 2026-10-28 completed **1499 cases, 0 failures and 4 expected notes** on Neovim 0.13.0-dev. The notes are two Windows-only skips and two token-throughput benchmarks.
- Targeted runs for `test_terminal.lua` (11), `test_activity.lua` (12), `acp/test_handler.lua` (31), `acp/test_acp.lua` (29), `tools/test_orchestrator.lua` (13), `ui/test_fold_reasoning_output.lua` (4), `test_approvals.lua` (29), `acp/test_permission_request.lua` (16) and `test_ui_controls.lua` (15) all pass.
- `make format` passes with StyLua 2.6.0, downloaded to `/tmp/opencode/stylua` because it wasn't installed.
- `make docs` passes with Pandoc 3.13, downloaded to `/tmp/opencode/pandoc` because it wasn't installed.
- `make lint` passes with `0 warnings / 0 errors in 282 files` using Luacheck 1.2.0, installed in the gitignored `deps/luacheck` tree. The repo now has `.luacheckrc` and a `LUACHECK`-overridable lint target that falls back to that tree.

## Known limitations / work remaining

1. **The composer is a separate float, not a separate buffer layout.** The transcript stays in the chat buffer. Composer controls are virtual lines, so the `▾` glyphs and `+` action are hints rather than mouse targets; use `ga`, `gO`, `gty` and `g+`.
2. **ACP terminals work only when the client and agent share a machine.** `terminal` and `fs` assume a shared filesystem and shell because ACP does not transport files or processes. A remote agent with a local client will read the wrong files and run the wrong shells. Terminal output is the rendered buffer text, so ANSI styling, wrapped lines and control sequences are not preserved byte for byte.
3. **Running activity cards are implemented, but nested subagents are not.** Stable IDs, in-place updates, expandable output, reasoning accordions and action gating are in place. `tasks/T3_running_activity.md` records story 3.4 as partial because background execution is still missing; story 3.5 renders explicit `parent_id` nesting but stays dormant because ACP tool-call updates carry no parent/child identifier. No nesting is inferred from order or titles.
4. **Manual UX verification remains pending.** The automated suite covers the composer, context chips, changed-files strip and attribution, but a live Neovim + OpenCode session still needs to confirm the full flow.
5. **HTTP attribution covers `edit_file` and `create_file` only.** Direct ACP filesystem writes and other HTTP tools such as `run_command` may not yet include chat/tool IDs or line counts.
6. **HTTP session autosave remains CodeCompanion-configured.** History appears only for sessions actually saved/autosaved. ACP session history remains agent-owned and capability-dependent.
7. **Current connection startup is deferred but still starts/authenticates the ACP process.** The intended invariant is no backend session creation until the first prompt; a real OpenCode smoke test should confirm this behavior.
8. **Background execution remains unavailable and undocumented.** Terminal and activity behaviour, including the ACP co-location assumption, is documented in [doc/usage/chat-buffer/index.md](doc/usage/chat-buffer/index.md). The composer, `gA` and the approval modes are also in [doc/configuration/chat-buffer.md](doc/configuration/chat-buffer.md). Local interactive UX verification remains pending.

## Suggested next steps

1. Have the user manually inspect `:CodeCompanionChat` with a live Neovim + OpenCode session: run a tool call and confirm the activity card appears, updates in place, collapses on success, expands with `gA`, and keeps output intact.
2. Confirm the `gty` approval modes behave as described in a real session, including Allow all's warning and ACP one-time versus persistent choices.
3. Add a real background path for `run_command` (a terminal buffer and a detach mechanism in the agent loop) so story 3.4 can move from partial to done.
4. Broaden changed-file event attribution to HTTP `run_command` and direct ACP filesystem writes.
5. Keep all edits inside the CodeCompanion fork and continue using existing CodeCompanion APIs.
