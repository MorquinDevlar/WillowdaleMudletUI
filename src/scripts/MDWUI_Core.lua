--[[
  MDWUI_Core.lua
  Shared plumbing for the Willowdale UI: GMCP requests, formatting, widget
  helpers, and lifecycle (handler/timer registration and cleanup).

  Dependencies: MDWUI_Config.lua must be loaded first.
]]

---------------------------------------------------------------------------
-- GMCP REQUESTS (client -> server)
-- Two forms, per the GMCP guide section 3. Form A (node request) for
-- specific nodes; the legacy "SendFullPayload" for the everything-refresh.
---------------------------------------------------------------------------

--- Request one GMCP node (Form A). `json` is an optional raw JSON body,
-- e.g. '{"id":8}' - kept as a string so we need no JSON encoder dependency.
function mdwui.request(node, json)
  if sendGMCP then
    sendGMCP(node, json or "{}")
  end
end

--- Ask the server to resend the entire login batch (Char, Room, Map, Group,
-- Game, and Comm.History). Used at build time and after Engine.Copyover.
function mdwui.requestFullPayload()
  if sendGMCP then
    sendGMCP("GMCP", '"SendFullPayload"')
  end
end

---------------------------------------------------------------------------
-- FORMATTING
---------------------------------------------------------------------------

--- Convert a server ANSI string (Char.Vitals.prompt, Comm.Channel.ansi) into
-- decho format. Guarded: ansi2decho ships with Mudlet but not with the test
-- harness, and a raw string beats an error either way.
function mdwui.ansiToDecho(s)
  if type(s) ~= "string" then return "" end
  if ansi2decho then
    local ok, out = pcall(ansi2decho, s)
    if ok and out then return out end
  end
  return s
end

--- Thousands-separated number, honoring the Char.Info.number_format display
-- preference the web client also applies ("none" disables grouping).
function mdwui.fmtNum(n)
  n = tonumber(n) or 0
  local info = gmcp and gmcp.Char and gmcp.Char.Info
  if info and info.number_format == "none" then
    return tostring(n)
  end
  local s = tostring(math.floor(n))
  local grouped = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return grouped
end

--- One decho gauge line: colored fill blocks + dim empty blocks + label.
-- Text gauges because MDW widget content is a MiniConsole, not a canvas.
function mdwui.gauge(cur, max, color, label)
  local cfg = mdwui.config
  cur, max = tonumber(cur) or 0, tonumber(max) or 0
  local pct = (max > 0) and math.min(1, math.max(0, cur / max)) or 0
  local filled = math.floor(pct * cfg.gaugeWidth + 0.5)
  return string.format("<%s>%s<60,60,60>%s<r> %s",
    color, string.rep("#", filled), string.rep("-", cfg.gaugeWidth - filled), label or "")
end

--- HP-style gauge color for a percentage, using the web client's thresholds.
function mdwui.healthColor(cur, max)
  local c = mdwui.config
  cur, max = tonumber(cur) or 0, tonumber(max) or 0
  local pct = (max > 0) and (cur / max) or 0
  if pct <= c.hpLowPct then return c.colors.bad end
  if pct <= c.hpMidPct then return c.colors.warn end
  return c.colors.good
end

--- "MM:SS" / "1h02m" style short duration; -1 is permanent (guide 8.5).
function mdwui.fmtDuration(seconds)
  seconds = tonumber(seconds) or 0
  if seconds < 0 then return "perm" end
  if seconds >= 3600 then
    return string.format("%dh%02dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
  end
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

---------------------------------------------------------------------------
-- WIDGET HELPERS
---------------------------------------------------------------------------

--- Our widget by name, or nil when MDW (or the widget) is not up - GMCP can
-- fire in the teardown-to-setup gap during an MDW update (guide-recommended
-- guard), so every renderer starts here.
function mdwui.w(name)
  local widget = mdw and mdw.widgets and mdw.widgets[name]
  if widget and widget.content then return widget end
  return nil
end

--- Emit a clickable action into a widget console. `command` is sent verbatim,
-- matching the web client's rule that widget affordances are real commands.
function mdwui.link(console, dechoText, command, hint)
  console:dechoLink(dechoText, function() send(command) end, hint or command, true)
end

--- Bind a render-from-state function as a widget's reflow. Why: MDW's own
-- reflow replays an echo buffer, which cannot reproduce clickable links.
-- These panels are pure functions of the gmcp table, so on any resize we
-- re-render from state instead - the renderers write straight to the
-- console (never through widget:echo) precisely so MDW's buffer stays empty
-- and this instance reflow is the only repaint path.
function mdwui.bindRenderer(widget, renderFn)
  widget.reflow = function()
    local ok, err = pcall(renderFn)
    if not ok and mdw and mdw.debugEcho then
      mdw.debugEcho("MDW_UI render error: %s", tostring(err))
    end
  end
end

---------------------------------------------------------------------------
-- LIFECYCLE
-- Named handlers and timers are registered through here so a package
-- uninstall can remove every trace (MDW's own discipline, applied to us).
---------------------------------------------------------------------------

function mdwui.registerHandler(event, fn)
  local name = mdwui.packageName .. "_" .. event
  registerNamedEventHandler(mdwui.packageName, name, event, fn)
  mdwui.state.handlers[name] = true
end

function mdwui.killAllHandlers()
  for name in pairs(mdwui.state.handlers) do
    deleteNamedEventHandler(mdwui.packageName, name)
  end
  mdwui.state.handlers = {}
end

function mdwui.addTimer(id)
  mdwui.state.timers[#mdwui.state.timers + 1] = id
end

function mdwui.killAllTimers()
  for _, id in ipairs(mdwui.state.timers) do
    if killTimer then pcall(killTimer, id) end
  end
  mdwui.state.timers = {}
end

--- Full self-removal on package uninstall: our widgets, handlers, timers,
-- and the MDW registration - MDW itself stays untouched.
function mdwui.onUninstall(_, package)
  if package ~= mdwui.packageName then return end
  mdwui.killAllTimers()
  mdwui.killAllHandlers()
  for name in pairs(mdwui.state.widgets) do
    local widget = mdw and mdw.widgets and mdw.widgets[name]
    if widget and widget.destroy then widget:destroy() end
  end
  mdwui.state.widgets = {}
  if mdw and mdw.onReady then
    mdw.onReady[mdwui.packageName] = nil
  end
end
