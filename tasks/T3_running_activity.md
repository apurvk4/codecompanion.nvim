# Task 3 — Inspectable running agent activity

While the agent is working, its thinking, tool calls and commands must be visible as activity
cards with a status and expandable output. Active work stays visible; completed details can
collapse. Terminal and background actions are offered only when CodeCompanion holds a real
process handle and the adapter protocol supports it.

## Story 3.1 — Activity cards with stable IDs and in-place updates
**Requirement:** Render every running tool call, command and agent-reported activity as a card
with a stable ID, title, status (`running`, `success`, `error`, `cancelled`) and expandable
output. Update the existing card when a later event carries the same ID instead of appending a
duplicate. Keep running cards expanded and visible.

**Acceptance criteria:**
- [x] ACP `tool_call` and `tool_call_update` events with the same `toolCallId` update one card.
- [x] HTTP tool calls receive a stable ID from the tool call and update the same card.
- [x] Status changes are reflected without reordering unrelated transcript content.
- [x] Running activity stays visible; completed cards can collapse.
- [x] A card without a usable ID falls back to append-only rendering and logs why.

**Implementation notes:**
- `lua/codecompanion/interactions/chat/ui/activity.lua` owns a per-buffer registry of cards keyed
  by the backend's stable ID. Output and child rows are virtual lines, so updating a card never
  moves the transcript or another card's line numbers.
- `tools/orchestrator.lua` uses the tool call's `id`; ACP `handler.lua` uses `toolCallId`.
  Repeated events update the existing card in place.
- A missing or empty ID gets a generated `__activity_N` ID, is marked `append_only`, and logs why
  it cannot be updated by a later event.
- Running cards force-expand. Successful cards collapse unless the user has toggled them.
  Error and cancelled cards stay expanded until manually toggled.

**Status:** ✅ DONE

---

## Story 3.2 — Thinking and reasoning accordions
**Requirement:** Show model- or agent-supplied thinking summaries in a collapsible accordion.
Display only reasoning that the backend explicitly supplies and its contract permits. Never
fabricate, reconstruct or expose hidden chain-of-thought.

**Acceptance criteria:**
- [x] ACP reasoning updates render in a dedicated accordion.
- [x] Providers that expose a thinking/reasoning summary render it with the same interaction.
- [x] Providers that expose no reasoning show no empty accordion.
- [x] Collapse state survives unrelated transcript updates.
- [x] No reasoning is synthesized from tool calls, prompts or message text.

**Implementation notes:**
- Reuses the existing `REASONING_MESSAGE` block and `ui/folds.lua` reasoning accordion. ACP
  `handle_thought_chunk` writes reasoning messages; leaving the reasoning block folds it.
- The same builder path serves HTTP adapters that supply reasoning.
- A fold is only created from a real `### Reasoning` section with a body. No reasoning message
  means no accordion.
- The reasoning fold is manual and is not recreated by unrelated writes, so its closed state
  survives later transcript updates.
- No code derives reasoning from prompts, tool calls or message text.

**Status:** ✅ DONE

---

## Story 3.3 — Tool call accordion with captured output
**Requirement:** Each tool call renders as an accordion containing the tool name, arguments,
status and captured output. Expanding reveals the output; collapsing hides it without discarding
it. Errors remain visible even when the card is collapsed.

**Acceptance criteria:**
- [x] Tool cards show name, status and a short argument summary.
- [x] Expanding shows the captured stdout/stderr or tool result.
- [x] Collapsing hides output but keeps it available for reopening.
- [x] Error output is visible or clearly flagged while collapsed.
- [x] Output is attributed to the correct chat and tool call.

**Implementation notes:**
- Card titles come from the tool's `output.cmd_string`, with a fallback that summarises common
  argument keys (`filepath`, `path`, `url`, `query`, `pattern`, `cmd`, `command`, `name`).
- Status is shown by the existing tool icon plus a `[status]` suffix.
- HTTP output is captured from the orchestrator's tool output; ACP output comes from `rawOutput`
  and text content blocks.
- Output is stored on the card even when collapsed. Collapsed errors show the first output line
  plus a hidden-lines hint.
- The registry is keyed by chat buffer and card ID, so output cannot leak between chats.

**Status:** ✅ DONE

---

## Story 3.4 — Commands, terminal and background execution
**Requirement:** For a command whose process or terminal handle is genuinely available, let the
user open its terminal and send the process to the background. Background work must remain
discoverable and stoppable. Do not offer terminal or background actions for an external ACP
process unless CodeCompanion holds a real handle and protocol support; show captured output and
explain the limitation instead.

