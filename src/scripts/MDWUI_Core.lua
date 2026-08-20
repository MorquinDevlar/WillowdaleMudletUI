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
-- The payload must be the BARE text SendFullPayload: the server matches the
-- raw bytes after the first space (gmcp.go's `case 'GMCP'`) without JSON
-- decoding, so a quoted body is silently dropped.
function mdwui.requestFullPayload()
  if sendGMCP then
    sendGMCP("GMCP", "SendFullPayload")
  end
end

--- Normalize a GMCP list/map value to a table; any non-table becomes {}.
-- Defense-in-depth: OLDER server builds marshaled nil Go slices/maps as JSON
-- null, which Mudlet decodes to a truthy userdata sentinel - `x or {}`
-- passes it through and ipairs/# then error. The current server guarantees
-- []/{}, but the guard costs nothing and keeps old builds working.
function mdwui.tbl(v)
  if type(v) == "table" then return v end
  return {}
end

--- Compare dotted numeric version strings: true when `have` >= `want`.
-- Component by component as NUMBERS, because string comparison would rank
-- "0.10.0" below "0.4.0". Missing trailing components count as 0, so "0.4"
-- satisfies "0.4.0"; a nil/non-string or number-free `have` is "too old".
function mdwui.versionAtLeast(have, want)
  if type(have) ~= "string" then return false end
  local h, w = {}, {}
  for n in have:gmatch("%d+") do h[#h + 1] = tonumber(n) end
  for n in tostring(want or ""):gmatch("%d+") do w[#w + 1] = tonumber(n) end
  if #h == 0 then return false end
  local count = math.max(#h, #w)
  for i = 1, count do
    local a, b = h[i] or 0, w[i] or 0
    if a ~= b then return a > b end
  end
  return true
end

--- Is the installed MDW new enough for the APIs this package calls?
function mdwui.mdwSatisfied()
  return mdwui.versionAtLeast(mdw and mdw.version, mdwui.minMdwVersion)
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

--- The web client's titleCase (gmcp-ui.js): uppercase each word's first
-- letter, leave the rest alone ("valenra channeler" -> "Valenra Channeler").
function mdwui.titleCase(s)
  return (tostring(s):gsub("%f[%a]%a", string.upper))
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

---------------------------------------------------------------------------
-- GRAPHICAL GAUGE STYLING (shared by the prompt layer, Combat, and Group)
-- Qt stylesheet transcriptions of webclient.css .gauge-bar/.gauge-bar-fill.
---------------------------------------------------------------------------

function mdwui.fillCss(color)
  return string.format("background-color: %s; border-radius: 4px;", color)
end

function mdwui.trackCss(color)
  return string.format("background-color: %s; %s", color, mdwui.config.gauges.frame)
end

--- HP fill color, shifting amber/red at the web-client thresholds.
function mdwui.hpFillColor(cur, max)
  local cfg = mdwui.config
  cur, max = tonumber(cur) or 0, tonumber(max) or 0
  local pct = (max > 0) and (cur / max) or 0
  if pct <= cfg.hpLowPct then return cfg.gauges.hpFillLow end
  if pct <= cfg.hpMidPct then return cfg.gauges.hpFillMid end
  return cfg.gauges.hpFill
end

--- Group-member fill color (gmcp-ui.js groupHealthClass bands: 75/40/15).
function mdwui.grpFillColor(cur, max)
  local g = mdwui.config.gauges
  cur, max = tonumber(cur) or 0, tonumber(max) or 0
  local pct = (max > 0) and (cur / max * 100) or 0
  if pct >= 75 then return g.grpHigh end
  if pct >= 40 then return g.grpMid end
  if pct >= 15 then return g.grpLow end
  return g.grpCritical
end

---------------------------------------------------------------------------
-- SETTINGS
-- Player toggles from the vertical-ellipsis menus, persisted in MDW's
-- layout file under our package name (the mdw.gameSettings contract).
---------------------------------------------------------------------------

--- The live settings table for one section ("promptBar" / "combat"),
-- creating it from `defaults` on first use. Defaults also fill in keys a
-- saved table predates, so new toggles appear for existing saves. The
-- returned table is the stored one - mutate it, then mdwui.saveSettings().
function mdwui.settings(section, defaults)
  mdw.gameSettings = mdw.gameSettings or {} -- older MDW: live-only fallback
  local root = mdw.gameSettings[mdwui.packageName]
  if not root then
    root = {}
    mdw.gameSettings[mdwui.packageName] = root
  end
  local s = root[section]
  if not s then
    s = {}
    root[section] = s
  end
  for k, v in pairs(defaults or {}) do
    if s[k] == nil then s[k] = v end
  end
  return s
end

function mdwui.saveSettings()
  if mdw and mdw.saveLayout then mdw.saveLayout() end
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

--- True while the current room is a shop (Room.Info.Basic.environment,
-- guide 5.14) - gates the item menus' Sell row. tbl-guarded per field: the
-- Room packages carry the same nil-marshaling history as the Char ones.
function mdwui.inShop()
  local basic = mdwui.tbl(mdwui.tbl(mdwui.tbl(gmcp and gmcp.Room).Info).Basic)
  return basic.environment == "Shop"
end

--- Emit a clickable name that opens MDW's context menu - the web client's
-- item pattern (gmcp-ui.js itemContextMenu): click the name, act from the
-- menu. Actions are { label, command } (a real game command, per the
-- outbound rule) or { label, fn }; { separator = true } draws a divider.
-- `actions` may also be a FUNCTION returning that array, evaluated when the
-- menu OPENS - for rows gated on state that changes without a repaint of
-- the widget (the web client builds its menus in the click handler too).
function mdwui.menuLink(co, dechoText, title, actions, hint)
  co:dechoLink(dechoText, function()
    -- Guarded: under an MDW too old for the API the name is simply inert.
    if not (mdw and mdw.showContextMenu) then return end
    local items = {}
    for _, action in ipairs(type(actions) == "function" and actions() or actions) do
      local cmd = action.command
      items[#items + 1] = action.separator and { separator = true }
        or { label = action.label, onClick = action.fn or function() send(cmd) end }
    end
    mdw.showContextMenu(title, items)
  end, hint or title, true)
end

--- Tooltip text for an item link, mirroring the web client's tooltip boxes
-- (updateEquipSlot / attachInventoryTooltip in gmcp-ui.js): the item name,
-- "Type (Subtype)" title-cased, then the caller's extra lines (equipment
-- adds its detail flags and "Use: Remove"; inventory "Use: <command>" and
-- "Uses: N"). Plain text - Mudlet shows link hints as native Qt tooltips,
-- this UI's stand-in for the web .item-tooltip box.
function mdwui.itemTooltip(item, extra)
  local lines = { item.name or "?" }
  local t = mdwui.titleCase(item.type or "")
  if item.sub_type and item.sub_type ~= "" then
    t = string.format("%s (%s)", t, mdwui.titleCase(item.sub_type))
  end
  if t ~= "" then lines[#lines + 1] = t end
  for _, line in ipairs(extra or {}) do
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
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
  -- These reflows are cheap pure repaints, not echo-buffer replays, so MDW
  -- may run them on every mouse-move of a live drag: width-aware layouts
  -- (the Character grid) re-space live as the sidebar resizes, like the web.
  widget.liveReflow = true
end

---------------------------------------------------------------------------
-- COLUMN TABLES
-- The shared layout of the web client's table-style panels (keychain list
-- today, Character's rules and label gray always): a #888 header row over a
-- rule, fixed columns around one elastic column, an optional right-aligned
-- last column flush with the panel edge. A column spec is { width = n }
-- fixed or { stretch = true } elastic (exactly one per table; long text
-- clips with an ellipsis, the web's text-overflow), plus right = true to
-- right-align a fixed column.
---------------------------------------------------------------------------

--- Usable text width for width-aware renderers. MDW refreshes _wrapWidth
-- right before every reflow; GMCP-driven renders reuse the width of the
-- last layout pass. `floor` covers the first render and absurdly thin docks.
function mdwui.wrapWidth(widget, floor)
  return math.max(floor, widget._wrapWidth or 34)
end

--- Full-width rule in the shared divider color (.char-divider, and the
-- .key-header-row bottom border).
function mdwui.divider(co, W)
  co:decho(string.format("<%s>%s\n", mdwui.config.colors.charDivider, string.rep("─", W)))
end

--- Clip to `max` display cells, ellipsis-terminated (the web's
-- text-overflow). Returns the text plus its display width: the ellipsis is
-- multi-byte, so # cannot measure a clipped result (GMCP text is otherwise
-- ASCII, where # is the width).
function mdwui.clipText(text, max)
  if max < 1 then return "", 0 end
  if #text <= max then return text, #text end
  return text:sub(1, max - 1) .. "…", max
end
local clip = mdwui.clipText

--- Word-wrap `text` into chunks of at most `width` cells, with an optional
-- narrower `firstWidth` for the opening line (the "Label: value" rows, whose
-- first line also carries the label). A word longer than the column is hard
-- split rather than left to overflow.
--
-- Why wrap here rather than let the console do it: Mudlet CAN indent wrapped
-- lines console-wide - setWindowWrapIndent sets the first segment's indent,
-- setWindowWrapHangingIndent the continuation lines' - but each is ONE value
-- for the whole console, and these blocks nest (prose at one level, objectives
-- and rewards a level deeper, row headers flush). So the indent is applied per
-- line by the caller, where the level is known.
function mdwui.wrapText(text, width, firstWidth)
  width = math.max(8, width)
  firstWidth = math.max(4, firstWidth or width)
  local lines, current = {}, ""
  local function limit() return (#lines == 0) and firstWidth or width end
  for word in tostring(text):gmatch("%S+") do
    while #word > limit() do
      if current ~= "" then
        lines[#lines + 1] = current
        current = ""
      end
      lines[#lines + 1] = word:sub(1, limit())
      word = word:sub(limit() + 1)
    end
    if current == "" then
      current = word
    elseif #current + 1 + #word <= limit() then
      current = current .. " " .. word
    else
      lines[#lines + 1] = current
      current = word
    end
  end
  if current ~= "" then lines[#lines + 1] = current end
  if #lines == 0 then lines[1] = "" end
  return lines
end

--- Emit `text` at `pad`, wrapped so every continuation line keeps that indent.
-- `attr` is a decho attribute letter ("i" italics, "s" strikethrough - decho
-- parses b/i/r/u/s/o inline). It is applied PER CHUNK because every decho call
-- resets the format at both ends, so an attribute opened in one call never
-- reaches the next - and it is added after wrapping, so the tag characters
-- never count against the column width.
function mdwui.wrapEcho(co, W, color, text, pad, attr)
  local open = attr and ("<" .. attr .. ">") or ""
  local close = attr and ("</" .. attr .. ">") or ""
  for _, chunk in ipairs(mdwui.wrapText(text, W - #pad)) do
    co:decho(string.format("%s<%s>%s%s%s\n", pad, color, open, chunk, close))
  end
end

--- One table row. `cells` pairs each column spec with { text, color }.
-- Non-right cells keep one trailing space so neighbours never touch.
function mdwui.tableRow(co, W, cols, cells)
  local stretchW = W
  for _, col in ipairs(cols) do
    stretchW = stretchW - (col.width or 0)
  end
  local parts = {}
  for i, col in ipairs(cols) do
    local cell = cells[i]
    local width = col.width or math.max(2, stretchW)
    local text, tw = clip(tostring(cell[1] or ""), col.right and width or width - 1)
    local pad = string.rep(" ", width - tw)
    parts[#parts + 1] = col.right
      and string.format("<%s>%s%s", cell[2], pad, text)
      or string.format("<%s>%s%s", cell[2], text, pad)
  end
  co:decho(table.concat(parts) .. "\n")
end

--- Header labels in the shared label gray over a rule (.key-header-row).
function mdwui.tableHeader(co, W, cols, labels)
  local cells = {}
  for i = 1, #cols do
    cells[i] = { labels[i] or "", mdwui.config.colors.charLabel }
  end
  mdwui.tableRow(co, W, cols, cells)
  mdwui.divider(co, W)
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
  -- An open context menu holds closures into this package - close it with us.
  if mdw and mdw.closeAllMenus then mdw.closeAllMenus() end
  -- Withdraw the prompt-bar declarations, or MDW would rebuild our gauge
  -- row and settings button (both survive teardown by design) after we are
  -- gone. Widget rows and menus die with their widgets below. Settings stay
  -- in the layout file on purpose: a package UPDATE fires uninstall too.
  if mdw and mdw.setPromptGauges then mdw.setPromptGauges(nil) end
  if mdw and mdw.setPromptBarMenu then mdw.setPromptBarMenu(nil) end
  -- The top bar too. MDW's own ownership reap would get it, but only if its
  -- handler sees our mdw.gamePackages entry before we clear it below - the
  -- event handler order is not ours to rely on.
  if mdw and mdw.removeBar then mdw.removeBar("WillowdaleTop") end
  for name in pairs(mdwui.state.widgets) do
    local widget = mdw and mdw.widgets and mdw.widgets[name]
    if widget and widget.destroy then widget:destroy() end
  end
  mdwui.state.widgets = {}
  -- Withdraw every MDW registration, not just onReady: a dead onTeardown
  -- closure or a stale co-removal entry would outlive us in MDW's registries.
  -- A package UPDATE fires uninstall too - the reinstall re-seeds all three.
  if mdw and mdw.onReady then
    mdw.onReady[mdwui.packageName] = nil
  end
  if mdw and mdw.onTeardown then
    mdw.onTeardown[mdwui.packageName] = nil
  end
  if mdw and mdw.gamePackages then
    mdw.gamePackages[mdwui.packageName] = nil
  end
end
