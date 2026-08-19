-- MDW_UI smoke suite: loads MDW (sibling checkout or $MDW_SRC) and this
-- package against the stubbed Mudlet API, then drives the layout build and
-- every GMCP-fed surface with fixture payloads. Run from the repo root:
--   lua5.1 tests/smoke.lua

package.path = "tests/?.lua;" .. package.path
local H = require("stub_mudlet")
H.homeDir = os.getenv("TMPDIR") or "/tmp"

local MDW_SRC = os.getenv("MDW_SRC") or "../mdw/src/scripts/"
local MDW_ORDER = { "MDW_Config", "MDW_Helpers", "MDW_Init", "MDW_WidgetCore",
  "MDW_DockLayout", "MDW_Widget", "MDW_TabbedWidget", "MDW_Stack", "MDW_Menus" }
local UI_ORDER = { "MDWUI_Config", "MDWUI_Core", "MDWUI_Panels", "MDWUI_Combat",
  "MDWUI_Comm", "MDWUI_Quests", "MDWUI_Init" }

os.remove(H.homeDir .. "/mdw_layout.lua")

local function check(cond, msg)
  if cond then print("ok   - " .. msg) else error("FAIL - " .. msg, 2) end
end
local function joined(widgetOrConsole)
  local console = widgetOrConsole.content or widgetOrConsole
  return table.concat(console._echoed)
end
local function findLink(console, pattern)
  for _, link in ipairs(console._links) do
    if link.text:find(pattern) then return link end
  end
  return nil
end

-- 1. Load MDW first, then MDW_UI (the reverse order is exercised implicitly:
-- MDWUI_Config seeds `mdw = mdw or {}` tables that MDW must preserve).
for _, name in ipairs(MDW_ORDER) do
  assert(pcall(dofile, MDW_SRC .. name .. ".lua"), "failed loading " .. name)
end
for _, name in ipairs(UI_ORDER) do
  assert(pcall(dofile, "src/scripts/" .. name .. ".lua"), "failed loading " .. name)
end

raiseEvent("sysLoadEvent")
H.flushTimers()
check(mdw.isSetUp, "MDW setup completes with MDW_UI registered")
check(mdw.widgets["Items"] == nil, "MDW examples suppressed by loadExamples seed")
check(mdw.config.usePromptTrigger == false, "gameConfig seed disabled the prompt trigger")

-- 2. Layout: every widget exists and the default groups match the web client
for _, name in ipairs({ "Affects", "Keyring", "Equipment", "Inventory", "Forage",
  "Character", "Combat", "Group", "Map", "Comm", "Quests", "Journal" }) do
  check(mdw.widgets[name] ~= nil, "widget " .. name .. " created")
end
check(mdw.widgets["Affects"].stackId == "MDWUI_Status"
  and mdw.widgets["Keyring"].stackId == "MDWUI_Status", "Affects|Keyring grouped")
check(mdw.widgets["Equipment"].stackId == "MDWUI_Items"
  and mdw.widgets["Inventory"].stackId == "MDWUI_Items"
  and mdw.widgets["Forage"].stackId == "MDWUI_Items", "Equipment|Inventory|Forage grouped")
check(mdw.widgets["Character"].stackId == "MDWUI_Char"
  and mdw.widgets["Combat"].stackId == "MDWUI_Char"
  and mdw.widgets["Group"].stackId == "MDWUI_Char", "Character|Combat|Group grouped")
check(mdw.widgets["Comm"].stackId == "MDWUI_Comms"
  and mdw.widgets["Quests"].stackId == "MDWUI_Comms"
  and mdw.widgets["Journal"].stackId == "MDWUI_Comms", "Comm|Quests|Journal grouped")
check(mdw.widgets["MDWUI_Char"].docked == "left"
  and mdw.widgets["MDWUI_Comms"].docked == "right", "groups docked to the web-client sides")
check(mdw.widgets["Map"].mapper ~= nil, "Map embeds the native mapper")

-- 3. Startup requests: full payload + native map feed
local requests = table.concat(H.gmcpSent, "|")
check(requests:find('GMCP "SendFullPayload"', 1, true) ~= nil, "full payload requested at build")
check(requests:find("Client.Map", 1, true) ~= nil, "native mapper feed requested")

