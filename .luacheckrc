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
  -- Main-console output for the `ui` command (results, listings, and the
  -- overview's clickable command lines). Named colours there, not the
  -- widgets' decho triplets - see MDWUI_Commands.lua's header.
  "cecho",
  "cechoLink",
  "echo",
  -- The alias's capture groups (src/aliases/ui.lua).
  "matches",
  -- Mudlet's JSON decoder (LuaGlobal.lua aliases yajl.to_value); read
  -- guarded, so an older Mudlet without it degrades instead of erroring.
  "json_to_value",
  "deleteNamedEventHandler",
  "getMudletHomeDir",
  -- The self-updater (MDWUI_Update.lua): Mudlet's asynchronous downloader and
  -- the package/module installers. downloadFile is read guarded, the rest are
  -- only ever reached after it answered.
  "downloadFile",
  "installPackage",
  "uninstallPackage",
  "getModulePath",
  "reloadModule",
  -- Native key folder toggle (numpad walking ships in src/keys); read guarded.
  "enableKey",
  "disableKey",
  "killTimer",
  "registerNamedEventHandler",
  "send",
  "sendGMCP",
  "tempTimer",
  gmcp = { other_fields = true },
  -- Sibling Willowdale package (version-exposure convention); read guarded,
  -- never assumed installed.
  mapper = { other_fields = true },
}

ignore = {
  "212", -- Unused argument (project convention: prefix with _ when intentional)
}

-- The test stub IS the Mudlet API: it defines the global surface everything
-- else reads, so global warnings (1xx) are noise there.
files["tests/**/*.lua"] = {
  ignore = { "1" },
}
