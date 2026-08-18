--[[
  MDWUI_Init.lua
  Builds the widget layout and wires the GMCP event handlers.

  Layout mirrors the web client's default (dockview-widgets.js, layout v3):

    Left dock                      Right dock
      [Affects | Keyring]            [Map]  (native Mudlet mapper)
      [Equipment | Inventory |       [Comm | Quests | Journal]
       Forage]
      [Character | Combat | Group]

  The default grouping only applies on a first run: once the player has a
  saved MDW layout, every widget is claimed by a saved group (via
  _pendingStackId) and placement belongs entirely to MDW's restore.

  Dependencies: all other MDWUI_* scripts.
]]

---------------------------------------------------------------------------
-- LAYOUT
---------------------------------------------------------------------------

--- Group freshly created widgets into a named stack, unless a saved layout
-- already owns any of them. Returns silently in that case - the player's
-- arrangement always beats our default.
local function defaultGroup(names, stackName, dock, height)
  for _, name in ipairs(names) do
    local widget = mdw.widgets[name]
    if not widget or widget._pendingStackId then return end
  end
  local stack = mdw.groupWidgetsIntoStack(names, { dock = dock, name = stackName })
  if stack and height then
    mdw.resizeWidgetClass(stack, nil, height)
  end
end

--- Repaint every surface from whatever the gmcp table already holds. Used at
-- build time (data may predate the UI - e.g. an MDW update mid-session) and
-- harmless when the table is still empty.
function mdwui.renderAll()
  mdwui.renderCharacter()
  mdwui.renderAffects()
  mdwui.renderGroup()
  mdwui.renderEquipment()
  mdwui.renderInventory()
  mdwui.renderKeyring()
  mdwui.renderForage()
  mdwui.renderCombat()
  mdwui.renderQuests()
  mdwui.renderJournal()
  mdwui.updatePromptBar()
  mdwui.onCommHistory()
end

--- Create the full widget set. Runs on every MDW setup (registered in
-- MDWUI_Config via mdw.onReady), so it must be idempotent: Widget:new
-- returns existing widgets, defaultGroup respects saved layouts, and the
-- ticker replaces itself.
function mdwui.buildUI()
  mdwui.killAllTimers()

  local defs = {
    -- name, renderer, constructor options (creation order = default row order)
    { "Affects", mdwui.renderAffects, { dock = "left" } },
    { "Keyring", mdwui.renderKeyring, { dock = "left" } },
    { "Equipment", mdwui.renderEquipment, { dock = "left" } },
    { "Inventory", mdwui.renderInventory, { dock = "left" } },
    { "Forage", mdwui.renderForage, { dock = "left" } },
    { "Character", mdwui.renderCharacter, { dock = "left" } },
    { "Combat", mdwui.renderCombat, { dock = "left" } },
    { "Group", mdwui.renderGroup, { dock = "left" } },
    { "Map", nil, { dock = "right" } },
    { "Quests", mdwui.renderQuests, { dock = "right" } },
    { "Journal", mdwui.renderJournal, { dock = "right" } },
  }
  for _, def in ipairs(defs) do
    local widget = mdw.Widget:new({ name = def[1], title = def[1], dock = def[3].dock })
    mdwui.state.widgets[def[1]] = true
    if def[2] then
      mdwui.bindRenderer(widget, def[2])
    end
  end
  mdw.widgets["Map"]:embedMapper()

  -- Comm is a TabbedWidget: channel tabs with "All" mirroring every message.
  mdw.TabbedWidget:new({
    name = "Comm",
    title = "Communications",
    tabs = mdwui.config.commTabs,
    allTab = "All",
    activeTab = "All",
    dock = "right",
  })
  mdwui.state.widgets["Comm"] = true

  -- Default grouping (first run only - see defaultGroup). Order builds the
  -- left dock top-to-bottom; the last group in each dock auto-fills.
  defaultGroup({ "Affects", "Keyring" }, "MDWUI_Status", "left", 180)
  defaultGroup({ "Equipment", "Inventory", "Forage" }, "MDWUI_Items", "left", 320)
  defaultGroup({ "Character", "Combat", "Group" }, "MDWUI_Char", "left")
  defaultGroup({ "Comm", "Quests", "Journal" }, "MDWUI_Comms", "right")
  local map = mdw.widgets["Map"]
  if map and not map._pendingStackId and map.stackId then
    mdw.resizeWidgetClass(mdw.widgets[map.stackId], nil, 380)
  end

  -- Paint from cached data, then ask the server for everything fresh. The
  -- full payload includes Comm.History (guide 8.22); Client.Map wakes the
  -- native mapper feed - never a Map.Nearby reimplementation (guide 5.12).
  mdwui.renderAll()
  mdwui.requestFullPayload()
  mdwui.request("Client.Map")

  -- Affects countdowns are driven locally (no per-second push from the
  -- server), so a 1s ticker repaints the panel while durations run down.
  local tid = tempTimer(1, function() mdwui.renderAffects() end, true)
  if tid then mdwui.addTimer(tid) end