**Acceptance criteria:**
- [x] A local command card exposes Open Terminal only when a terminal buffer exists for it.
- [ ] A local command card exposes Background only when the process can keep running detached.
- [ ] Backgrounded commands remain listed with a running status and a Stop action.
- [ ] Stopping a background command terminates it and updates the card.
- [x] ACP command cards without a handle show captured output and the limitation, with no
      terminal or background action.
- [x] The UI never presents an action that would silently do nothing.

**Implementation notes:**
- `run_command` and the HTTP orchestrator still use `vim.system` and create no terminal buffer.
  The activity card gates Open Terminal on a valid `terminal_bufnr`, so it is never offered for
  these commands.
- The background action is only offered when a card has a real `on_background` handler. No
  current tool supplies one, because the agent loop waits on the tool callback and CodeCompanion
  cannot detach the process from that loop yet. The `Activity.background` API and its gating are
  covered by tests with a stub handler.
- `Activity.stop` terminates a card's job and marks it cancelled. The orchestrator's current
  command is stoppable through the same path.
- ACP `execute` cards show captured output and the sentence
  "No terminal or background handle is available for this agent-owned command." They also get a
  read-only snapshot of the command and the output the agent reports.
- The action menu only lists actions backed by a valid buffer, job or handler.
- ACP `terminal/*` support and the `terminal = true` capability landed in
  `tasks/T7_acp_terminal.md`. Background execution remains the open part of this story.

**Status:** 🟡 PARTIAL

---

## Story 3.5 — Nested subagent and submodel activity
**Requirement:** Show subagent or submodel work as nested activity only when the backend supplies
reliable parent/child identifiers. Never infer nesting from timing, order or titles.

**Acceptance criteria:**
- [x] A child activity with a known parent ID renders inside that parent.
- [x] An activity without a parent ID renders at the top level.
- [x] Parent collapse hides its children and expanding restores them.
- [x] Unknown parent IDs fall back to top-level rendering and log why.
- [x] No nesting is inferred from message order or naming conventions.

**Implementation notes:**
- A card nests only when `Activity.upsert` receives an explicit `parent_id` that matches an
  existing card. Children render as indented virtual lines under their parent.
- Unknown parent IDs render at the top level and log the missing parent.
- No timing, order or title heuristics are used.
- Current ACP tool-call updates do not carry a parent/child identifier, so nesting stays dormant
  until an agent supplies one. The rendering and fallback paths are covered by tests.

**Status:** ✅ DONE

---

## Story 3.6 — Allow, deny and background lifecycle
**Requirement:** Permission prompts must respect the active mode and the adapter's semantics.
Default/Ask prompts before protected work; Auto approves only actions covered by safe rules and
prompts for risky or unknown actions; Allow all runs without prompting after an explicit warning.
ACP one-time versus persistent choices must be preserved. Denying an action must not start it.

**Acceptance criteria:**
- [x] Default/Ask prompts for every protected tool or command.
- [x] Auto approves only safe actions and still prompts for risky or unknown actions.
- [x] Allow all requires an explicit selection and shows a warning before use.
- [x] ACP one-time and persistent permission choices are presented distinctly.
- [x] Denying a tool or command returns a rejection to the agent and starts no process.
- [x] Backgrounded work cannot bypass the active permission mode.

**Implementation notes:**
- Reuses the existing approval modes in
  `lua/codecompanion/interactions/chat/tools/approvals.lua`, the `gty` mode menu, and the ACP
  permission flow in `acp/request_permission.lua`. No parallel approval path was added.
- The `gty` menu offers Default / Ask, Auto-approve safe actions and Allow all, and warns when
  Allow all is selected.
- ACP `allow_once`, `allow_always`, `reject_once` and `reject_always` remain distinct.
- Rejection returns the existing rejection message to the agent and does not start a process.
- Background is only offered for a card that is already running, so it cannot bypass the
  permission decision that allowed the work to start.

**Status:** ✅ DONE

---

## Verification

- `tests/interactions/chat/ui/test_activity.lua` covers stable IDs, in-place updates, append-only
  fallback, collapse behaviour, error visibility, nesting, action gating, stop and per-chat
  attribution.
- `tests/interactions/chat/acp/test_handler.lua` covers repeated ACP tool-call IDs, missing IDs
  and the ACP reasoning accordion.
- `tests/interactions/chat/tools/test_orchestrator.lua` covers an HTTP tool call creating one
  card with captured output and the argument-summary fallback.
- `tests/interactions/chat/ui/test_fold_reasoning_output.lua` covers reasoning folds surviving
  unrelated transcript output.
- Approval behaviour remains covered by `tests/interactions/chat/tools/test_approvals.lua` and
  `tests/interactions/chat/acp/test_permission_request.lua`.
