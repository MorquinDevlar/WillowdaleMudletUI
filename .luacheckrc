-- Luacheck configuration for MDW_UI (Willowdale MUD UI for Mudlet).
-- Mudlet runs Lua 5.1 / LuaJIT and injects a large global API surface.

std = "lua51+luajit"
max_line_length = 150

globals = {
  "mdwui",
  "mdw", -- seeded (mdw = mdw or {}) so load order vs the MDW package is free
}

read_globals = {
  "ansi2decho",
  "deleteNamedEventHandler",
  "getMudletHomeDir",
  "killTimer",
  "registerNamedEventHandler",
  "send",
  "sendGMCP",
  "tempTimer",
  gmcp = { other_fields = true },
}

ignore = {
  "212", -- Unused argument (project convention: prefix with _ when intentional)
}

-- The test stub IS the Mudlet API: it defines the global surface everything
-- else reads, so global warnings (1xx) are noise there.
files["tests/**/*.lua"] = {
  ignore = { "1" },
}
