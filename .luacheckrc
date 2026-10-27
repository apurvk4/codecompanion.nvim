std = "luajit"

-- Neovim exposes the `vim` API as a global. `_` is the conventional discard name.
-- `bit32` is only read when LuaJIT's `bit` is unavailable.
globals = { "vim", "_" }
read_globals = { "bit32" }

ignore = {
  "212", -- unused argument: callbacks and interface functions keep their signatures
  "213", -- unused loop variable
  "512", -- loop executes at most once: intentional early return
  "542", -- empty branch: documents an intentional no-op
  "631", -- line length is owned by StyLua; long strings and comments are allowed
}

-- `table.unpack` is absent from LuaJIT and the fallback is intentional.
files["lua/codecompanion/utils/async.lua"] = {
  ignore = { "143" },
}
