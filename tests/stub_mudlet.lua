-- Stubbed Mudlet API, just deep enough to load MDW and MDW_UI and drive their
-- flows headlessly under plain Lua 5.1. Returns a harness table with the
-- captured side effects (sent commands, GMCP requests, timers, callbacks).

local WIN_W, WIN_H = 1600, 900
local H = {
  callbacks = {}, handlers = {}, timers = {}, labels = {},
  sent = {}, gmcpSent = {}, nextTimerId = 0,
  winW = WIN_W, winH = WIN_H,
  -- The MAIN console: where `ui` (and MDW's own notices) talk to the player.
  main = { _echoed = {}, _links = {} },
  scrolls = {}, -- { fn, window, arg } per scroll call
}

local function resolveDim(v, total)
  if type(v) == "string" then
    local pct = v:match("(%d+)%%")
    if pct then return tonumber(pct) / 100 * total end
    return tonumber(v) or 0
  end
  return v or 0
end

-- Shared stub element -------------------------------------------------------
local Element = {}
Element.__index = Element
local function newElement(props, container)
  local self = setmetatable({}, Element)
  self.name = props.name
  self._x = props.x or 0
  self._y = props.y or 0
  self._w = resolveDim(props.width, WIN_W)
  self._h = resolveDim(props.height, WIN_H)
  -- Geyser visibility model (GeyserContainer.lua): `hidden` is the explicit
  -- flag, `auto_hidden` the cascaded one; children live in windowList. A NEW
  -- element starts shown even inside a hidden container - Mudlet's default
  -- add path skips add2's hidden-state inheritance, the gotcha MDW's widget
  -- row block compensates for (rows built behind another stack tab).
  self._shown = true
  self.hidden = false
  self.auto_hidden = false
  self.windowList = {}
  if container then
    self.container = container
    container.windowList[self] = self
  end
  self._echoed = {}
  self._links = {}
  if self.name then H.labels[self.name] = self end
  return self
end
function Element:get_x() return self._x < 0 and WIN_W + self._x or self._x end
function Element:get_y() return self._y < 0 and WIN_H + self._y or self._y end
function Element:get_width() return self._w end
function Element:get_height() return self._h end
function Element:move(x, y)
  if x then self._x = x end
  if y then self._y = y end
end
function Element:resize(w, h)
  if w then self._w = resolveDim(w, WIN_W) end
  if h then self._h = resolveDim(h, WIN_H) end
end
-- Real Geyser semantics: hide cascades hide(true) to children; show respects
-- a hidden parent (even an explicit show cannot reveal a child while its
-- container is hidden) and cascades show(true), which clears only the auto
-- flag - so explicitly hidden children stay hidden through it.
function Element:show(auto)
  local parent = self.container
  if parent and (parent.hidden or parent.auto_hidden) then
    if not auto then self.hidden = false end
    return false
  end
  if auto then self.auto_hidden = false else self.hidden = false end
  if not self.hidden and not self.auto_hidden then
    self._shown = true
  end
  for _, v in pairs(self.windowList) do v:show(true) end
end
function Element:hide(auto)
  if auto then self.auto_hidden = true else self.hidden = true end
  self._shown = false
  for _, v in pairs(self.windowList) do v:hide(true) end
end
function Element:raise() end
function Element:setStyleSheet(css) self._css = css end
function Element:setFontSize() end
function Element:setFont() end
function Element:setAlignment(a) self._align = a end
function Element:setColor() end
function Element:setWrap(w) self._wrap = w end
function Element:setCursor() end
function Element:setToolTip() end
function Element:setBackgroundImage() end
function Element:setClickCallback(cb) self._click = cb end
function Element:echo(t) self._echoed[#self._echoed + 1] = t end
Element.cecho, Element.decho, Element.hecho = Element.echo, Element.echo, Element.echo
function Element:clear()
  self._echoed = {}
  self._links = {}
  self._clears = (self._clears or 0) + 1
end
-- Mudlet 4.20+ real deletion (Geyser :delete()); MDW's deleteElement prefers
-- it and only falls back to hide+deleteLabel on older Mudlet.
function Element:delete()
  if self.name then H.labels[self.name] = nil end
  if self.container then self.container.windowList[self] = nil end
  self._shown = false
  self._deleted = true
end
local function recordLink(self, text, cb, hint)
  self._echoed[#self._echoed + 1] = text
  self._links[#self._links + 1] = { text = text, cb = cb, hint = hint }
end
Element.echoLink, Element.cechoLink, Element.dechoLink, Element.hechoLink =
  recordLink, recordLink, recordLink, recordLink

Geyser = {}
Geyser.Label = { setSvgTint = nil }
function Geyser.Label:new(props, container) return newElement(props, container) end
Geyser.Container = {}
function Geyser.Container:new(props, container) return newElement(props, container) end
Geyser.MiniConsole = {}
function Geyser.MiniConsole:new(props, container) return newElement(props, container) end
Geyser.Mapper = {}
function Geyser.Mapper:new(props, container) return newElement(props, container) end
-- Compound like the real thing: three named labels (MDW tracks those,
-- parented to the gauge so hide/show cascades reach them), plus the slice of
-- the Gauge API the prompt-gauge row uses. setValue mirrors Geyser's refusal
-- of a non-positive max; text echo REPLACES (labels are not consoles).
Geyser.Gauge = {}
function Geyser.Gauge:new(props, container)
  local g = newElement(props, container)
  H.labels[props.name] = nil -- a Geyser container is no Qt label
  g.back = newElement({ name = props.name .. "_back" }, g)
  g.front = newElement({ name = props.name .. "_front" }, g)
  g.text = newElement({ name = props.name .. "_text" }, g)
  function g.setValue(gauge, cur, max, text)
    if max ~= nil and max <= 0 then return nil end
    gauge._value, gauge._max = cur, max
    if text then gauge.text._echoed = { text } end
    return true
  end
  function g.setStyleSheet(gauge, css, cssback, cssText)
    gauge.frontCSS, gauge.backCSS = css, cssback or css
    gauge.front:setStyleSheet(gauge.frontCSS)
    gauge.back:setStyleSheet(gauge.backCSS)
    if cssText ~= nil then
      gauge.textCSS = cssText
      gauge.text:setStyleSheet(cssText)
    end
  end
  function g.setAlignment() end
  function g.setFontSize() end
  function g.setFgColor() end
  return g
end

-- Global Mudlet API ---------------------------------------------------------
-- Qt cursor shapes (KeyCodes.lua), read by MDW's drag handles and buttons.
mudlet = {
  cursor = { Arrow = 0, OpenHand = 1, ClosedHand = 2, PointingHand = 3,
    ResizeHorizontal = 4, ResizeVertical = 5 },
}
function getMainWindowSize() return WIN_W, WIN_H end
function getMousePosition() return 444, 333 end
function getMudletHomeDir() return H.homeDir end
function calcFontSize(size) return size * 0.6, size * 1.2 end
function getFontSize() return 11 end
function setFontSize() end
function getAvailableFonts() return { ["JetBrains Mono NL"] = true, ["Bitstream Vera Sans Mono"] = true } end
function setBorderLeft() end
function setBorderRight() end
function setBorderTop() end
function setBorderBottom() end
function setBackgroundColor() end
function setBgColor() end
function setFgColor() end
function deleteLabel(name) H.labels[name] = nil end
function enableClickthrough() end
function enableTrigger() end
function disableTrigger() end
-- echo/cecho/decho: one arg is the main console, two is a named window.
-- Capturing rather than dropping, so main-console output (MDW's notices, the
-- whole `ui` command surface) can be asserted on.
local function windowEcho(a, b)
  local target = b and H.labels[a] or H.main
  local text = b or a
  if target then target._echoed[#target._echoed + 1] = tostring(text) end
end
echo, cecho, decho, hecho = windowEcho, windowEcho, windowEcho, windowEcho
-- dechoLink(text, code, hint, useCurrentFormat) on the main console: the link
-- callback is what an overview link runs when the player clicks it.
local function mainLink(text, cb, hint)
  H.main._echoed[#H.main._echoed + 1] = tostring(text)
  H.main._links[#H.main._links + 1] = { text = tostring(text), cb = cb, hint = hint }
end
echoLink, cechoLink, dechoLink, hechoLink = mainLink, mainLink, mainLink, mainLink
function debugc() end
-- Per-window scrolling (Mudlet 4.17+). Recorded rather than simulated: what
-- matters is that the right console name and line count went out.
local function recordScroll(fn)
  return function(window, arg)
    H.scrolls[#H.scrolls + 1] = { fn = fn, window = window, arg = arg }
  end
end
scrollUp = recordScroll("scrollUp")
scrollDown = recordScroll("scrollDown")
scrollTo = recordScroll("scrollTo")
function getScroll(window)
  H.scrolls[#H.scrolls + 1] = { fn = "getScroll", window = window }
  return 0
end
function send(cmd) H.sent[#H.sent + 1] = cmd end
function sendGMCP(pkg, payload) H.gmcpSent[#H.gmcpSent + 1] = pkg .. " " .. (payload or "") end
function ansi2decho(s) return s end

-- Mudlet's JSON decoder (LuaGlobal.lua aliases yajl.to_value). Enough of a
-- parser to decode the book documents Char.Journal.Entry carries: objects,
-- arrays, strings with escapes, numbers, booleans and null.
function json_to_value(text)
  local pos = 1
  local parseValue
  local function skipSpace()
    local _, stop = text:find("^[ \t\r\n]*", pos)
    pos = stop + 1
  end
  local function parseString()
    pos = pos + 1 -- opening quote
    local out = {}
    while pos <= #text do
      local c = text:sub(pos, pos)
      if c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == "\\" then
        local esc = text:sub(pos + 1, pos + 1)
        local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
          ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
        if esc == "u" then
          out[#out + 1] = "?" -- the harness never feeds \u escapes
          pos = pos + 6
        else
          out[#out + 1] = map[esc] or esc
          pos = pos + 2
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    error("unterminated string in JSON")
  end
  parseValue = function()
    skipSpace()
    local c = text:sub(pos, pos)
    if c == '"' then return parseString() end
    if c == "{" then
      local obj = {}
      pos = pos + 1
      skipSpace()
      if text:sub(pos, pos) == "}" then pos = pos + 1 return obj end
      while true do
        skipSpace()
        local key = parseString()
        skipSpace()
        pos = pos + 1 -- colon
        obj[key] = parseValue()
        skipSpace()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == "}" then return obj end
      end
    end
    if c == "[" then
      local arr = {}
      pos = pos + 1
      skipSpace()
      if text:sub(pos, pos) == "]" then pos = pos + 1 return arr end
      while true do
        arr[#arr + 1] = parseValue()
        skipSpace()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == "]" then return arr end
      end
    end
    local literal, stop = text:match("^([%w%.%+%-]+)()", pos)
    if not literal then error("bad JSON at position " .. pos) end
    pos = stop
    if literal == "true" then return true end
    if literal == "false" then return false end
    if literal == "null" then return nil end
    return tonumber(literal)
  end
  return parseValue()
end
function raiseEvent(event, ...)
  -- Snapshot: handlers may deregister themselves mid-dispatch (uninstall
  -- does), and real Mudlet dispatches over a copy.
  local snapshot = {}
  for k, v in pairs(H.handlers[event] or {}) do snapshot[k] = v end
  for _, fn in pairs(snapshot) do
    local f = fn
    if type(f) == "string" then -- resolve "mdw.onInstall" style names
      f = _G
      for part in fn:gmatch("[^%.]+") do f = f[part] end
    end
    f(event, ...)
  end
end
function registerNamedEventHandler(user, name, event, fn)
  H.handlers[event] = H.handlers[event] or {}
  H.handlers[event][name] = fn
end
function deleteNamedEventHandler(user, name)
  for _, tbl in pairs(H.handlers) do tbl[name] = nil end
end
function tempTimer(t, fn, _repeating)
  H.nextTimerId = H.nextTimerId + 1
  H.timers[H.nextTimerId] = fn
  return H.nextTimerId
end
function killTimer(id) H.timers[id] = nil return true end
-- Native key items (a package's src/keys, installed by Mudlet under a folder
-- named after the package). enableKey/disableKey act by NAME on any item,
-- folders included - TKey::match is gated on isActive, so a disabled folder
-- silences everything inside. The harness seeds the names it "installed";
-- an unknown name returns false, as Mudlet's KeyUnit does.
H.nativeKeys = {} -- name -> active
function enableKey(name)
  if H.nativeKeys[name] == nil then return false end
  H.nativeKeys[name] = true
  return true
end
function disableKey(name)
  if H.nativeKeys[name] == nil then return false end
  H.nativeKeys[name] = false
  return true
end
-- Package/module plumbing and the downloader (the self-updater's world).
-- Downloads are RECORDED, never performed, and installPackage does not raise
-- sysInstallPackage: the suite writes the file it wants and raises the events
-- itself, which is the only way to drive a verify-then-swap flow (and its
-- watchdog) deterministically. uninstallPackage keeps raising, because our
-- own cleanup runs inside that call in real Mudlet too.
H.downloads = {}    -- { path, url } per downloadFile call
H.installed = {}    -- paths passed to installPackage
H.uninstalled = {}  -- package names passed to uninstallPackage
H.reloaded = {}     -- package names passed to reloadModule
H.modulePaths = {}  -- package name -> module file, when installed as a module
H.packages = {}     -- installed package names, as getPackages reports them
function downloadFile(path, url)
  H.downloads[#H.downloads + 1] = { path = path, url = url }
  return true
end
function installPackage(path)
  H.installed[#H.installed + 1] = path
  return true
end
function getPackages()
  local out = {}
  for i, name in ipairs(H.packages) do out[i] = name end
  return out
end
function getModulePath(name) return H.modulePaths[name] end
function reloadModule(name) H.reloaded[#H.reloaded + 1] = name return true end
function uninstallPackage(name)
  H.uninstalled[#H.uninstalled + 1] = name
  raiseEvent("sysUninstallPackage", name)
end
local function cbSet(kind)
  return function(name, fn)
    H.callbacks[name] = H.callbacks[name] or {}
    H.callbacks[name][kind] = fn
  end
end
setLabelClickCallback = cbSet("click")
setLabelMoveCallback = cbSet("move")
setLabelReleaseCallback = cbSet("release")
setLabelOnEnter = cbSet("enter")
setLabelOnLeave = cbSet("leave")

-- prompt-capture surface (unused here, but MDW references it)
function getLineNumber() return 1 end
--- A console's text as plain lines: what `ui read` prints and what MDW's
-- widgetText reads. Colour tags come off, since Mudlet's getLines is plain
-- text too. An unknown window keeps the old one-empty-line answer, which the
-- prompt-capture path relies on.
local function windowLines(window)
  local element = window and H.labels[window]
  if not element then return { "" } end
  local text = table.concat(element._echoed):gsub("<[^>]*>", "")
  if text:sub(-1) ~= "\n" then text = text .. "\n" end
  local lines = {}
  for chunk in text:gmatch("([^\n]*)\n") do lines[#lines + 1] = chunk end
  return lines
end
function getLineCount(window) return #windowLines(window) end
--- Mudlet's line numbers are absolute and 0-based.
function getLines(window, from, to)
  local lines = windowLines(window)
  if not from then return lines end
  local out = {}
  for i = math.max(1, (tonumber(from) or 0) + 1), math.min(#lines, (tonumber(to) or #lines) + 1) do
    out[#out + 1] = lines[i]
  end
  return out
end
function selectCurrentLine() end
function deselect() end
function deleteLine() end
function moveCursor() end
function moveCursorEnd() end
function copy2decho() return "<255,255,255:0,0,0>stub" end

-- io.exists + table.contains + table.save/load (Mudlet extensions) -----------
-- table.contains recurses into nested tables, as Mudlet's TableUtils.lua does;
-- the bootstrap asks it whether MDW is among getPackages() before uninstalling.
table.contains = function(t, value)
  for _, v in pairs(t) do
    if v == value then return true end
    if type(v) == "table" and table.contains(v, value) then return true end
  end
  return false
end
io.exists = function(p)
  local f = io.open(p)
  if f then f:close() return true end
  return false
end
local function ser(v)
  if type(v) == "table" then
    local parts = {}
    for k, val in pairs(v) do
      local key = type(k) == "string" and string.format("[%q]", k) or ("[" .. tostring(k) .. "]")
      parts[#parts + 1] = key .. "=" .. ser(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif type(v) == "string" then
    return string.format("%q", v)
  end
  return tostring(v)
end
table.save = function(file, tbl)
  local f = assert(io.open(file, "w"))
  f:write("return " .. ser(tbl))
  f:close()
end
table.load = function(file, tbl)
  local t = assert(loadfile(file))()
  for k, v in pairs(t) do tbl[k] = v end
end

-- Harness helpers -----------------------------------------------------------
function H.flushTimers()
  local pending = H.timers
  H.timers = {}
  local ids = {}
  for id in pairs(pending) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do pending[id]() end
end

return H
