# Task 6 — Hardening, formatting, tests, release

## Story 6.1 — Full test suite
**Requirement:** Run full Mini.Test suite; ensure new/updated tests pass.

**Acceptance criteria:**
- [x] `make test` passes with 0 failures.
- [x] Targeted tests per feature file pass via `make test_file FILE=`.

**Implementation notes:**
- `make test` passes with 0 failures and 4 expected notes on Neovim 0.13.0-dev.
- New and extended coverage: `tests/interactions/chat/test_session_picker.lua`, `tests/interactions/chat/test_ui_controls.lua`, `tests/interactions/chat/acp/test_handler.lua`, `tests/interactions/chat/tools/builtin/edit_file/test_edit_file.lua` and `tests/interactions/chat/tools/builtin/test_create_file.lua`.
- Targeted runs for each changed test file pass via `make test_file FILE=`.

**Status:** ✅ DONE

---

## Story 6.2 — Formatting & static checks
**Requirement:** Run `make format` (StyLua, 120 cols, 2 spaces).

**Acceptance criteria:**
- [x] `stylua` passes with no diffs.
- [x] `luacheck`/static diagnostics clean (per repo config).

**Implementation notes:**
- StyLua 2.6.0 was downloaded to `/tmp/opencode/stylua` because it wasn't installed. `make format` completes with no remaining diff.
- Added `.luacheckrc` for the Neovim/LuaJIT runtime and a `make lint` target. Luacheck 1.2.0 is installed in the gitignored `deps/luacheck` tree; `make lint` prefers a `luacheck` on `PATH` and falls back to that tree. Override with `LUACHECK=...`.
- `make lint` reports `0 warnings / 0 errors in 280 files`. Existing warnings were fixed rather than silenced where they were real (dead assignments, shadowed locals, an accidental global in the symbols slash command). The config ignores only callback-signature, intentional-early-exit, empty-branch, and line-length warnings, which StyLua owns.

**Status:** ✅ DONE

---

## Story 6.3 — Manual UX verification checklist
**Requirement:** User must manually verify in Neovim + OpenCode:
- Fresh chat shows session list; selection restores history; New Chat works.
- Composer bottom box; model/effort/agent/permission controls work; submit via real path.
- + button attaches buffer/all buffers; chips/removal.
- Changed-files strip lists edits with +/-; per-file diff opens; review-all.
- Running agent: tool cards accordion; thinking accordion; allow/deny per mode.
- Terminal/background when supported.

**Acceptance criteria:**
- [ ] All manual checks pass on a live OpenCode session.
- [ ] No regressions in history/ACP lifecycle.

**Implementation notes:**
- Not run. This requires a live Neovim session with the OpenCode ACP adapter and a real agent, which isn't available to the automated workspace.
- Pending checks: session list restore, composer controls, context chips, changed-file strip and per-file review, activity accordions and permission modes.

**Status:** ⏳ PENDING

---

## Story 6.4 — Documentation
**Requirement:** Update docs via `make docs` after doc-page changes; read
`.codecompanion/skills/writing-docs/SKILL.md` first.

**Acceptance criteria:**
- [x] Vimdoc regenerated (`:h CodeCompanionChat`).
- [x] New keymaps/shortcuts documented.

**Implementation notes:**
- `doc/usage/chat-buffer/index.md` now documents the composer, `g+`, `gO`, `gF` and the send/newline/clear keys.
- `doc/configuration/chat-buffer.md` documents `composer_controls` and `session_picker`.
- `make docs` regenerated `doc/codecompanion.txt` with Pandoc 3.13 (installed to `/tmp/opencode/pandoc` for the run).

**Status:** ✅ DONE

---