-- 4. GMCP fixtures (field names per the Widget GMCP Guide)
gmcp = {
  Char = {
    Info = { name = "Morquin", class = "Ranger", race = "Human", level = 12, role = "user" },
    Vitals = { health = 80, health_max = 120, aether = 45, aether_max = 60,
      prompt = "HP:80 AE:45>", prompt2 = "carrying 4/20" },
    Attributes = { body = 10, mind = 8, spirit = 6, armor_rating = 12, evasion_chance = 15,
      warding_rating = 3, spirit_resilience = 4, martial_power = 18, aether_power = 9, state_potency = 2 },
    Worth = { gold_carried = 1234, gold_bank = 56789, stat_points = 1, training_points = 2,
      xp_total = 45000, xp_current = 500, xp_tnl = 1500 },
    Affects = {
      Sanctuary = { name = "Sanctuary", duration_max = 300, duration_current = 120, type = "buff" },
      Regen = { name = "Regen", duration_max = -1, duration_current = -1, type = "buff" },
    },
    Inventory = {
      Worn = { weapon = { id = "!20:aa", name = "iron sword", details = { "enchanted" }, command = "wield" } },
      Backpack = {
        Items = { { id = "!21:bb", name = "red potion", quantity = 3, details = {}, command = "quaff" } },
        Summary = { count = 4, max = 20 },
      },
      Keyring = {
        { type = "Key", where = "Willowdale Gate", sequence = "" },
        { type = "Lockpick", where = "a worn kit", sequence = "1-3-2" },
      },
      Ingredients = { items = { { id = "!22:cc", name = "moss", quantity = 2 } }, count = 2, max = 30 },
    },
    Combat = {
      Enemies = { { id = 5, name = "a goblin", is_primary = true, health = 30, health_max = 40 },
                  { id = 6, name = "a wolf", health = 10, health_max = 25 } },
      Target = { id = 5, name = "a goblin", hp_current = 30, hp_max = 40 },
      Status = { in_combat = true, in_melee = true, combat_action = "" },
    },
    Balance = { balance = 2, max_balance = 4, seconds = "1.5", is_balanced = false },
    Quests = {
      active = { { id = 8, name = "Wolves at the Gate", category = "hunt", completion = 40,
        step_description = "Slay the wolves", tracked = true, ready = false } },
      completed = { { id = 2, name = "First Steps", count = 3 } },
      rumors = { { text = "Something stirs below", source_text = "a farmer", zone = "Fields" } },
    },
    Quest = {},
  },
  Group = {
    Info = { leaderid = "p1", members = { { id = "p1", name = "Morquin" }, { id = "p2", name = "Aria" } } },
    Vitals = { { name = "Aria", health = 50, health_max = 80 } },
  },
  Comm = {},
  Game = { Clock = { time = "12:34:56" }, Calendar = { phase = "day", day_name = "Mireday" } },
}

raiseEvent("gmcp.Char.Info")
raiseEvent("gmcp.Char.Attributes")
raiseEvent("gmcp.Char.Worth")
raiseEvent("gmcp.Char.Vitals")
local charText = joined(mdw.widgets["Character"])
check(charText:find("Morquin") and charText:find("Ranger"), "Character panel shows identity")
check(charText:find("1,234"), "numbers are thousands-grouped")
check(joined(mdw.promptBar):find("HP:80 AE:45>", 1, true) ~= nil, "GMCP prompt drives the prompt bar")

raiseEvent("gmcp.Char.Affects")
local affText = joined(mdw.widgets["Affects"])
check(affText:find("Sanctuary") and affText:find("2:00"), "affects show with countdown")
check(affText:find("Regen") and affText:find("perm"), "permanent affects marked")

