# Task 7 — ACP terminal capability and live command output

CodeCompanion can already display agent activity, but it holds no process handle for any command.
This task adds the ACP client terminal capability so an agent can ask CodeCompanion to run a
command, and adds a read-only snapshot for commands the agent runs itself.

## Assumption

The client and the agent run on the same machine and see the same filesystem and shell. ACP does
not transport files or processes. If the client and agent are on different machines, do not
advertise `terminal` or `fs`; the agent must use its own environment instead.

## Story 7.1 — Terminal registry backed by `vim.fn.termopen`
**Requirement:** Extend `lua/codecompanion/interactions/chat/terminal.lua` with a protocol-facing
API that runs an explicit command in a terminal, tracks its output and exit status, and releases
it. Use `vim.fn.termopen` for the process. Creating a terminal must not steal focus or resize the
user's layout; the buffer stays hidden until the user opens it.

**Acceptance criteria:**
- [x] `Terminal.create({ command, args, env, cwd, output_byte_limit })` returns a `terminal_id`
      immediately, without waiting for the command to finish.
- [x] The command runs through `vim.fn.termopen` with `cwd` and `env` applied.
- [x] `Terminal.output(terminal_id)` returns the captured output and a `truncated` flag, plus an
      `exitStatus` only after the command exits.
- [x] Output is truncated from the beginning at a UTF-8 character boundary when
      `output_byte_limit` is exceeded.
- [x] `Terminal.wait_for_exit(terminal_id, callback)` resolves from `TermClose` without blocking
      the editor.
- [x] `Terminal.kill(terminal_id)` stops the process and leaves the terminal readable.
- [x] `Terminal.release(terminal_id)` kills a running process, deletes the buffer and removes the
      state; a released ID is rejected by every later call.
- [x] Creating a terminal does not change the current window or buffer.

**Implementation notes:**
- `TermClose` sets `v:event.status`, which gives the exit code. There is no separate signal field,
  so responses carry `signal = vim.NIL`.
- Neovim 0.13 deprecates `termopen()` in favour of `jobstart(..., { term = true })`. The call sits
  in `open_hidden` so it can be swapped without touching the protocol handlers.
- Reading a terminal buffer returns rendered lines, not the exact bytes the process wrote. Long
  lines wrap at the buffer width. The docs state this limitation.
- An empty options table reaches Vimscript as a list, which `termopen` rejects, so `open_hidden`
  passes `vim.empty_dict()` when there are no options.
- `release` is not idempotent: a second call returns `false` and the ACP handler answers it with an
  invalid-params error rather than crashing.

**Status:** ✅ DONE

---

## Story 7.2 — ACP terminal methods
**Requirement:** Implement `terminal/create`, `terminal/output`, `terminal/wait_for_exit`,
`terminal/kill` and `terminal/release` as client methods on the ACP connection, backed by the
Story 7.1 registry.

**Acceptance criteria:**
- [x] The method names are defined in `lua/codecompanion/acp/methods.lua` and dispatched from the
      connection's request table.
- [x] Each method validates `sessionId` and `terminalId` and returns a JSON-RPC invalid-params
      error for an unknown session or terminal instead of raising.
- [x] `terminal/create` returns `{ terminalId = ... }` immediately and starts the command in the
      background.
- [x] `terminal/output` returns `{ output, truncated, exitStatus? }` in the shape the protocol
      specifies.
- [x] `terminal/wait_for_exit` answers when the process exits and does not block other JSON-RPC
      traffic while waiting.
- [x] `terminal/kill` stops the process and still allows a later `terminal/output` and
      `terminal/wait_for_exit`.
- [x] `terminal/release` is safe to call twice and makes the ID invalid for all other methods.
- [x] A test drives all five methods through a fake agent request and asserts the responses.

**Implementation notes:**
- The connection resolves a chat from `sessionId`; `terminal/create` uses that chat for the
  approval check and as the terminal's owner.
- `terminal/wait_for_exit` registers a callback on the terminal session. `TermClose` resolves the
  callbacks, so the dispatcher never sleeps or polls.
- A second `terminal/release` returns an invalid-params error instead of raising. The ID stays
  invalid for `terminal/output`, `terminal/kill` and `terminal/wait_for_exit`.

**Status:** ✅ DONE

---

## Story 7.3 — Tool-call terminals and the capability flag
**Requirement:** When a tool call embeds `{ type = "terminal", terminalId = ... }`, attach the real
terminal to its activity card. Advertise `clientCapabilities.terminal = true` only after Stories
7.1 and 7.2 pass.

**Acceptance criteria:**
- [x] Tool-call content of type `terminal` is recognised and its `terminalId` is attached to the
      activity card.
- [x] The card shows the terminal's current output and `gA` offers Open terminal, which focuses the
      real terminal buffer.
