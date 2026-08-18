-- Stubbed Mudlet API, just deep enough to load MDW and MDW_UI and drive their
-- flows headlessly under plain Lua 5.1. Returns a harness table with the
-- captured side effects (sent commands, GMCP requests, timers, callbacks).

local WIN_W, WIN_H = 1600, 900
local H = {
  callbacks = {}, handlers = {}, timers = {}, labels = {},
  sent = {}, gmcpSent = {}, nextTimerId = 0,
  winW = WIN_W, winH = WIN_H,
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
local function newElement(props)
  local self = setmetatable({}, Element)
  self.name = props.name
  self._x = props.x or 0
  self._y = props.y or 0
  self._w = resolveDim(props.width, WIN_W)
  self._h = resolveDim(props.height, WIN_H)
  self._shown = true
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
function Element:show() self._shown = true end
function Element:hide() self._shown = false end
function Element:raise() end
function Element:setStyleSheet(css) self._css = css end
function Element:setFontSize() end
function Element:setFont() end
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
local function recordLink(self, text, cb, hint)
  self._echoed[#self._echoed + 1] = text
  self._links[#self._links + 1] = { text = text, cb = cb, hint = hint }
end
Element.echoLink, Element.cechoLink, Element.dechoLink, Element.hechoLink =
  recordLink, recordLink, recordLink, recordLink

Geyser = {}
Geyser.Label = { setSvgTint = nil }
function Geyser.Label:new(props) return newElement(props) end
Geyser.Container = {}
function Geyser.Container:new(props) return newElement(props) end
Geyser.MiniConsole = {}
function Geyser.MiniConsole:new(props) return newElement(props) end
Geyser.Mapper = {}
function Geyser.Mapper:new(props) return newElement(props) end

-- Global Mudlet API ---------------------------------------------------------
mudlet = { cursor = { Arrow = 0, OpenHand = 1, ClosedHand = 2, PointingHand = 3,
  ResizeHorizontal = 4, ResizeVertical = 5 } }
function getMainWindowSize() return WIN_W, WIN_H end
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
function cecho() end
function decho() end
function debugc() end
function send(cmd) H.sent[#H.sent + 1] = cmd end
function sendGMCP(pkg, payload) H.gmcpSent[#H.gmcpSent + 1] = pkg .. " " .. (payload or "") end
function ansi2decho(s) return s end
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
function uninstallPackage(name) raiseEvent("sysUninstallPackage", name) end
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
function getLines() return { "" } end
function selectCurrentLine() end
function deselect() end
function deleteLine() end
function moveCursor() end
function moveCursorEnd() end
function copy2decho() return "<255,255,255:0,0,0>stub" end

-- io.exists + table.save/load (Mudlet extensions) ----------------------------
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
