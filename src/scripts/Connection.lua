--[[
  Connection.lua
  The Connection Stats widget: what this session costs on the wire
  (guide section 5.17, Game.Connection).

  The LAYOUT is the web client's Connection Stats panel: a "Session bandwidth"
  header with a Refresh affordance, then label/value rows - transport,
  compression state, compression, the three byte totals, and the saved
  percentage with its ratio - over an italic footnote about how the figures
  were counted.

  PULL-ONLY, which is the one thing that makes this widget unlike every other
  panel here. Nothing pushes Game.Connection: it is asked for, or it is never
  seen. So this module owns a poll of its own (the web client's, 2 seconds)
  that runs ONLY while the widget is on screen - a hidden panel must not cost
  the connection a request every two seconds for the life of a session, and
  the numbers it would collect are ones nobody is looking at.

  Only the server can measure any of this. Mudlet hands a script already
  decompressed text and the browser's WebSocket API does the same, so a client
  cannot count its own wire bytes - which is why the guide makes this a GMCP
  node rather than something a client works out locally.

  Dependencies: Config.lua, Core.lua.
]]

-- The web client polls its panel every 2 seconds while it is open.
local POLL_SECONDS = 2

-- Wire names (guide 5.17) mapped to what the web panel calls them. The
-- compression row says both the algorithm and the mechanism it belongs to,
-- because "deflate" alone means nothing to a player deciding whether their
-- connection is behaving.
local TRANSPORTS = { telnet = "Telnet", websocket = "WebSocket" }
local COMPRESSIONS = {
  zlib = "Zlib (MCCP2)",
  deflate = "Deflate (permessage-deflate)",
  none = "None",
}

--- How the three enum fields are spelled, for the widget and for
-- `ui connection` both - one source, so the panel and the typed answer can
-- never disagree about what the connection is doing.
-- @return transport, compression, compression state
function mdwui.connectionText(s)
  s = mdwui.tbl(s)
  return TRANSPORTS[s.transport] or mdwui.titleCase(s.transport or "-"),
    COMPRESSIONS[s.compression] or mdwui.titleCase(s.compression or "-"),
    s.active and "Active" or "Inactive"
end

--- The payload, or an empty table before the first answer arrives.
local function stats()
  return mdwui.tbl(mdwui.tbl(gmcp and gmcp.Game).Connection)
end

--- Ask the server for the current figures. Also the Refresh row's action and
-- what `ui refresh connection` sends.
function mdwui.requestConnection()
  mdwui.request("Game.Connection")
end

--- Byte counts the way the web panel prints them: 1024-based, and the
-- precision drops as the unit grows (421.3 KB, 2.29 MB) so the column stays
-- the same width whatever the session has done.
function mdwui.fmtBytes(n)
  n = tonumber(n) or 0
  if n < 1024 then return string.format("%d B", math.floor(n)) end
  if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
  return string.format("%.2f MB", n / (1024 * 1024))
end

--- One label/value line: label flush left, value flush right, the way the web
-- panel's space-between rows read.
--
-- The pair WRAPS rather than clips when the dock is too narrow for both - the
-- value drops onto its own line, still flush right. The web panel is a wide
-- floating dockview pane and this one is usually a 250px sidebar, where
-- "Compression  Deflate (permessage-deflate)" does not fit on any one line;
-- clipping there would eat either the label or the answer, and both of them
-- are the content.
local function row(co, W, label, value, valueColor)
  local C = mdwui.config.colors
  local text, tw = mdwui.clipText(tostring(value), W)
  local labelText, lw = mdwui.clipText(tostring(label), W)
  valueColor = valueColor or C.text
  if lw + 1 + tw > W then
    co:decho(string.format("<%s>%s\n%s<%s>%s\n", C.text, labelText,
      string.rep(" ", W - tw), valueColor, text))
    return
  end
  co:decho(string.format("<%s>%s%s<%s>%s\n", C.text, labelText,
    string.rep(" ", W - lw - tw), valueColor, text))
end

--- Repaint from Game.Connection.
function mdwui.renderConnection()
  local widget = mdwui.w("Connection")
  if not widget then return end
  local C = mdwui.config.colors
  local s = stats()

  -- The header band, as a row rather than console text: it carries the
  -- Refresh affordance, and a row's click target is the whole strip - which
  -- is what a header a player pokes at to re-read the numbers should be.
  -- Under an MDW predating the rows API the panel simply has no header; the
  -- figures below are the part that matters, and `ui refresh connection`
  -- reaches the same request.
  if mdw and mdw.setWidgetRows then
    mdw.setWidgetRows("Connection", {
      { id = "hdr", type = "text",
        text = string.format("<%s>Session bandwidth", C.charGold),
        rightText = string.format("<%s>Refresh", C.link),
        -- The band and its rule, from the shared divider colour: the decho
        -- triplets in config double as CSS rgb() arguments.
        css = string.format("background-color: rgba(255,255,255,4%%); "
          .. "border-bottom: 1px solid rgb(%s);", C.charDivider),
        onClick = function() mdwui.requestConnection() end },
    })
  end

  local co = widget.content
  co:clear()
  local W = mdwui.wrapWidth(widget, 34)

  if next(s) == nil then
    co:decho(string.format("<%s>Waiting for the server's figures.\n", C.faint))
    return
  end

  local transport, compression, state = mdwui.connectionText(s)
  row(co, W, "Transport", transport)
  -- `active` follows the LIVE stream, not the history: it goes false when the
  -- server shuts compression down before a copyover while the byte totals
  -- keep everything that was saved (guide 5.17).
  row(co, W, "Compression state", state, s.active and C.good or C.dim)
  row(co, W, "Compression", compression)
  row(co, W, "Expanded", mdwui.fmtBytes(s.bytes_sent))

  -- measured = false means no wire bytes have been counted yet, and the guide
  -- is explicit that the derived fields are then UNAVAILABLE rather than
  -- zero - so the rows that depend on a wire count say nothing instead of
  -- claiming a session saved 100% of everything it has ever sent.
  if s.measured then
    row(co, W, "Wire sent", mdwui.fmtBytes(s.bytes_wire))
    row(co, W, "Saved", mdwui.fmtBytes(s.bytes_saved))
    row(co, W, "Bandwidth saved", string.format("%.1f%% (%.2f:1)",
      tonumber(s.saved_pct) or 0, tonumber(s.ratio) or 0), C.good)
  else
    for _, label in ipairs({ "Wire sent", "Saved", "Bandwidth saved" }) do
      row(co, W, label, "-", C.dim)
    end
  end

  co:decho("\n")
  -- Transport-dependent, because the caveat is: over HTTPS the wire figure is
  -- counted underneath TLS and carries its record framing, so the real ratio
  -- is better than shown. Telnet figures are exact, and printing the apology
  -- there would be inventing an inaccuracy (guide 5.17).
  local note = (s.transport == "telnet")
    and "Counted server-side at the socket. Telnet figures are exact."
    or "Counted server-side at the socket. Over HTTPS the wire figure includes "
      .. "TLS framing, so the real compression ratio is slightly better than shown."
  mdwui.wrapEcho(co, W, C.faint, note, "", "i")
end

--- Is the panel on screen? The whole poll hangs off this: a closed widget
-- costs the connection nothing.
local function shown()
  local widget = mdw and mdw.widgets and mdw.widgets["Connection"]
  if not widget then return false end
  if not mdw.isWidgetShown then return true end
  return mdw.isWidgetShown(widget) and true or false
end

--- Start the 2s poll (buildUI). Registered like every other timer, so an MDW
-- teardown and a package uninstall both stop it - and buildUI's killAllTimers
-- is what keeps a rebuild from stacking a second one.
function mdwui.startConnectionPoll()
  local tid = tempTimer(POLL_SECONDS, function()
    if shown() then mdwui.requestConnection() end
  end, true)
  if tid then mdwui.addTimer(tid) end
end

--- Reveal or close the panel - the gear-menu row's action, and what makes
-- the row worth having: this widget is not in the default layout, so the
-- Widgets menu is the only other place a player would find it.
--
-- The reveal asks IMMEDIATELY rather than leaving the panel empty for up to
-- two seconds: a pull-only node has nothing cached to paint from the first
-- time it is opened.
function mdwui.toggleConnection()
  local widget = mdw and mdw.widgets and mdw.widgets["Connection"]
  if not widget then return end
  if shown() then
    if mdw.hideWidget then mdw.hideWidget("Connection") end
    return
  end
  if mdw.showWidget then mdw.showWidget("Connection") end
  mdwui.requestConnection()
end

--- The gear-menu row (mdw.addMenuItem, MDW 0.7). Declared from buildUI, so
-- MDW stamps it with this package and reaps it with us; re-declaring on every
-- build replaces the row in place rather than adding a second one.
--
-- Unguarded, like every other MDW call inside buildUI: the version gate at
-- the top of it is what guarantees the API, and this row is not a garnish -
-- the panel is closed on a first run, so the gear is where a player finds it.
function mdwui.setupConnectionMenu()
  mdw.addMenuItem({
    id = "connection",
    -- A LABEL getter and no checkbox: the row names the action it performs,
    -- the way the Sidebars rows do not have to because a sidebar is always
    -- there to tick. This panel is off by default and off most of the time,
    -- so an unticked box reads as "unavailable" where "Show connection stats"
    -- reads as the thing to click. MDW resolves the getter on every gear
    -- open, which is what keeps the wording honest however the panel was
    -- closed - this row, the Widgets menu, or the panel's own X.
    label = function()
      return shown() and "Hide connection stats" or "Show connection stats"
    end,
    onClick = function() mdwui.toggleConnection() end,
  })
end