- [x] After `terminal/release`, the card keeps the final output and the Open terminal action is no
      longer offered for a dead buffer.
- [x] Every ACP adapter in `lua/codecompanion/adapters/acp/` advertises `terminal = true`, and a
      test asserts it.
- [x] The capability is only advertised when all five terminal methods are registered.
- [x] The docs state the co-location assumption and the rendered-output limitation.

**Implementation notes:**
- The capability is injected centrally in `Connection:prepare_adapter()` with
  `vim.tbl_deep_extend("keep", ...)`, so an adapter that sets `terminal = false` still wins.
- Because injection happens at connection time, the adapter files themselves are unchanged. The
  test in `tests/acp/test_acp.lua` prepares an adapter and asserts the resulting capability.
- The handler reads `terminalId` from a `terminal` content block, resolves the buffer through the
  terminal registry and sets `external = false` for those cards. The card prefers the terminal's
  current output and falls back to the agent's `rawOutput` when the buffer is empty.
- `Activity.detach_terminal` keeps the last output when the agent releases the terminal, and
  `actions_for` only offers Open terminal while the buffer is valid.
- `rawOutput` and text content blocks still render for tool calls that carry no terminal.

**Status:** ✅ DONE

---

## Story 7.4 — Read-only snapshot for agent-owned commands
**Requirement:** For a `tool_call` of kind `execute` with no `terminalId`, show a read-only live
snapshot of the command and the output the agent reports. The snapshot must make clear that
CodeCompanion does not own the process.

**Acceptance criteria:**
- [x] The card creates a read-only scratch buffer (`buftype = "nofile"`, `modifiable = false`,
      `readonly = true`) with a header that names the command and says the process belongs to the
      agent.
- [x] The command is taken from `rawInput` when it has a command field, otherwise from the card
      title. Nothing is invented.
- [x] The buffer updates on each `tool_call_update` while the card is running and keeps the last
      reported output when the card completes.
- [x] `gA` offers View command snapshot for these cards and opens the buffer.
- [x] When the agent reports no output, the buffer says so instead of showing an empty terminal.
- [x] Snapshot buffers are deleted when the chat is closed or cleared.
- [x] Tests cover the command header, output updates, the no-output message and cleanup.

**Implementation notes:**
- This is a formatted view of the agent's `rawOutput` and text content blocks, not stdout from a
  process CodeCompanion can read.
- The snapshot reuses the activity card's stable ID, so repeated updates rewrite the same buffer.
- `rawInput.command` and its `args` form the header when present. Otherwise the agent's own tool
  title is used, never a formatted or inferred label.
- `Activity.cleanup` deletes snapshot buffers, and `Chat:close()` and `Chat:clear()` both call it.

**Status:** ✅ DONE

---

## Story 7.5 — Security, cleanup and verification
**Requirement:** Treat `terminal/create` as a privileged request. Apply the active approval policy
and keep every terminal scoped to the session's workspace.

**Acceptance criteria:**
- [x] `cwd` must resolve inside the session root set; a path outside it is rejected.
- [x] The active approval mode is applied to the full command, args and env before a process
      starts. Denying the request starts no process and returns an error to the agent.
- [x] A released terminal leaves no buffer, channel or registry entry behind.
- [x] Closing or clearing a chat releases its terminals and snapshot buffers.
- [x] `make test`, `make format`, `make lint` and `make docs` pass.

**Implementation notes:**
- `cwd` defaults to `vim.fn.getcwd()` and must resolve inside it; a path outside is rejected before
  the approval prompt.
- `yolo` allows the command, `auto` allows a safe command only when it carries no `env`, otherwise
  the user chooses Allow once, Allow always or Reject. Approval is keyed on the full command line
  plus any `env` assignments, so a changed environment needs a fresh approval.
- `Connection:disconnect()` releases terminals owned by its chat. `Chat:close()` and `Chat:clear()`
  release them too, so closing a chat does not leave a process running.
- The ACP spec says a permission request from the agent does not replace the client's own checks.

**Status:** ✅ DONE

---

## Verification

- `tests/interactions/chat/test_terminal.lua` covers the registry, output, truncation, kill and
  release.
- `tests/acp/test_acp.lua` covers the five terminal methods, their error responses and the
  injected `terminal` capability.
- `tests/interactions/chat/acp/test_handler.lua` covers terminal content blocks and the
  agent-owned snapshot.
- `tests/interactions/chat/ui/test_activity.lua` covers the Open terminal and View command
  snapshot actions.

## Limitations

- The co-location assumption is not enforced. A remote agent with a local client will read the
  wrong files and run the wrong shells if `terminal` or `fs` is advertised.
- Terminal output is the rendered buffer text, so ANSI styling, wrapped lines and control
  sequences are not preserved byte for byte.
- Agent-owned commands remain opaque. The snapshot shows only what the agent reports, and cannot
  be stopped or inspected beyond that.