raiseEvent("gmcp.Char.Inventory.Worn")
local eq = mdw.widgets["Equipment"]
check(joined(eq):find("iron sword") and joined(eq):find("enchanted"), "equipment shows item and badge")
check(findLink(eq.content, "%[x%]") ~= nil, "equipment has a remove link")
findLink(eq.content, "%[x%]").cb()
check(H.sent[#H.sent] == "remove weapon", "remove link sends the slot command")

raiseEvent("gmcp.Char.Inventory.Backpack.Items")
local inv = mdw.widgets["Inventory"]
check(joined(inv):find("red potion") and joined(inv):find("x3"), "inventory shows item and quantity")
check(joined(inv):find("4/20"), "inventory footer shows carry summary")
findLink(inv.content, "quaff").cb()
check(H.sent[#H.sent] == "quaff !21:bb", "item's own verb sends with its id")

raiseEvent("gmcp.Char.Inventory.Keyring")
check(joined(mdw.widgets["Keyring"]):find("1%-3%-2"), "lockpick sequence rendered")
raiseEvent("gmcp.Char.Inventory.Ingredients")
check(joined(mdw.widgets["Forage"]):find("moss"), "forage shows ingredients")

raiseEvent("gmcp.Group.Info")
local groupText = joined(mdw.widgets["Group"])
check(groupText:find("Morquin") and groupText:find("leader"), "group shows the named leader")
check(groupText:find("Aria") and groupText:find("50/80"), "group shows member vitals")

-- 5. Combat: gauges, target link, auto-target, and both end signals
raiseEvent("gmcp.Char.Combat.Status")
raiseEvent("gmcp.Char.Combat.Enemies")
raiseEvent("gmcp.Char.Combat.Target")
local combat = mdw.widgets["Combat"]
local combatText = joined(combat)
check(combatText:find("a goblin") and combatText:find("a wolf"), "enemy list rendered")
check(combatText:find("engaged"), "melee status text follows the web-client rule")
check(combatText:find("%(T%)"), "target marker painted from Target.id")
findLink(combat.content, "a wolf").cb()
check(H.sent[#H.sent] == "target #6", "clicking an enemy targets it with the # prefix")

-- Auto-target: current target (5) leaves the list, wolf (6) remains
gmcp.Char.Combat.Enemies = { { id = 6, name = "a wolf", health = 10, health_max = 25 } }
raiseEvent("gmcp.Char.Combat.Enemies")
check(H.sent[#H.sent] == "target #6", "auto-target re-targets the surviving enemy")

gmcp.Char.Combat.Status = { in_combat = false }
raiseEvent("gmcp.Char.Combat.Status")
check(joined(combat):find("Not in combat"), "in_combat:false clears the combat display")
mdwui.state.inCombat = true
raiseEvent("gmcp.Char.Combat.Ended")
check(joined(combat):find("Not in combat"), "Char.Combat.Ended clears it too")

-- 6. Comm routing: channel map + All mirror; history batch replaces backlog
gmcp.Comm.Channel = { channel = "say", sender = "Aria", text = "hello", ansi = "Aria says hello" }
raiseEvent("gmcp.Comm.Channel")
local comm = mdw.widgets["Comm"]
check(#comm.tabsByName["Room"]._buffer == 1, "say routed to the Room tab")
check(#comm.tabsByName["All"]._buffer >= 1, "All tab mirrors the message")
gmcp.Comm.Channel = { channel = "wibble", text = "odd", ansi = "odd" }
raiseEvent("gmcp.Comm.Channel")
check(#comm.tabsByName["Global"]._buffer == 1, "unknown channels land in Global")
gmcp.Comm.History = {
  { channel = "chat", text = "old one", ansi = "old one", timestamp = "11:02" },
  { channel = "tell", text = "old two", ansi = "old two", timestamp = "11:03" },
}
raiseEvent("gmcp.Comm.History")
check(#comm.tabsByName["Global"]._buffer == 1 and #comm.tabsByName["Tells"]._buffer == 1,
  "history batch replaces the backlog instead of appending")

-- 7. Quests: list, track toggle, lazy detail round-trip, invalidation
raiseEvent("gmcp.Char.Quests")
local quests = mdw.widgets["Quests"]
check(joined(quests):find("Wolves at the Gate"), "active quest listed")
findLink(quests.content, "untrack").cb()
check(H.sent[#H.sent] == "quest untrack 8", "track toggle sends the quest command")
findLink(quests.content, "Wolves").cb()
check(H.gmcpSent[#H.gmcpSent]:find('Char.Quest.Detail {"id":8}', 1, true) ~= nil,
  "expanding a quest lazily requests its detail")
check(joined(quests):find("Fetching"), "detail view shows fetching state")
gmcp.Char.Quest = { Detail = { id = 8, name = "Wolves at the Gate", category = "hunt",
  description = "The gate is under attack.", step_num = 1, step_count = 3,
  step_description = "Slay the wolves",
  objectives = { { text = "Wolves slain", current = 2, count = 5, done = false } },
  has_reward = true, reward_xp = 500, reward_gold = 100, reward_items = {} } }
raiseEvent("gmcp.Char.Quest.Detail")
local detailText = joined(quests)
check(detailText:find("under attack") and detailText:find("2/5"), "detail renders payload")
check(detailText:find("500 xp"), "detail shows rewards")
local before = #H.gmcpSent
raiseEvent("gmcp.Char.Quests")
check(#H.gmcpSent == before + 1, "a quests push re-requests the open detail (cache invalidation)")
findLink(quests.content, "back to quests").cb()
check(joined(quests):find("Wolves at the Gate") and not joined(quests):find("Fetching"),
  "back link returns to the list")

local journalText = joined(mdw.widgets["Journal"])
check(journalText:find("First Steps") and journalText:find("x3"), "journal lists completions")
check(journalText:find("Something stirs"), "journal lists rumors")

-- 8. Resize re-render keeps links alive (the bindRenderer contract)
local linkCountBefore = #eq.content._links
mdw.refreshWidgetContent(eq)
check(#eq.content._links == linkCountBefore and linkCountBefore > 0,
  "reflow re-renders equipment links from state")

-- 9. Copyover triggers a fresh full payload
local sentBefore = #H.gmcpSent
raiseEvent("gmcp.Engine.Copyover")
check(H.gmcpSent[#H.gmcpSent]:find("SendFullPayload") ~= nil and #H.gmcpSent == sentBefore + 1,
  "copyover re-requests the full payload")

-- 10. MDW update mid-session: our widgets and groups come back unaided
mdw.teardown()
mdw.setup()
H.flushTimers()
check(mdw.widgets["Combat"] ~= nil and mdw.widgets["Comm"] ~= nil,
  "widgets rebuilt after an MDW update")
check(mdw.widgets["Equipment"].stackId ~= nil, "grouping restored after update")

-- 11. Uninstalling this package removes everything ours, leaves MDW running.
-- The event carries the mfile package name - packageName must match it.
raiseEvent("sysUninstallPackage", mdwui.packageName)
check(mdw.widgets["Combat"] == nil and mdw.widgets["Comm"] == nil, "our widgets destroyed on uninstall")
check(mdw.onReady[mdwui.packageName] == nil, "onReady registration removed")
check(mdw.isSetUp, "MDW itself unaffected")

print("\nSMOKE PASSED")