end

---------------------------------------------------------------------------
-- EVENT WIRING
-- One table, one registration loop. Named handlers, so re-running this
-- script replaces rather than duplicates, and uninstall can remove them all.
---------------------------------------------------------------------------

local handlers = {
  -- Character panel aggregates four packages plus the time line.
  ["gmcp.Char.Info"] = function() mdwui.renderCharacter() end,
  ["gmcp.Char.Attributes"] = function() mdwui.renderCharacter() end,
  ["gmcp.Char.Worth"] = function() mdwui.renderCharacter() end,
  ["gmcp.Game.Clock"] = function() mdwui.renderCharacter() end,
  ["gmcp.Game.Calendar"] = function() mdwui.renderCharacter() end,

  ["gmcp.Char.Vitals"] = function() mdwui.onVitals() end,
  ["gmcp.Char.Balance"] = function() mdwui.renderCombat() end,
  ["gmcp.Char.Combat.Enemies"] = function() mdwui.onCombatEnemies() end,
  ["gmcp.Char.Combat.Status"] = function() mdwui.onCombatStatus() end,
  ["gmcp.Char.Combat.Ended"] = function() mdwui.setInCombat(false) end,
  ["gmcp.Char.Combat.Target"] = function()
    local target = (gmcp.Char and gmcp.Char.Combat and gmcp.Char.Combat.Target) or {}
    if target.name and target.name ~= "" then mdwui.state.inCombat = true end
    mdwui.renderCombat()
  end,

  ["gmcp.Char.Affects"] = function()
    -- Anchor the local countdown to arrival time (guide 8.5).
    mdwui.state.affectsReceivedAt = os.time()
    mdwui.renderAffects()
  end,

  ["gmcp.Char.Inventory.Worn"] = function() mdwui.renderEquipment() end,
  ["gmcp.Char.Inventory.Backpack.Items"] = function() mdwui.renderInventory() end,
  ["gmcp.Char.Inventory.Backpack.Summary"] = function() mdwui.renderInventory() end,
  ["gmcp.Char.Inventory.Keyring"] = function() mdwui.renderKeyring() end,
  ["gmcp.Char.Inventory.Ingredients"] = function() mdwui.renderForage() end,

  ["gmcp.Group.Info"] = function() mdwui.renderGroup() end,
  ["gmcp.Group.Vitals"] = function() mdwui.renderGroup() end,

  ["gmcp.Char.Quests"] = function() mdwui.onQuests() end,
  ["gmcp.Char.Quest.Detail"] = function() mdwui.onQuestDetail() end,

  ["gmcp.Comm.Channel"] = function() mdwui.onCommChannel() end,
  ["gmcp.Comm.History"] = function() mdwui.onCommHistory() end,

  -- Server hot-reload: cached state may be stale - re-request everything
  -- (guide 8.15).
  ["gmcp.Engine.Copyover"] = function() mdwui.requestFullPayload() end,

  ["sysUninstallPackage"] = function(event, package) mdwui.onUninstall(event, package) end,
}

for event, fn in pairs(handlers) do
  mdwui.registerHandler(event, fn)
end

-- Late-join (MDW contract): if MDW is already running - this package was just
-- installed or its scripts re-ran - build now instead of waiting for the next
-- profile load. MDW also re-runs the registration on every future setup.
if mdw.isSetUp and mdw.runReadyCallbacks then
  mdw.runReadyCallbacks(mdwui.packageName)
end
