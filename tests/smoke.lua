-- MDW_UI smoke suite: loads MDW (sibling checkout or $MDW_SRC) and this
-- package against the stubbed Mudlet API, then drives the layout build and
-- every GMCP-fed surface with fixture payloads. Run from the repo root:
--   lua5.1 tests/smoke.lua

package.path = "tests/?.lua;" .. package.path
local H = require("stub_mudlet")
H.homeDir = os.getenv("TMPDIR") or "/tmp"

local MDW_SRC = os.getenv("MDW_SRC") or "../mdw/src/scripts/"
local MDW_ORDER = { "MDW_Config", "MDW_Helpers", "MDW_Init", "MDW_WidgetCore",
  "MDW_DockLayout", "MDW_Widget", "MDW_TabbedWidget", "MDW_Stack", "MDW_Menus",
  "MDW_Examples" }
-- THE SHIPPED ORDER, read from the manifest Mudlet itself loads by, so the
-- suite can never exercise a load order the package does not have. It used to
-- be a literal here, and a new module added to one list and not the other
-- simply went missing from every check in this file.
local UI_ORDER = {}
do
  local fh = assert(io.open("src/scripts/scripts.json"))
  local text = fh:read("*a")
  fh:close()
  for _, entry in ipairs(json_to_value(text)) do
    if entry.isFolder ~= "yes" then UI_ORDER[#UI_ORDER + 1] = entry.name end
  end
end

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
-- By tooltip instead of text: the quest chevrons all share the same glyph,
-- but each carries "Expand/Collapse <quest name>" as its hint.
local function findByHint(console, pattern)
  for _, link in ipairs(console._links) do
    if link.hint and link.hint:find(pattern) then return link end
  end
  return nil
end

-- Counts real MDW setups, so a test can SEE a rebuild happen rather than infer
-- it from side effects. Wrapped after MDW loads, restored by nothing - it only
-- ever adds a counter.
SETUPS = 0

-- 1. The HARD install path on purpose: MDW boots alone first (demo widgets
-- and all), then this package installs into the live session. That exercises
-- the late-join build, the demo-widget takeover, and the live config apply.
-- The seeds-before-MDW ordering is covered later by the MDW-update step,
-- which re-runs the registration through a full setup.
for _, name in ipairs(MDW_ORDER) do
  assert(pcall(dofile, MDW_SRC .. name .. ".lua"), "failed loading " .. name)
end
do
  local realSetup = mdw.setup
  mdw.setup = function(...) SETUPS = SETUPS + 1 return realSetup(...) end
end
raiseEvent("sysLoadEvent")
H.flushTimers()
check(mdw.isSetUp, "MDW sets up alone with its demo widgets")
check(mdw.widgets["Items"] ~= nil, "demo widgets present before our install")
check(mdw.widgets["Comm"].tabsByName["Tell"] ~= nil, "demo Comm carries its own tab set")

-- Cross-package version convention fixture: the mapper exposes its version
-- as a plain global field, which the top bar reads guarded at render time.
mapper = { version = "9.9.9" }

-- "Install" the package's native keys the way Mudlet does: it imports a
-- package's key items before any of its scripts ever run, so the names exist
-- by the time buildUI flips the folder.
local function loadKeysJson(path)
  local fh = assert(io.open(path))
  local text = fh:read("*a")
  fh:close()
  return json_to_value(text)
end
local numpadKeyDefs
for _, entry in ipairs(loadKeysJson("src/keys/keys.json")) do
  H.nativeKeys[entry.name] = (entry.isActive == "yes")
  if entry.isFolder == "yes" then
    numpadKeyDefs = loadKeysJson("src/keys/" .. entry.name .. "/keys.json")
    for _, def in ipairs(numpadKeyDefs) do
      H.nativeKeys[def.name] = (def.isActive == "yes")
    end
  end
end

for _, name in ipairs(UI_ORDER) do
  assert(pcall(dofile, "src/scripts/" .. name .. ".lua"), "failed loading " .. name)
end
-- The late-join build is armed a tick late on purpose (see the bottom of
-- Init.lua), so a mid-session install needs the tick before there is a UI.
H.flushTimers()
check(mdw.widgets["Items"] == nil, "demo-only widget destroyed by mid-session install")
check(mdw.widgets["Comm"].tabsByName["Global"] ~= nil and mdw.widgets["Comm"].tabsByName["Tell"] == nil,
  "demo Comm replaced with our channel tabs")
check(mdw.config.usePromptTrigger == false, "prompt trigger disabled live on mid-session install")
check(mdw.config.uiName == "WillowdaleUI", "UI branding applied live on mid-session install")
check(mdw.gamePackages and mdw.gamePackages[mdwui.packageName] == true,
  "registered for co-removal with MDW's full uninstall")
check(type(mdw.onTeardown[mdwui.packageName]) == "function", "MDW teardown hook registered")
local mfileFh = assert(io.open("mfile"))
local mfileText = mfileFh:read("*a")
local mfileVersion = mfileText:match('"version"%s*:%s*"([^"]+)"')
local mfilePackage = mfileText:match('"package"%s*:%s*"([^"]+)"')
mfileFh:close()
check(mdwui.version == mfileVersion, "mdwui.version matches the mfile version")
-- Mudlet reports the mfile name in sysUninstallPackage, so a mismatch here
-- means cleanup silently never fires.
check(mdwui.packageName == mfilePackage, "mdwui.packageName matches the mfile package")
check(mdw.bars["WillowdaleTop"] ~= nil and mdw.bars["WillowdaleTop"].edge == "top",
  "top chrome bar created below the header")
check(mdw.bars["WillowdaleTop"].owner == mdwui.packageName,
  "top bar carries our ownership stamp")

-- 1b. The MDW version requirement. Component-wise numeric compare, or
-- "0.10.0" would sort below "0.4.0" as a string.
check(mdwui.versionAtLeast("0.4.0", "0.4.0") == true, "equal versions satisfy the minimum")
check(mdwui.versionAtLeast("0.10.0", "0.4.0") == true, "0.10.0 outranks 0.4.0 numerically")
check(mdwui.versionAtLeast("0.3.9", "0.4.0") == false, "0.3.9 falls short of 0.4.0")
check(mdwui.versionAtLeast(nil, "0.4.0") == false, "a missing mdw.version is too old")
check(mdwui.versionAtLeast("0.4", "0.4.0") == true, "missing trailing components count as 0")
check(mdwui.mdwSatisfied(), "the sibling MDW checkout meets our minimum")
-- The pin is TWO constants and nothing at runtime notices them disagreeing:
-- the build gate reads minMdwVersion, the bootstrap downloads mdwUrl. Point
-- them at different releases and ensureMdw fetches an MDW that still fails
-- the gate - the player gets no UI at all, and one "needs MDW" line per
-- session, with the download working perfectly every time.
local pinnedMdw = mdwui.mdwUrl:match("/releases/download/v([^/]+)/")
check(pinnedMdw == mdwui.minMdwVersion, string.format(
  "mdwUrl matches minMdwVersion (offers %s, requires %s)",
  tostring(pinnedMdw), mdwui.minMdwVersion))
-- The gate must refuse BEFORE any side effect, so a build under an old MDW
-- leaves the live session exactly as it was.
local realMdwVersion = mdw.version
mdw.version = "0.3.0"
local barBefore = mdw.bars["WillowdaleTop"]
local echoedBefore = #H.main._echoed
mdwui.buildUI()
local refused = false
for i = echoedBefore + 1, #H.main._echoed do
  -- Read from the constant, not typed: the pin moves whenever a newer MDW API
    -- is adopted, and a hardcoded number here would fail the release that did it.
    if H.main._echoed[i]:find("needs MDW " .. mdwui.minMdwVersion, 1, true) then refused = true end
end
check(refused, "an old MDW gets one explanatory line on the main console")
check(mdw.bars["WillowdaleTop"] == barBefore, "the refused build rebuilt no chrome bar")
check(mdw.widgets["Journal"] ~= nil, "the refused build left the existing widgets alone")
mdw.version = realMdwVersion

-- 2. Layout: every widget exists and the default groups match the web client
for _, name in ipairs({ "Affects", "Keyring", "Equipment", "Inventory", "Forage",
  "Character", "Combat", "Group", "Map", "Comm", "Quests", "Journal" }) do
  check(mdw.widgets[name] ~= nil, "widget " .. name .. " created")
end
-- One Journal widget holds the whole `journal` command, quests included
-- (mirroring the web client); the split-out second one is retired on sight,
-- or a saved layout from that version would keep an empty panel docked.
check(mdw.widgets["PlayerJournal"] == nil, "the split-out journal widget is gone")
mdw.Widget:new({ name = "PlayerJournal", dock = "right" })
mdwui.buildUI()
check(mdw.widgets["PlayerJournal"] == nil,
  "a PlayerJournal restored from an older layout is destroyed on build")
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
-- First-run heights are measured from the content, not guessed as a fraction:
-- rows times the real line box, plus a stack's chrome. The checks below are
-- written around the failure that actually happened - MDW auto-fills the
-- BOTTOM row of a dock, and sizing a stack while it is still the bottom row
-- is silently discarded, so every default height sat at MDW's 200px no matter
-- what was asked for. The old assertions compared the two stacks to each
-- other and passed happily while BOTH were 200.
local itemsStack = mdw.widgets["MDWUI_Items"]
local statusStack = mdw.widgets["MDWUI_Status"]
local itemsH = itemsStack.container:get_height()
local statusH = statusStack.container:get_height()
local _, smokeWinH = getMainWindowSize()
check(itemsStack.fill ~= true and statusStack.fill ~= true,
  "neither sized group is the dock's fill row - a fill row cannot be sized at all")
check(itemsH ~= mdw.config.widgetHeight and statusH ~= mdw.config.widgetHeight,
  "and their first-run heights really were applied, not left at MDW's default")
-- Tall enough for a whole equipment loadout, counted from the same table the
-- renderer walks: a console with more content than height scrolls to the
-- BOTTOM, so being short by two lines hides the Weapons header, not the tail.
local wornRows = 0
for i, section in ipairs(mdwui.config.wornSections) do
  if i > 1 then wornRows = wornRows + 1 end
  wornRows = wornRows + 1 + #section.slots
end
check(itemsH >= wornRows * mdw.charHeightEstimate(mdw.config.contentFontSize),
  "the items group opens tall enough for a full equipment loadout")
check(statusH + itemsH < smokeWinH * 0.75,
  "and together they leave real room for the character group MDW auto-fills")
check(mdw.widgets["Map"].mapper ~= nil, "Map embeds the native mapper")

-- 3. Startup requests: full payload + native map feed
local requests = table.concat(H.gmcpSent, "|")
-- The exact frame matters: the server string-matches the bare text after the
-- first space - "GMCP SendFullPayload" works, a JSON-quoted body is dropped.
check(requests:find("GMCP SendFullPayload", 1, true) ~= nil, "full payload requested at build")
check(requests:find('"SendFullPayload"', 1, true) == nil, "full payload body is unquoted")
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
      -- attunement is the share of the item's power the character channels,
      -- item_level the tier of the piece itself. Two levels of differing width
      -- so the right-aligned column is exercised, and both attunement bands.
      Worn = { weapon = { id = "!20:aa", name = "iron sword", type = "weapon", sub_type = "sword",
        details = { "enchanted" }, command = "wield", attunement = 25, item_level = 12 },
        body = { id = "!20:bb", name = "leather vest", type = "armor", sub_type = "chest",
          details = {}, command = "wear", attunement = 100, item_level = 3 } },
      Backpack = {
        -- Shapes taken from a live payload: an item's own command is its verb,
        -- and it is what decides which action a menu offers.
        Items = { { id = "!21:bb", name = "red potion", type = "consumable", sub_type = "potion",
          quantity = 3, details = {}, command = "quaff" },
          { id = "!10100:1", name = "Rusty Sword", type = "weapon", sub_type = "slashing",
            quantity = 1, details = {}, command = "wield", uses = 0 },
          { id = "!30007:1", name = "Pork Pie", type = "food", sub_type = "edible",
            quantity = 1, details = {}, command = "eat", uses = 0 },
          { id = "!30004:1", name = "Elderflower Cordial", type = "drink", sub_type = "drinkable",
            quantity = 1, details = {}, command = "drink", uses = 0 } },
        Summary = { count = 4, max = 20 },
      },
      Keyring = {
        { type = "Key", location = "By the Cooper's Yard", roomid = 82, where = "south", sequence = "" },
        { type = "Lockpick", location = "Thieves' Den", roomid = 133, where = "chest", sequence = "1-3-2" },
      },
      -- Both shapes from a live Char.Inventory.Ingredients push: the bag holds
      -- crafting materials (empty command) alongside food (command "eat"),
      -- which is the whole reason the menu reads the item's own verb.
      Ingredients = { items = {
        { id = "!19022:1", name = "Fine Brown Hare Pelt", quantity = 1, details = {},
          type = "object", sub_type = "material", command = "", uses = 0 },
        { id = "!30203:1", name = "Wild Roots", quantity = 2, details = {},
          type = "food", sub_type = "edible", command = "eat", uses = 0 },
      }, count = 2, max = 30 },
    },
    Combat = {
      Enemies = { { id = 5, name = "a goblin", is_primary = true, health = 30, health_max = 40 },
                  { id = 6, name = "a wolf", health = 10, health_max = 25 } },
      Target = { id = 5, name = "a goblin", hp_current = 30, hp_max = 40 },
      Status = { in_combat = true, in_melee = true, combat_action = "" },
    },
    Balance = { balance = 2, max_balance = 4, seconds = "1.5", is_balanced = false },
    Quests = {
      active = {
        { id = 8, name = "Wolves at the Gate", category = "hunt", completion = 40,
          step_description = "Slay the wolves", tracked = true, ready = false,
          zone = "Gatelands", receiver = "",
          objectives = { { text = "Wolves slain", current = 2, count = 5, done = false },
            { text = "Report to the gate captain", current = 0, count = 1, done = false } } },
        { id = 9, name = "Grain Thief", category = "tutorial", completion = 100,
          step_description = "Return to Farmer Bram", tracked = false, ready = true,
          zone = "Fields", receiver = "Farmer Bram", objectives = {} },
      },
      completed = { { id = 2, name = "First Steps", count = 3 } },
      rumors = { { text = "Something stirs below", source_text = "a farmer", zone = "Fields" } },
    },
    Quest = {},
    -- Player journal (guide 5.15): Tier 1 counts are pushed, and always
    -- carry all six categories in the telnet front-page order.
    Journal = {
      categories = {
        { slug = "books", title = "Books", description = "Bound volumes you have read.", count = 2 },
        { slug = "documents", title = "Documents", description = "Scraps and letters.", count = 0 },
        { slug = "quests", title = "Quests", description = "Active and completed threads.", count = 2 },
        { slug = "rumors", title = "Rumors", description = "Whispers overheard.", count = 1 },
        { slug = "observations", title = "Observations", description = "Things noted.", count = 0 },
        { slug = "notes", title = "Notes", description = "Notes you jotted down.", count = 1 },
      },
      total = 6,
    },
  },
  Group = {
    Info = { leaderid = "u:1", members = {
      { id = "u:1", name = "Morquin", status = "leader", position = "front",
        class = "Ranger", autoattack = true },
      { id = "u:2", name = "Aria", status = "group", position = "middle",
        class = "Spirit Channeler", autoattack = false },
    } },
    Vitals = {
      { id = "u:1", name = "Morquin", level = 12, health = 100,
        healthcurrent = 240, healthmax = 240, location = "At a Large Willow Tree" },
      { id = "u:2", name = "Aria", level = 9, health = 62, healthcurrent = 50,
        healthmax = 80, location = "A Muddy Path", aggro = true },
    },
  },
  Comm = {},
  Game = { Clock = { time = "12:34:56" }, Calendar = { phase = "day", day_name = "Mireday" },
    -- The music catalog (guide 5.16): static for the life of the server
    -- process, in the order `music list` shows and a playlist plays in.
    Music = { base_url = "https://example.test/", tracks = {
      { id = "air", title = "Air", file = "static/audio/music/Air.mp3" },
      { id = "ballad", title = "Ballad", file = "static/audio/music/Ballad.mp3" },
      { id = "legend", title = "Legend", file = "static/audio/music/Legend.mp3" },
    } },
  },
}

raiseEvent("gmcp.Char.Info")
raiseEvent("gmcp.Char.Attributes")
raiseEvent("gmcp.Char.Worth")
raiseEvent("gmcp.Char.Vitals")
-- The Character panel mirrors the web client's #character-panel: a
-- name / Lv. N / class header, attributes beside the spendable points,
-- then the derived-stat columns. Strip decho color tags to assert on the
-- monospace grid the player actually sees.
local charPlain = joined(mdw.widgets["Character"]):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", ""):gsub("<r>", "")
check(charPlain:find("Morquin%s+Lv%. 12%s+Ranger"), "Character header: name, level, class")
check(charPlain:find("Body%s+10%s+Training Pts%s+2")
  and charPlain:find("Mind%s+8%s+Stat Pts%s+1")
  and charPlain:find("Spirit%s+6"), "attributes sit beside the spendable points")
check(charPlain:find("Armor%s+12%s+Martial Pwr%s+18")
  and charPlain:find("Evasion%s+15%%%s+Aether Pwr%s+9")
  and charPlain:find("Warding%s+3%s+Resilience%s+4"), "derived-stat grid matches the web client")
check(not charPlain:find("1,234") and not charPlain:find("HP") and not charPlain:find("12:34"),
  "gold, vitals and the clock stay out of the Character panel (prompt layer/toolbar data)")
check(mdwui.fmtNum(1234) == "1,234", "fmtNum groups thousands")

-- Top bar: identity from Char.Info plus the connection timer on the left,
-- the three package versions on the right via the version-exposure
-- convention (mdwui.version + mdw.version + mapper.version).
local topBar = mdw.bars["WillowdaleTop"]
local function topBarPlain()
  return joined(topBar.console):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", "")
end
local function topBarWidth()
  return mdw.calculateWrap(topBar.console:get_width(), mdw.config.contentFontSize) - 1
end
local topPlain = topBarPlain()
check(topPlain:find("Morquin") and topPlain:find("Ranger") and topPlain:find("Lvl%. 12"),
  "top bar shows name, class and level")
check(topPlain:find("Con%. Time: %d%dh %d%dm %d%ds"), "top bar shows the connection timer")
check(topPlain:find("UI v" .. mdwui.version, 1, true) ~= nil, "top bar shows the UI version")
check(topPlain:find("MDW v" .. mdw.version, 1, true) ~= nil, "top bar shows MDW's version")
check(topPlain:find("Mapper v9.9.9", 1, true) ~= nil,
  "top bar reads the mapper's exposed version")
-- Color coding: each package name carries its own hue, the "v" is dim and
-- the version is the clock's body text, and the clock's unit letters take
-- the class gold. Checked on the raw decho, before stripping.
local topRaw = joined(topBar.console)
check(topRaw:find("<" .. mdwui.config.colors.verMapper .. ">Mapper <"
  .. mdwui.config.colors.dim .. ">v<" .. mdwui.config.colors.text .. ">9.9.9",
  1, true) ~= nil,
  "package name takes its hue, the whole version the body text, the v dim")
check(topRaw:find("<" .. mdwui.config.colors.text .. ">%d%d<"
  .. mdwui.config.colors.charGold .. ">h") ~= nil,
  "the connection clock's h/m/s take the class gold")
-- The gap between the two groups is pure padding, so identity sits at column
-- one and the versions end exactly at the bar's usable width.
check(topPlain:find("Morquin - Ranger Lvl. 12", 1, true) == 1, "identity group sits flush left")
check(topPlain:sub(-#"Mapper v9.9.9") == "Mapper v9.9.9"
  and #topPlain == topBarWidth(),
  "right group padded flush to the bar's wrap width, one column short of the wrap")
topBar.console:resize(700, nil)
mdwui.renderTopBar()
topPlain = topBarPlain()
check(#topPlain == mdw.calculateWrap(700, mdw.config.contentFontSize) - 1
  and topPlain:sub(-#"Mapper v9.9.9") == "Mapper v9.9.9",
  "top bar re-pads to a narrower console")
mdw.layoutBars() -- restore the real width for everything downstream
-- The 1s ticker carries the clock (and the re-pad after a resize, which MDW
-- performs with no callback to hook). Fire the registered timers in place
-- rather than through H.flushTimers: the teardown checks further down need
-- these ids still alive.
local topClears = topBar.console._clears or 0
for _, id in ipairs(mdwui.state.timers) do
  if H.timers[id] then H.timers[id]() end
end
check((topBar.console._clears or 0) > topClears,
  "the 1s ticker repaints the top bar's connection clock")

-- Live sidebar drags: bindRenderer marks every panel reflow as a cheap pure
-- repaint (MDW's liveReflow opt-in), so the width-aware Character grid
-- re-renders on every drag move instead of deferring to the release.
mdw.selectStackTab(mdw.widgets["MDWUI_Char"], "Character")
local liveClears = mdw.widgets["Character"].content._clears or 0
mdw.splitterDrag.active = true
mdw.reorganizeDock("left")
mdw.splitterDrag.active = false
check((mdw.widgets["Character"].content._clears or 0) > liveClears,
  "Character grid re-renders during a live sidebar drag")
-- Web defaults (promptBarSettings): the Vitals prompt line stays hidden -
-- the gauges carry those numbers - while the Worth line (prompt2) shows.
check(joined(mdw.promptBar):find("carrying 4/20", 1, true) ~= nil,
  "worth line (prompt2) drives the prompt bar")
check(joined(mdw.promptBar):find("HP:80 AE:45>", 1, true) == nil,
  "vitals prompt line hidden by default like the web client")

-- 4a. Prompt layer: the web client's default gauge set (hp/ae/balance; the
-- enemy bar stays in the Combat widget) tracks Vitals and Balance, with the
-- web client's fill colors and band shifts.
check(mdw.promptGauges.hp ~= nil and mdw.promptGauges.ae ~= nil and mdw.promptGauges.balance ~= nil,
  "prompt layer carries the HP/AE/Balance gauges")
check(mdw.promptGauges.hp.text._echoed[1] == "HP 80/120"
  and mdw.promptGauges.ae.text._echoed[1] == "AE 45/60", "prompt gauges labeled from Vitals")
check(mdw.promptGauges.hp.front._css:find("60,160,80", 1, true) ~= nil,
  "healthy HP wears the web client's green fill")
gmcp.Char.Vitals.health = 20
raiseEvent("gmcp.Char.Vitals")
check(mdw.promptGauges.hp.front._css:find("220,60,50", 1, true) ~= nil,
  "low HP shifts the fill red at the web-client threshold")
gmcp.Char.Vitals.health = 80
raiseEvent("gmcp.Char.Vitals")
-- The bound slice of the aether pool (guide 5.1 `aether_reserved`, web
-- _setGaugeReserved). The fixture carries no such field - an older server
-- sends none - so the untouched gauge proves a player with nothing bound
-- still gets exactly the track this package has always drawn.
do
  local aeBar = mdw.promptGauges.ae
  local g = mdwui.config.gauges
  check(aeBar.back._css == mdwui.trackCss(g.aeTrack),
    "an AE pool with nothing bound keeps the plain track")
  -- 15 of 60 bound caps recovery at 45, which is where the pool already
  -- sits: the fill still scales against the TRUE maximum, so it ends exactly
  -- at the slice's edge, three quarters along the bar.
  gmcp.Char.Vitals.aether_reserved = 15
  raiseEvent("gmcp.Char.Vitals")
  check(aeBar.text._echoed[1] == "AE 45/60" and aeBar._value == 45 and aeBar._max == 60,
    "the AE label and the fill keep speaking in the true maximum")
  check(aeBar.back._css:find("stop:0.7500 " .. g.aeTrack, 1, true) ~= nil
    and aeBar.back._css:find("stop:0.7501 " .. g.aeReserved, 1, true) ~= nil,
    "the bound slice is a hard-edged segment pinned at the full end of the track")
  check(aeBar.front._css:find("140,70,200", 1, true) ~= nil,
    "and the fill keeps the web client's AE color")
  -- Everything bound: no boundary left to draw and no fill to meet it, while
  -- the label keeps the pool the player still holds.
  gmcp.Char.Vitals.aether_reserved = 60
  raiseEvent("gmcp.Char.Vitals")
  check(aeBar._value == 0 and aeBar.text._echoed[1] == "AE 45/60",
    "a wholly bound pool leaves no fill and keeps its true numbers")
  check(aeBar.back._css == mdwui.trackCss(g.aeReserved),
    "and no gradient - the whole bar reads as reserve")
  -- 10 of 320 puts the edge on 0.96875, where "%.4f" of the edge and of the
  -- edge plus a ten-thousandth used to print the same string - one position,
  -- one colour, and the boundary blended across the whole bar.
  gmcp.Char.Vitals.aether_max, gmcp.Char.Vitals.aether_reserved = 320, 10
  raiseEvent("gmcp.Char.Vitals")
  check(aeBar.back._css:find("stop:0.9687 " .. g.aeTrack, 1, true) ~= nil
    and aeBar.back._css:find("stop:0.9688 " .. g.aeReserved, 1, true) ~= nil,
    "the two stops never round onto one position: 10 of 320 sits on a %.4f tie")
  gmcp.Char.Vitals.aether_max, gmcp.Char.Vitals.aether_reserved = 60, nil
  raiseEvent("gmcp.Char.Vitals")
  check(aeBar.back._css == mdwui.trackCss(g.aeTrack),
    "releasing the reserve puts the plain track back")
end
raiseEvent("gmcp.Char.Balance")
local balGauge = mdw.promptGauges.balance
check(balGauge.text._echoed[1] == "1.5s" and balGauge._value == 2 and balGauge._max == 4,
  "draining balance shows the preformatted seconds over the drained bar")
check(balGauge.front._css:find("50,90,160", 1, true) ~= nil, "draining balance dims the fill")
gmcp.Char.Balance = { balance = 4, max_balance = 4, seconds = "0.0", is_balanced = true }
raiseEvent("gmcp.Char.Balance")
check(balGauge.text._echoed[1] == "Balanced" and balGauge._value == 1 and balGauge._max == 1,
  "regained balance shows a full Balanced bar")
check(balGauge.front._css:find("60,110,200", 1, true) ~= nil,
  "regained balance restores the normal fill")

-- 4b. Prompt bar settings menu: the vertical-ellipsis button toggles
-- elements live (keepOpen checkbox rows) and persists into mdw.gameSettings.
check(H.labels["MDW_PromptBarMenuBtn"] ~= nil, "prompt bar settings button present")
H.callbacks["MDW_PromptBarMenuBtn"].click()
check(H.labels["MDW_ContextMenuItem1"]._echoed[1]:find("[ ] Vitals", 1, true) ~= nil
  and H.labels["MDW_ContextMenuItem2"]._echoed[1]:find("[x] Worth", 1, true) ~= nil,
  "menu rows mirror the web-client defaults")
H.callbacks["MDW_ContextMenuItem6"].click() -- Enemy on
check(H.labels["MDW_PromptGauge_enemy_back"] ~= nil, "enemy gauge appears when toggled on")
check(mdw.promptGauges.enemy.text._echoed[1] == "No Enemy", "enemy gauge idles as No Enemy")
check(mdw.gameSettings[mdwui.packageName].promptBar.enemy == true,
  "prompt bar toggle persisted to gameSettings")
H.callbacks["MDW_ContextMenuItem1"].click() -- Vitals on
check(joined(mdw.promptBar):find("HP:80 AE:45>", 1, true) ~= nil,
  "vitals prompt line returns when toggled on")
local _, promptCharH = calcFontSize(mdw.getPromptEffectiveFontSize())
check(mdw.config.promptBarHeight >= 2 * promptCharH + mdw.config.promptBarTopPadding
  + mdw.config.separatorHeight + mdw.promptGaugeRowHeight(),
  "bar grew so the re-enabled vitals line is visible without dragging")
H.callbacks["MDW_ContextMenuItem1"].click() -- Vitals back off
check(mdw.config.promptBarHeight == math.ceil(promptCharH) + mdw.config.promptBarTopPadding
  + mdw.config.separatorHeight + mdw.promptGaugeRowHeight(),
  "bar shrinks back when the vitals line is hidden again")
mdw.closeAllMenus()

raiseEvent("gmcp.Char.Affects")
local affText = joined(mdw.widgets["Affects"])
check(affText:find("Sanctuary") and affText:find("2:00"), "affects show with countdown")
check(affText:find("Regen") and affText:find("perm"), "permanent affects marked")

-- Equipment: the web client's sectioned panel (updateEquipSlot + the
-- .eq-section markup) - gold slot labels, teal names with [C][E][Q] flags,
-- "-nothing-" empties, and the item tooltip as the whole-row link's hint.
raiseEvent("gmcp.Char.Inventory.Worn")
local eq = mdw.widgets["Equipment"]
local eqText = joined(eq)
check(eqText:find("Weapons:") and eqText:find("Armor:") and eqText:find("Jewelry:"),
  "equipment renders the three web sections")
check(eqText:find("Mainhand:", 1, true) and eqText:find("iron sword", 1, true),
  "equipped item on its labeled slot row")
check(eqText:find("[<136,136,255>E", 1, true) ~= nil, "enchanted renders as its [E] flag")
check(eqText:find("-nothing-", 1, true) ~= nil, "empty slots read -nothing-")
-- Attunement (.eq-attune-*): every occupied slot carries its share, banded by
-- quarter - a color for full strength is only worth having if full strength
-- prints, so 100 is a blue "100%" and not a blank. Only empty and disabled
-- slots pad, to the same six columns the widest percentage fills, so every
-- name in the panel starts in one column whatever sits in front of it.
local eqVisible = (eqText:gsub("<%d+,%d+,%d+>", ""))
check(eqText:find("<200,120,50> 25%  ", 1, true) ~= nil,
  "a quarter-attuned item takes the orange band, not the yellow one above it")
check(eqText:find("<74,163,214>100%  ", 1, true) ~= nil,
  "and a fully attuned one prints 100% in the full-strength blue")
check(eqVisible:find("Mainhand:  25%  (12)  [E] iron sword", 1, true) ~= nil,
  "label, percentage, level, flags, name - the game's own row order")
check(eqVisible:find("Body: 100%   (3)  leather vest", 1, true) ~= nil,
  "100% spends the column narrower percentages pad, and a short level indents")
-- The column header rides the Weapons section header, the web client's
-- .eq-attune-head span inside that row: it exists only because something
-- below it shows a number, and it sits on the columns those numbers occupy,
-- in the section-header parchment rather than any band's.
local eqHead = eqVisible:match("^([^\n]*)\n")
local eqSword = eqVisible:match("\n([^\n]*iron sword[^\n]*)")
local eqVest = eqVisible:match("\n([^\n]*leather vest[^\n]*)")
local eqEmpty = eqVisible:match("\n([^\n]*%-nothing%-[^\n]*)")
-- Item level (.eq-ilvl): the muted gray between the percentage and the name,
-- right-aligned in its own four columns so a one-digit and a two-digit level
-- end together and every name below starts on one column - empty slots pad
-- the field like they pad the percentage.
check(eqText:find("<136,136,136>(12) ", 1, true) ~= nil
  and eqText:find("<136,136,136> (3) ", 1, true) ~= nil,
  "levels render in the web client's muted gray, the short one right-aligned")
check(eqVest:find("leather vest", 1, true) == eqSword:find("[E] iron sword", 1, true),
  "so a one-digit level leaves its name in the same column as a two-digit one")
check(eqEmpty:find("-nothing-", 1, true) == eqSword:find("[E] iron sword", 1, true),
  "and an empty slot pads both fields, so -nothing- lands there too")
check(eqHead == "Weapons:  Att:  Lvl:", "a worn loadout heads the columns on the Weapons line")
check(eqText:find("<232,220,200>Att:", 1, true) ~= nil,
  "the header takes the section header's parchment, not a band color")
check(eqSword:find(" 25%", 1, true) == eqHead:find("Att:", 1, true),
  "and it starts on the same column as the percentage below it")
check(eqVest:find("100%", 1, true) == eqHead:find("Att:", 1, true),
  "which the four-character 100% shares with the three-character ones")
check(eqSword:find("(12)", 1, true) == eqHead:find("Lvl:", 1, true),
  "and Lvl: starts on the same column as the level tokens below it")
-- The whole band ladder (.eq-attune-100/-75/-50/-25/-0), including the bottom
-- rung the game cannot reach today - a worn item floors at 25% - but which the
-- payload could still carry.
for _, band in ipairs({
  { 100, "74,163,214", "blue of full strength" },
  { 80, "79,165,95", "green just under it" },
  { 60, "224,176,32", "yellow of the half" },
  { 40, "200,120,50", "orange of the quarter" },
  { 10, "225,90,90", "red below a quarter" },
}) do
  gmcp.Char.Inventory.Worn.weapon.attunement = band[1]
  raiseEvent("gmcp.Char.Inventory.Worn")
  check(joined(eq):find(string.format("<%s>%3d%%", band[2], band[1]), 1, true) ~= nil,
    string.format("attunement %d takes the %s", band[1], band[3]))
end
gmcp.Char.Inventory.Worn.weapon.attunement = 25
-- Nothing worn, nothing to head: a header over an all-blank column reads as
-- broken, so an empty loadout leaves the section headers bare.
local wornFixture = gmcp.Char.Inventory.Worn
gmcp.Char.Inventory.Worn = {}
raiseEvent("gmcp.Char.Inventory.Worn")
check(joined(eq):find("Att:", 1, true) == nil,
  "an empty loadout renders no header over the blank column")
gmcp.Char.Inventory.Worn = wornFixture
raiseEvent("gmcp.Char.Inventory.Worn")
check(findLink(eq.content, "iron sword").hint
  == "iron sword\nWeapon (Sword)\nEnchanted\nUse: Remove",
  "equipment row hint carries the web tooltip box")
-- The row opens the web client's equipment menu: Remove (by slot), then Look
findLink(eq.content, "iron sword").cb()
check(H.labels["MDW_ContextMenuTitle"] ~= nil
  and H.labels["MDW_ContextMenuTitle"]._echoed[1]:find("iron sword", 1, true) ~= nil,
  "clicking an item opens its context menu")
H.callbacks["MDW_ContextMenuItem1"].click()
check(H.sent[#H.sent] == "remove weapon" and H.sentEcho[#H.sentEcho] == false,
  "menu Remove sends the slot command, silently like every click affordance")
check(mdw.menus.context == false and H.labels["MDW_ContextMenuItem1"] == nil,
  "context menu closes after acting")

-- Inventory: the web client's numbered list (updateInventoryList) with the
-- "N out of max items." footer over a rule; rows carry the item tooltip.
raiseEvent("gmcp.Char.Inventory.Backpack.Items")
local inv = mdw.widgets["Inventory"]
local invText = joined(inv)
check(invText:find(" 1 - <", 1, true) and invText:find("red potion", 1, true)
  and invText:find("(3)", 1, true), "inventory row is numbered with (quantity)")
check(invText:find("4 out of 20 items.", 1, true) and invText:find("─"),
  "inventory footer counts stacks over a rule")
check(findLink(inv.content, "red potion").hint
  == "red potion\nConsumable (Potion)\nUse: Quaff",
  "inventory row hint carries the web tooltip box")
-- Each item's OWN command is its action, whatever the item is - the same rule
-- that decides whether the forage bag offers Eat.
findLink(inv.content, "Rusty Sword").cb()
check(H.labels["MDW_ContextMenuItem1"]._echoed[1]:find("Wield") ~= nil,
  "a weapon's menu leads with its own verb, Wield")
findLink(inv.content, "Pork Pie").cb()
check(H.labels["MDW_ContextMenuItem1"]._echoed[1]:find("Eat") ~= nil,
  "and food leads with Eat, from the same field")
findLink(inv.content, "Elderflower Cordial").cb()
check(H.labels["MDW_ContextMenuItem1"]._echoed[1]:find("Drink") ~= nil,
  "and a drink leads with Drink - nothing here special-cases a type")
-- Menu rows mirror makeInventoryClickHandler: own verb first, then Look, Drop
findLink(inv.content, "red potion").cb()
check(H.labels["MDW_ContextMenuItem1"]._echoed[1]:find("Quaff") ~= nil,
  "item's own verb heads its menu, capitalized")
H.callbacks["MDW_ContextMenuItem1"].click()
check(H.sent[#H.sent] == "quaff !21:bb", "menu verb sends with the item id")
findLink(inv.content, "red potion").cb()
H.callbacks["MDW_ContextMenuItem3"].click()
check(H.sent[#H.sent] == "drop !21:bb", "menu Drop sends with the item id")

-- Sell gates on Room.Info.Basic.environment and is decided when the menu
-- OPENS: entering a shop adds the row with no inventory repaint in between.
findLink(inv.content, "red potion").cb()
check(H.labels["MDW_ContextMenuItem4"] == nil, "no Sell row outside a shop")
mdw.closeAllMenus()
gmcp.Room = { Info = { Basic = { environment = "Shop" } } }
findLink(inv.content, "red potion").cb()
check(H.labels["MDW_ContextMenuItem4"] ~= nil
  and H.labels["MDW_ContextMenuItem4"]._echoed[1]:find("Sell") ~= nil,
  "entering a shop adds Sell at menu-open without a repaint")
H.callbacks["MDW_ContextMenuItem4"].click()
check(H.sent[#H.sent] == "sell !21:bb", "menu Sell sends with the item id")

-- Keyring: the web client's keychain table (updateKeychainList) - header
-- row over a rule, "#roomid location", capitalized right-aligned exit.
raiseEvent("gmcp.Char.Inventory.Keyring")
local keyOut = joined(mdw.widgets["Keyring"])
check(keyOut:find("Type") and keyOut:find("Exit") and keyOut:find("─"),
  "keyring header row over a rule")
check(keyOut:find("#82", 1, true) ~= nil, "keyring location leads with the room id")
check(keyOut:find("South\n", 1, true) ~= nil and keyOut:find("Chest\n", 1, true) ~= nil,
  "keyring exit capitalized at the row's right edge")
check(keyOut:find("Sequence: <92,179,165>1%-3%-2"), "lockpick sequence on its own line")
raiseEvent("gmcp.Char.Inventory.Ingredients")
local forageText = joined(mdw.widgets["Forage"])
check(forageText:find("Wild Roots") and forageText:find("(2)", 1, true)
  and forageText:find("2 out of 30 items.", 1, true),
  "forage renders the same numbered list and footer")
-- The ingredient menu leads with Eat, for something that can BE eaten: the bag
-- holds crafting materials too, and "Eat" on a hare pelt is nonsense a player
-- has to read past every time.
findLink(mdw.widgets["Forage"].content, "Wild Roots").cb()
check(H.labels["MDW_ContextMenuItem1"]._echoed[1]:find("Eat") ~= nil,
  "an edible ingredient leads with Eat")
H.callbacks["MDW_ContextMenuItem1"].click()
check(H.sent[#H.sent] == "eat !30203:1", "menu Eat sends with the ingredient id")
findLink(mdw.widgets["Forage"].content, "Hare Pelt").cb()
local pelt = H.labels["MDW_ContextMenuItem1"]._echoed[1]
check(pelt:find("Eat") == nil and pelt:find("Look") ~= nil,
  "a crafting material offers no Eat at all, and leads with Look")
-- Still in the shop from above: the ingredient bag sells too (sell.go
-- searches backpack then ingredient bag)
findLink(mdw.widgets["Forage"].content, "Wild Roots").cb()
check(H.labels["MDW_ContextMenuItem4"] ~= nil
  and H.labels["MDW_ContextMenuItem4"]._echoed[1]:find("Sell") ~= nil,
  "ingredient menu offers Sell in a shop")
H.callbacks["MDW_ContextMenuItem4"].click()
check(H.sent[#H.sent] == "sell !30203:1", "forage Sell sends with the ingredient id")
gmcp.Room = nil -- leave the shop for the rest of the suite

-- 4c. Group widget: the web client's member card (updateGroupPanel), two
-- lines per member - name and class against the autoattack mode, then a real
-- gauge banded like .grp-hp-* against the level/position tag.
raiseEvent("gmcp.Group.Info")
local groupWidget = mdw.widgets["Group"]
local function rowText(id)
  local el = H.labels["MDW_Group_Row_" .. id]
  return el and el._echoed[#el._echoed] or ""
end
check(rowText("name_1"):find("Morquin", 1, true) ~= nil
  and rowText("name_1"):find("leader", 1, true) ~= nil,
  "group shows the named leader")
check(rowText("hp_1_Right") == "<138,131,120>L12 front"
  and rowText("hp_2_Right") == "<138,131,120>L9 middle",
  "level (Vitals) and position (Info) tag the gauge line")
check(rowText("name_1"):find("Ranger", 1, true) ~= nil,
  "class rides the name line")
check(rowText("name_1_Right"):find("auto", 1, true) ~= nil
  and rowText("name_2_Right"):find("manual", 1, true) ~= nil,
  "the autoattack mode shares the name's line")
check(rowText("name_1"):find("<" .. mdwui.config.colors.grpLeader .. ">leader", 1, true)
  and rowText("name_1"):find(mdwui.config.colors.charHeader, 1, true) == 2,
  "only the word leader is green - the name keeps the header color")
check(H.labels["MDW_Group_Row_loc_1"] == nil,
  "the room stays out of the card")
-- The web client's card border has no equivalent in a stack of rows, so
-- members are divided by the Character panel's rule.
check(H.labels["MDW_Group_Row_sep_2"]._css:find("border-top", 1, true) ~= nil
  and H.labels["MDW_Group_Row_sep_2"]._css:find(mdwui.config.colors.charDivider, 1, true) ~= nil,
  "members are divided by the Character panel's rule")
check(H.labels["MDW_Group_Row_sep_1"] == nil, "no rule above the first member")
-- Aggro is a red card border in the web client; a row of labels has no
-- border, so it lands on the name.
check(rowText("name_2"):find(mdwui.config.colors.bad, 1, true) == 2,
  "a member in combat is flagged on their name")
local ariaGauge = groupWidget._rows and groupWidget._rows["hp_2"]
check(ariaGauge ~= nil and ariaGauge.el._value == 50 and ariaGauge.el._max == 80
  and ariaGauge.el.text._echoed[1] == "50/80", "group member health is a real gauge")
check(ariaGauge.el.front._css:find("190,170,60", 1, true) ~= nil,
  "member fill banded by percent (62% = mid)")
-- Info and Vitals join on the server id, never the name: a rename-free join
-- is the whole reason the ids exist (two members can own same-named pets).
gmcp.Group.Vitals[2].id = "u:9"
raiseEvent("gmcp.Group.Vitals")
check(groupWidget._rows["hp_2"].el._value == 0
  and rowText("hp_2_Right") == "<138,131,120>L0 middle",
  "vitals join on id, not on the matching name")
gmcp.Group.Vitals[2].id = "u:2"
raiseEvent("gmcp.Group.Vitals")

-- Invited players have not accepted: tagged, and no vitals rows at all.
gmcp.Group.Info.invited = { { id = "u:3", name = "Bob", status = "invited" } }
raiseEvent("gmcp.Group.Info")
check(rowText("name_3_Right"):find("invited", 1, true) ~= nil
  and groupWidget._rows["hp_3"] == nil,
  "an invited player gets no gauge")
-- A charmed creature fights when its owner does, so it has no mode of its
-- own; its tag stays on the name line and its bar keeps the full width.
gmcp.Group.Info.invited = nil
gmcp.Group.Info.members[3] = { id = "m:7", name = "a wolf", status = "companion",
  companion = true }
gmcp.Group.Vitals[3] = { id = "m:7", name = "a wolf", level = 3, health = 100,
  healthcurrent = 30, healthmax = 30, companion = true }
raiseEvent("gmcp.Group.Info")
check(rowText("name_3_Right"):find("companion", 1, true) ~= nil
  and groupWidget._rows["hp_3"] ~= nil
  and H.labels["MDW_Group_Row_hp_3_Right"] == nil,
  "a companion keeps its tag on the name line, so its bar runs full width")
gmcp.Group.Info.members[3] = nil
gmcp.Group.Vitals[3] = nil
gmcp.Group.Info.invited = nil

-- Vitals arriving before the roster (movement, combat) still shows a group.
local savedInfo = gmcp.Group.Info
gmcp.Group.Info = nil
raiseEvent("gmcp.Group.Vitals")
check(rowText("name_1"):find("Morquin", 1, true) ~= nil
  and groupWidget._rows["hp_1"] ~= nil, "vitals-only payload still renders the roster")
gmcp.Group.Info = savedInfo
raiseEvent("gmcp.Group.Info")

-- 5. Combat: the web panel's rows (enemy names, PLAYER gauges, enemy bars),
-- click-to-target, auto-target, and both end signals. Defaults per
-- combatWidgetSettings: hp + enemy gauges + names on; ae/balance off.
raiseEvent("gmcp.Char.Combat.Status")
raiseEvent("gmcp.Char.Combat.Enemies")
raiseEvent("gmcp.Char.Combat.Target")
local combat = mdw.widgets["Combat"]
-- Character was the active tab (the live-drag step selected it): combat
-- starting must front the Combat tab like the web client (setCombatActive),
-- so its freshly built rows land on a VISIBLE container.
local charStack = mdw.widgets["MDWUI_Char"]
check(charStack.activeMember == "Combat", "combat start fronts the Combat tab")
check(H.labels["MDW_Combat_Row_name_5"]._shown == true,
  "combat rows visible on the fronted tab")
local goblinRow = H.labels["MDW_Combat_Row_name_5"]
check(goblinRow ~= nil and H.labels["MDW_Combat_Row_name_6"] ~= nil, "enemy name rows rendered")
local goblinText = goblinRow._echoed[#goblinRow._echoed]
check(goblinText:find("(T)", 1, true) ~= nil, "target marker painted from Target.id")
check(goblinText:find("engaged", 1, true) ~= nil, "melee status text follows the web-client rule")
check(combat._rows["hp"] ~= nil and combat._rows["hp"].el._value == 80,
  "player HP is a real gauge inside the widget")
check(combat._rows["ae"] == nil and combat._rows["balance"] == nil,
  "AE and Balance default off in the combat widget (web defaults)")
check(combat._rows["bar_5"].el._value == 30
  and combat._rows["bar_5"].el.text._echoed[1]:find("a goblin 30/40", 1, true) ~= nil,
  "enemy health bars carry name and numbers")
H.callbacks["MDW_Combat_Row_name_6"].click()
check(H.sent[#H.sent] == "target #6" and H.sentEcho[#H.sentEcho] == false,
  "clicking an enemy name targets it with the # prefix, silently")
check(mdw.promptGauges.enemy.text._echoed[1]:find("a goblin 30/40", 1, true) ~= nil,
  "prompt bar enemy gauge tracks the live target")

-- The player tabs back to Character mid-fight: per-beat pushes must neither
-- snap the tab back (the switch is transition-gated, unlike the web's
-- per-push re-assert) nor paint rows over the active member - the changed
-- enemy set recreates the row block, and fresh rows must inherit the hidden
-- container state (the MDW fix for the Geyser creation gotcha).
mdw.selectStackTab(charStack, "Character")
-- Auto-target: current target (5) leaves the list, wolf (6) remains
gmcp.Char.Combat.Enemies = { { id = 6, name = "a wolf", health = 10, health_max = 25 } }
raiseEvent("gmcp.Char.Combat.Enemies")
check(H.sent[#H.sent] == "target #6", "auto-target re-targets the surviving enemy")
check(charStack.activeMember == "Character",
  "mid-fight pushes leave the player's tab choice alone")
check(H.labels["MDW_Combat_Row_name_6"]._shown == false,
  "rows recreated behind the Character tab stay hidden")
mdw.selectStackTab(charStack, "Combat")
check(H.labels["MDW_Combat_Row_name_6"]._shown == true,
  "rows appear when the Combat tab returns")

gmcp.Char.Combat.Status = { in_combat = false }
raiseEvent("gmcp.Char.Combat.Status")
check(charStack.activeMember == "Character",
  "combat end returns the Character tab (web setCombatActive)")
check(combat._rows["idle"] ~= nil, "in_combat:false shows the idle row")
check(combat._rows["name_6"] == nil, "enemy rows cleared out of combat")
check(mdw.promptGauges.enemy.text._echoed[1] == "No Enemy",
  "prompt bar enemy gauge clears with combat")
mdwui.state.inCombat = true
raiseEvent("gmcp.Char.Combat.Ended")
check(combat._rows["idle"] ~= nil, "Char.Combat.Ended clears it too")

-- 5a. Combat widget settings menu: same pattern as the prompt bar's, keyed
-- to the web combatWidgetSettings names (info = enemy names section).
check(H.labels["MDW_Combat_MenuBtn"] ~= nil, "combat settings button present")
H.callbacks["MDW_Combat_MenuBtn"].click()
check(H.labels["MDW_ContextMenuItem2"]._echoed[1]:find("[ ] AE Gauge", 1, true) ~= nil,
  "combat menu mirrors the web defaults")
H.callbacks["MDW_ContextMenuItem2"].click() -- AE Gauge on
check(combat._rows["ae"] ~= nil and combat._rows["ae"].el._value == 45,
  "AE gauge appears in the widget when toggled on")
check(mdw.gameSettings[mdwui.packageName].combat.ae == true, "combat toggle persisted")
check(combat._rows["ae"].back == mdwui.trackCss(mdwui.config.gauges.aeTrack),
  "the widget's AE row starts on the plain track")
-- The widget row draws the bound slice out of the same helper as the prompt
-- gauge, so the two surfaces cannot disagree about it - which is what the
-- track compared against the live prompt gauge's own backCSS says.
do
  local g = mdwui.config.gauges
  gmcp.Char.Vitals.aether_reserved = 15
  raiseEvent("gmcp.Char.Vitals")
  check(combat._rows["ae"].el._value == 45
    and combat._rows["ae"].back == mdw.promptGauges.ae.backCSS
    and combat._rows["ae"].back ~= mdwui.trackCss(g.aeTrack),
    "the combat widget's AE row carries the same bound slice as the prompt gauge")
  gmcp.Char.Vitals.aether_reserved = 60
  raiseEvent("gmcp.Char.Vitals")
  check(combat._rows["ae"].el._value == 0
    and combat._rows["ae"].back == mdwui.trackCss(g.aeReserved),
    "a wholly bound pool empties the widget row too")
  gmcp.Char.Vitals.aether_reserved = nil
  raiseEvent("gmcp.Char.Vitals")
  check(combat._rows["ae"].el._value == 45
    and combat._rows["ae"].back == mdwui.trackCss(g.aeTrack),
    "releasing the reserve puts the widget row back on the plain track")
end
H.callbacks["MDW_ContextMenuItem2"].click() -- back off for the later sections
check(combat._rows["ae"] == nil, "AE gauge leaves when toggled off")
mdw.closeAllMenus()

-- 5b. Music (guide 5.16): the catalog and the settings are two packages, and
-- the widget is a pure repaint of both. Its LAYOUT is the web client's "Sound
-- & Music" panel - a bare master slider, the "Music" header, the hint, the
-- catalog with a playlist box per row, and Repeat/Shuffle under it - drawn in
-- this package's own palette, so an MDW theme still reaches it. It writes ONLY
-- through the silent Char.Audio.Set node - a click on a slider, a box or a
-- title must never put a `music` command in the player's main window.
--
-- Wrapped in a do block for the same reason the sections below it are not:
-- Lua 5.1 allows 200 locals per chunk and this suite is one chunk, so a
-- section with more than a couple of its own keeps them to itself.
do
local music = mdw.widgets["Music"]
--- Echoed cells carry their decho colour tag, so both readers take the tags
-- off first and match on the words.
local function plainText()
  return (joined(music):gsub("<[^>]*>", ""))
end
local function linkTexts()
  local out = {}
  for i, link in ipairs(music.content._links) do
    out[i] = (link.text:gsub("<[^>]*>", ""))
  end
  return out
end
--- The nth link of the current paint. Re-read every time: the console's link
-- list is replaced by the clear() at the top of each render.
local function link(n)
  return music.content._links[n]
end
local function lastGmcp()
  return H.gmcpSent[#H.gmcpSent]
end

check(joined(music):find("No music has arrived", 1, true) ~= nil,
  "the Music widget renders an empty state before either package lands")
raiseEvent("gmcp.Game.Music")
-- Char.Audio - this character's own settings, pushed after every change -
-- lands a moment after the catalog here on purpose: a widget built before
-- either package must show something rather than error.
check(plainText():find("[ ] Air\n[ ] Ballad\n[ ] Legend\n", 1, true) ~= nil,
  "the catalog paints a checkbox and a title per track, in catalog order")
check(plainText():find("[+]", 1, true) == nil and plainText():find("(playing)", 1, true) == nil,
  "and nothing else - no ordinals, no [+] buttons, no now-playing word")
-- Before the first push there is no stored playlist and no stored flag to
-- build a write from, so the boxes DRAW but do not click (the web swallows
-- that click too).
check(table.concat(linkTexts(), "|") == "Air|Ballad|Legend",
  "before Char.Audio only the titles are links - the boxes are not")
check(plainText():find("[ ] Repeat   [ ] Shuffle", 1, true) ~= nil,
  "Repeat and Shuffle draw under the list all the same")

local gmcpBeforeAudio = #H.gmcpSent
gmcp.Char.Audio = {
  mode = "playlist", music_volume = 75, track = "air",
  playlist = { "air", "ballad" }, ["repeat"] = false, shuffle = false,
  volumes = { combat = 75, movement = 60, environment = 75, other = 75 },
  sound = true,
}
raiseEvent("gmcp.Char.Audio")
check(#H.gmcpSent == gmcpBeforeAudio, "a repaint on its own writes nothing")

-- The row block is the panel's top: one unlabelled slider, the header and the
-- hint. The four sound-effect levels live on `ui music volume` - nothing in
-- this game plays through them, which is why the web panel hides its own.
local rowIds = {}
for i, row in ipairs(music._rowDefs) do rowIds[i] = row.id end
check(table.concat(rowIds, "|") == "vol_music|hdr|hint"
  and music._rows["now"] == nil and music._rows["vol_combat"] == nil,
  "the rows are the master slider, the header and the hint, and nothing else")
check(music._rows["vol_music"].type == "slider" and music._rows["vol_music"].el._value == 75
  and music._rows["vol_music"].el.text._echoed[1] == "",
  "the slider carries the music level and no label of its own")
check(music._rows["vol_music"].front == mdwui.fillCss(mdwui.config.gauges.aeFill)
  and music._rows["vol_music"].back == mdwui.trackCss(mdwui.config.gauges.aeTrack),
  "drawn with the package's own gauge colours, not a palette of its own")
check(music._rowDefs[2].text == string.format("<%s>Music", mdwui.config.colors.charLabel)
  and music._rowDefs[2].fontSize == mdwui.config.gauges.headerFontSize
  and music._rowDefs[2].height == mdwui.config.gauges.headerHeight
  and music._rowDefs[3].text
    == string.format("<%s>Click title to play. Check box to add to playlist.",
      mdwui.config.colors.dim),
  "the header is styled like the Combat widget's, and the hint says what to click")
-- The web hangs its settings off the panel itself, so there is no menu button
-- to hang them off here either.
check(H.labels["MDW_Music_MenuBtn"] == nil, "the Music widget carries no menu button")

-- The playing track is marked by the package's own live colour and nothing
-- else: no background, no suffix, no second marker.
check(joined(music):find("<" .. mdwui.config.colors.good .. ">Air", 1, true) ~= nil
  and joined(music):find("<" .. mdwui.config.colors.link .. ">Ballad", 1, true) ~= nil,
  "the playing title is C.good and every other title C.link")
check(joined(music):find("<%d+,%d+,%d+:") == nil,
  "and no cell carries a decho background at all - the console keeps MDW's")
check(table.concat(linkTexts(), "|")
    == "[x]|Air|[x]|Ballad|[ ]|Legend|[ ] Repeat|[ ] Shuffle",
  "the push turns every box into a link and ticks the two tracks in the playlist")

-- An MDW without slider rows still shows the level (mdw.rowTypes is the
-- capability, and a plain gauge is the documented stand-in).
local realRowTypes = mdw.rowTypes
mdw.rowTypes = { text = true, gauge = true }
mdwui.renderMusic()
check(music._rows["vol_music"].type == "gauge" and music._rows["vol_music"].el._value == 75,
  "an MDW without sliders falls back to a display-only gauge")
mdw.rowTypes = realRowTypes
mdwui.renderMusic()

-- Clicking a title plays it. GMCP only, and nothing on the command line.
local sentBeforeMusic = #H.sent
link(2).cb()
check(lastGmcp() == 'Char.Audio.Set {"track":"air"}',
  "clicking a title plays it through the silent write node")
check(#H.sent == sentBeforeMusic, "and sends no game command at all")
-- Playlist edits are built from the list the server told us, never from an
-- empty local one: the field REPLACES the playlist.
link(5).cb()
check(lastGmcp() == 'Char.Audio.Set {"playlist":["air","ballad","legend"]}',
  "an empty box sends the whole new playlist, the stored one plus this track")
link(1).cb()
check(lastGmcp() == 'Char.Audio.Set {"playlist":["ballad"]}',
  "a ticked one sends the stored playlist without this track")
link(7).cb()
check(lastGmcp() == 'Char.Audio.Set {"repeat":true}', "Repeat flips the stored flag")
link(8).cb()
check(lastGmcp() == 'Char.Audio.Set {"shuffle":true}', "and Shuffle its own")
gmcp.Char.Audio["repeat"] = true
raiseEvent("gmcp.Char.Audio")
check(table.concat(linkTexts(), "|")
    == "[x]|Air|[x]|Ballad|[ ]|Legend|[x] Repeat|[ ] Shuffle",
  "the box ticks because the push says so, not because it was clicked")
gmcp.Char.Audio["repeat"] = false
raiseEvent("gmcp.Char.Audio")

-- A drag writes ONCE, on the release: a write per mouse move would answer
-- every pixel with a re-sent track. There is no label to follow the pointer,
-- so nothing is previewed either.
local sliderName = music._rows["vol_music"].el.text.name
local sliderWidth = music._rows["vol_music"].el.text:get_width()
local gmcpBeforeDrag = #H.gmcpSent
H.callbacks[sliderName].click({ x = sliderWidth * 0.2 })
H.callbacks[sliderName].move({ x = sliderWidth * 0.4 })
check(music._rows["vol_music"].el._value == 40 and #H.gmcpSent == gmcpBeforeDrag,
  "a drag moves the bar under the pointer and writes nothing")
H.callbacks[sliderName].release()
check(lastGmcp() == 'Char.Audio.Set {"music_volume":40}',
  "the release commits the music level once")
-- The push is the answer to every write, and it takes the bar back.
raiseEvent("gmcp.Char.Audio")
check(music._rows["vol_music"].el._value == 75,
  "and the Char.Audio push repaints the stored level over it")

-- Track-end relay: a playlist track plays once, and the client reporting the
-- end is what advances the playlist. Everything else Mudlet finishes playing
-- must be ignored - sound effects share the event.
local gmcpBeforeEnd = #H.gmcpSent
raiseEvent("sysMediaFinished", "Air.mp3", "media/", "music")
check(lastGmcp() == 'Char.Audio.Set {"next":true}' and #H.gmcpSent == gmcpBeforeEnd + 1,
  "the playing track ending asks the server for the next one, once")
gmcpBeforeEnd = #H.gmcpSent
raiseEvent("sysMediaFinished", "Ballad.mp3", "media/", "music")
raiseEvent("sysMediaFinished", "Air.mp3", "media/", "sound")
check(#H.gmcpSent == gmcpBeforeEnd,
  "another file, or a sound effect, advances nothing")
gmcp.Char.Audio.mode = "server"
raiseEvent("gmcp.Char.Audio")
gmcpBeforeEnd = #H.gmcpSent
raiseEvent("sysMediaFinished", "Air.mp3", "media/", "music")
check(#H.gmcpSent == gmcpBeforeEnd,
  "and a looping track in server mode needs no relay")
gmcp.Char.Audio.mode = "playlist"

-- The sound toggle is the one affordance here that IS a typed command, since
-- the server sends no MSP at all while it is off.
gmcp.Char.Audio.sound = false
raiseEvent("gmcp.Char.Audio")
check(joined(music):find("Sound is off", 1, true) ~= nil
  and #linkTexts() == 9 and linkTexts()[1] == "config sound on",
  "sound off is said, with the command that turns it back on")
gmcp.Char.Audio.sound = true
raiseEvent("gmcp.Char.Audio")

-- Widget affordances are MOUSE gestures: the command they stand for must not
-- be echoed into the main window as if the player had typed it. Every
-- console link in the package goes out through mdwui.link, so one check here
-- covers the item, quest and journal lists too.
gmcp.Char.Audio.sound = false
raiseEvent("gmcp.Char.Audio")
link(1).cb()
check(H.sent[#H.sent] == "config sound on" and H.sentEcho[#H.sentEcho] == false,
  "mdwui.link sends its command silently")
gmcp.Char.Audio.sound = true
raiseEvent("gmcp.Char.Audio")
end
-- 5c. Connection Stats (guide 5.17): the one PULL-ONLY panel here. Nothing
-- pushes Game.Connection, so the widget owns a 2s poll that runs only while
-- it is on screen, and it is CLOSED on a first run - which is what the gear
-- menu row exists to undo. Its figures are the server's: a client cannot
-- count its own wire bytes.
do
local conn = mdw.widgets["Connection"]
local function plainConn()
  return (joined(conn):gsub("<[^>]*>", ""))
end
local function connRequests()
  local n = 0
  for _, sent in ipairs(H.gmcpSent) do
    if sent:find("Game.Connection", 1, true) then n = n + 1 end
  end
  return n
end

check(conn ~= nil and conn.title == "Connection Stats", "the widget exists, titled as the web panel")
check(mdw.isWidgetShown(conn) == false, "closed on a first run - the one widget that is")
check(conn.stackId ~= "MDWUI_Comms", "and left out of the default right-dock group")
-- Floated into the top-right corner of the MAIN CONSOLE AREA on its first run,
-- not docked: a readout you glance at and close again, so it earns no slice of
-- a sidebar. Placed after the top chrome bar exists, because the bar is part
-- of what defines that corner - measured here against the same bar.
do
  local group = mdw.widgets[conn.stackId]
  local margin = mdw.config.floatMargin
  local winW = (getMainWindowSize())
  check(group.docked == nil and group.originalDock == nil, "floating, not docked")
  -- Past the main console's scrollbar as well as the margin: MDW draws that
  -- allowance for every right-hand anchor, and this panel is the reason.
  check(group.container:get_x() + group.container:get_width()
    == winW - mdw.config.rightDockWidth - mdw.config.mainScrollBarWidth - margin,
    "a margin in from the right sidebar's edge, clear of the console scrollbar")
  check(group.container:get_y()
    == mdw.config.headerHeight + mdw.barsHeight("top") + margin,
    "and a margin below the header and our own top bar")
  check(mdw.barsHeight("top") > 0,
    "which is only a real test because that bar exists by then")
end
check(joined(conn):find("Waiting for the server", 1, true) ~= nil,
  "an empty state until the first answer, since nothing pushes this node")

-- A hidden panel costs the connection nothing: the poll asks only when
-- someone is looking at it. Re-armed before each of the two flushes below:
-- the harness runs a repeating timer once and drops it, and the poll buildUI
-- armed was spent by an earlier section's flush.
local hiddenBefore = connRequests()
mdwui.startConnectionPoll()
H.flushTimers()
check(connRequests() == hiddenBefore, "the poll asks for nothing while the panel is closed")

-- The gear row is what reopens it (mdw.addMenuItem, declared from buildUI so
-- MDW stamps it with this package).
local gearRow
for _, row in ipairs(mdw.gameMenu or {}) do
  if row.id == "connection" then gearRow = row end
end
check(gearRow ~= nil, "a gear-menu row is declared for the panel")
check(gearRow.checked() == false, "its checkbox reads the panel's live visibility")
local beforeOpen = connRequests()
gearRow.onClick()
check(mdw.isWidgetShown(conn) and gearRow.checked() == true, "clicking it reveals the panel")
-- ...where it was left, not re-centred. This is what makes the corner a
-- first-run DEFAULT rather than a rule the package re-imposes: mdw.showWidget
-- shows a hidden float without moving it, so a player who drags this panel
-- somewhere keeps it there across every close and reopen.
check(mdw.widgets[conn.stackId].container:get_x()
  == (getMainWindowSize()) - mdw.config.rightDockWidth
    - mdw.config.mainScrollBarWidth - mdw.config.floatMargin
    - mdw.widgets[conn.stackId].container:get_width(),
  "reopening leaves it where it was rather than re-centring it")
check(connRequests() == beforeOpen + 1,
  "and asks at once - a pull-only node has nothing cached to paint")

local shownBefore = connRequests()
mdwui.startConnectionPoll()
H.flushTimers()
check(connRequests() == shownBefore + 1, "the poll asks while the panel is open")

gmcp.Game = gmcp.Game or {}
gmcp.Game.Connection = {
  transport = "websocket", compression = "deflate", active = true,
  bytes_sent = 2401239, bytes_wire = 431411, bytes_saved = 1969828,
  saved_pct = 82.03, ratio = 5.57, measured = true,
}
raiseEvent("gmcp.Game.Connection")
check(plainConn():find("Transport", 1, true) ~= nil and plainConn():find("WebSocket", 1, true) ~= nil,
  "the wire enum prints as the word the web panel shows")
check(plainConn():find("Deflate (permessage-deflate)", 1, true) ~= nil,
  "and the compression names its mechanism, not just the algorithm")
check(plainConn():find("2.29 MB") ~= nil and plainConn():find("421.3 KB") ~= nil
  and plainConn():find("1.88 MB") ~= nil,
  "byte totals are 1024-based, with the precision the web panel uses")
check(mdwui.fmtBytes(900) == "900 B" and mdwui.fmtBytes(1536) == "1.5 KB",
  "and small counts stay in the unit they fit")
check(plainConn():find("82.0%% %(5.57:1%)") ~= nil, "the saved share carries its ratio")
check(plainConn():find("TLS framing") ~= nil,
  "an HTTPS session is told its wire figure sits under TLS")

-- The header band is a row, not console text: it carries the Refresh
-- affordance, and a row's click target is the whole strip.
check(conn._rowDefs and conn._rowDefs[1].id == "hdr"
  and conn._rowDefs[1].text:find("Session bandwidth", 1, true) ~= nil
  and conn._rowDefs[1].rightText:find("Refresh", 1, true) ~= nil,
  "the header row carries the title and the Refresh affordance")
local beforeRefresh = connRequests()
conn._rows["hdr"].onClick()
check(connRequests() == beforeRefresh + 1, "clicking the header re-asks")

-- measured = false: the guide says treat the derived fields as UNAVAILABLE,
-- not as zero. A session that has sent bytes but had none counted must not
-- read as having saved all of them.
gmcp.Game.Connection.measured = false
raiseEvent("gmcp.Game.Connection")
check(plainConn():find("82.0%%") == nil and plainConn():find("421.3 KB") == nil,
  "nothing measured yet withholds every derived figure")
check(plainConn():find("Expanded") ~= nil, "the count the server did make still shows")

gmcp.Game.Connection.measured = true
gmcp.Game.Connection.transport = "telnet"
raiseEvent("gmcp.Game.Connection")
check(plainConn():find("Telnet") ~= nil and plainConn():find("exact") ~= nil
  and plainConn():find("TLS framing") == nil,
  "telnet figures are exact, so the TLS caveat is not printed at them")
gmcp.Game.Connection.transport = "websocket"

-- The typed surface. `ui connection` cannot print at the moment it runs -
-- there is nothing current to print - so it asks and prints on arrival.
local beforeAsk = connRequests()
local mainBefore = #H.main._echoed
mdwui.command("connection")
check(connRequests() == beforeAsk + 1, "ui connection asks the server")
check(table.concat(H.main._echoed, "", mainBefore + 1, #H.main._echoed)
  :find("Asking the server", 1, true) ~= nil,
  "and says so, rather than answering silently")
mainBefore = #H.main._echoed
raiseEvent("gmcp.Game.Connection")
local answer = table.concat(H.main._echoed, "", mainBefore + 1, #H.main._echoed)
check(answer:find("Session bandwidth", 1, true) ~= nil
  and answer:find("WebSocket", 1, true) ~= nil and answer:find("5.57:1", 1, true) ~= nil,
  "the answer prints to the main console when it lands")
-- The poll keeps answering all session; only the answer to a question the
-- player asked may print.
mainBefore = #H.main._echoed
raiseEvent("gmcp.Game.Connection")
check(#H.main._echoed == mainBefore, "an unasked-for answer prints nothing")

check(mdwui.resolveWidget("conn") == conn, "the widget answers to a spoken shorthand")
local beforeNamed = connRequests()
mdwui.command("refresh connection")
check(connRequests() == beforeNamed + 1, "ui refresh connection pulls the node by name")
local beforeAll = connRequests()
mdwui.command("refresh")
check(connRequests() == beforeAll,
  "but a full refresh does not - Game.Connection is outside the login batch")

gearRow.onClick()
check(mdw.isWidgetShown(conn) == false, "the gear row closes the panel again")
end

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

-- 7. Quests: the web client's two zone-keyed sections (updateQuestsPanel),
-- chevron expand/collapse, quest menu (per questContextOptions), lazy detail
-- round-trip, invalidation
gmcp.Room = { Info = { Basic = { area = "Fields" } } }
raiseEvent("gmcp.Char.Quests")
local quests = mdw.widgets["Quests"]
local questPlain = joined(quests):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", "")
check(questPlain:find("Tracked:") and questPlain:find("Here:"),
  "quest panel renders the web client's two sections")
check(questPlain:find("%[8%] Wolves at the Gate"), "tracked quest row carries its [id]")
check(questPlain:find("40%%\n"), "completion right-aligned at the row's edge")
check(questPlain:find("Wolves slain") == nil, "objective lines start collapsed (web default)")
check(questPlain:find("%[9%] Grain Thief") and questPlain:find("Heard from a farmer"),
  "Here lists the zone's ready untracked quest and its rumor")
check(questPlain:find("Nothing nearby") == nil, "populated Here drops the empty text")

-- Chevron round-trip; expansion is per quest and survives re-renders
findByHint(quests.content, "Expand Wolves").cb()
questPlain = joined(quests):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", "")
check(questPlain:find("Wolves slain (2/5)", 1, true) ~= nil,
  "chevron expands objectives with the (current/count) counter")
check(questPlain:find("Report to the gate captain\n", 1, true) ~= nil,
  "single-count objective shows no (0/1) counter")
findByHint(quests.content, "Expand Grain").cb()
check(joined(quests):find("See Farmer Bram", 1, true) ~= nil,
  "a Here entry expands to its turn-in pointer")
raiseEvent("gmcp.Char.Quests")
check(joined(quests):find("Wolves slain", 1, true) ~= nil,
  "a quests push keeps expanded quests open")
findByHint(quests.content, "Collapse Wolves").cb()
questPlain = joined(quests):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", "")
check(questPlain:find("Wolves slain") == nil
  and questPlain:find("See Farmer Bram", 1, true) ~= nil,
  "collapsing one quest leaves the other open")

-- Here is zone-keyed: the Room.Info.Basic push repaints it, so leaving the
-- zone empties the section (the web client's Room.Info handler behavior)
gmcp.Room = { Info = { Basic = { area = "Elsewhere" } } }
raiseEvent("gmcp.Room.Info.Basic")
questPlain = joined(quests):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", "")
check(questPlain:find("Grain Thief") == nil and questPlain:find("Nothing nearby") ~= nil,
  "leaving the zone empties the Here section")
gmcp.Room = { Info = { Basic = { area = "Fields" } } }
raiseEvent("gmcp.Room.Info.Basic")

findLink(quests.content, "Wolves").cb()
check(H.labels["MDW_ContextMenuTitle"]._echoed[1]:find("%[8%] Wolves") ~= nil,
  "quest menu titled with id and name")
-- Item 2 is the separator; the track toggle is item 3
H.callbacks["MDW_ContextMenuItem3"].click()
check(H.sent[#H.sent] == "quest untrack 8", "menu Untrack sends the quest command")
findLink(quests.content, "Wolves").cb()
H.callbacks["MDW_ContextMenuItem1"].click()
check(H.gmcpSent[#H.gmcpSent]:find('Char.Quest.Detail {"id":8}', 1, true) ~= nil,
  "menu Information lazily requests the quest detail")
check(joined(quests):find("Fetching"), "detail view shows fetching state")
gmcp.Char.Quest = { Detail = { id = 8, name = "Wolves at the Gate", category = "hunt",
  description = "The gate is under attack.", step_num = 1, step_count = 3,
  step_description = "Slay the wolves", step_hint = "They den to the north.",
  giver_name = "Captain Hale", giver_zone = "Gatelands", active = true,
  hints = { { emote = "scowls at the treeline.", say = "Mind the alpha." } },
  objectives = { { text = "Wolves slain", current = 2, count = 5, done = false },
    { text = "Warn the farmers", current = 1, count = 1, done = true } },
  quest_items = { { name = "wolf pelt", count = 3 } },
  has_reward = true, reward_xp = 500, reward_gold = 100,
  -- reward_items are {name,count} OBJECTS - concatenating them as strings
  -- was a real crash in the detail renderer, so the fixture carries one.
  reward_items = { { name = "gate token", count = 2 } },
  reward_title = "Wolfsbane", reward_skill = "Tracking", reward_buff = "Keen Eye" } }
raiseEvent("gmcp.Char.Quest.Detail")
-- Whitespace-flattened: prose wider than the dock wraps, and these checks are
-- about CONTENT. The indent that survives wrapping is asserted separately,
-- against a fixed width, in the Journal section below.
local detailFlat = joined(quests):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", ""):gsub("%s+", " ")
check(detailFlat:find("under attack") and detailFlat:find("Wolves slain (2/5)", 1, true),
  "detail renders payload")
check(detailFlat:find("Given by: Captain Hale", 1, true)
  and detailFlat:find("Current step (1 of 3)", 1, true)
  and detailFlat:find("Tip: They den to the north.", 1, true),
  "detail carries the web client's giver/step/tip lines")
check(detailFlat:find('Captain Hale says, "Mind the alpha."', 1, true) ~= nil,
  "hint beats render as the giver's recalled counsel")
check(detailFlat:find("wolf pelt x3", 1, true) ~= nil, "held quest items listed")
check(detailFlat:find("500 experience, 100 gold", 1, true)
  and detailFlat:find("Item: gate token x2", 1, true)
  and detailFlat:find("Title: Wolfsbane", 1, true)
  and detailFlat:find("Skill: Tracking", 1, true)
  and detailFlat:find("Blessing: Keen Eye", 1, true),
  "reward block matches the web client, item objects included")
local gmcpSentBeforePush = #H.gmcpSent
raiseEvent("gmcp.Char.Quests")
check(#H.gmcpSent == gmcpSentBeforePush + 1,
  "a quests push re-requests the open detail (cache invalidation)")
-- The back link is a pure view switch: quest names appear in BOTH views, so
-- assert on the list-only completion percentage and the detail state itself,
-- and that no game command went out (the bug this caught: the link sent the
-- `quests` command instead of leaving the detail view).
local sentBeforeBack = #H.sent
findLink(quests.content, "back to quests").cb()
check(mdwui.state.questDetailId == nil and joined(quests):find("40%%"),
  "back link returns to the list view")
check(#H.sent == sentBeforeBack, "back link sends no game command")

-- The invalidating push above sent a fresh detail request for quest 8 that is
-- still in flight; land its response so the journal below has a warm cache.
raiseEvent("gmcp.Char.Quest.Detail")

-- 7a. The Journal widget's QUESTS category: the full filterable quest list
-- (renderQuestJournal), which lives inside the journal now rather than in a
-- widget of its own - the same merge the web client made, and what telnet's
-- `journal quests` has always done.
local journal = mdw.widgets["Journal"]
raiseEvent("gmcp.Char.Journal", "gmcp.Char.Journal")
check(joined(journal):find("Books") ~= nil, "the journal opens on its category front page")
local questsBefore = #H.gmcpSent
findLink(journal.content, "Quests").cb()
check(mdwui.state.pjCategory == "quests", "the Quests row opens a view inside the journal")
-- Char.Journal.List does not serve the quests category - a request for it is
-- answered with silence, so none may go out.
check(#H.gmcpSent == questsBefore,
  "opening Quests requests no journal list (that category is never served)")
local journalPlain = joined(journal):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", "")
-- The name column is elastic and ellipsis-clips at the dock's width (web
-- text-overflow parity), so assert on the stable prefix, not the full name.
check(journalPlain:find("%[8%] Wolves at the") and journalPlain:find("untrack"),
  "journal lists active quests with the web's track button")
check(journalPlain:find("%[9%] Grain Thief") and journalPlain:find("100%%"),
  "journal shows a ready quest and its completion")
check(journalPlain:find("First Steps") and journalPlain:find("completed x3", 1, true),
  "journal lists completions with their repeat count")
check(journalPlain:find("Something stirs"), "journal lists rumors")
check(journalPlain:find("All zones", 1, true) and journalPlain:find("All statuses", 1, true)
  and journalPlain:find("All categories", 1, true), "journal renders its filter bar")

-- The track button sends the real game command (web .qst-track-btn parity)
findLink(journal.content, "untrack").cb()
check(H.sent[#H.sent] == "quest untrack 8", "journal track button sends the quest command")

-- A row expands to the full detail, fetched lazily on first open. Quest 8's
-- detail is already cached from the Quests widget above, so this row paints
-- from cache without a new request.
local beforeExpand = #H.gmcpSent
findByHint(journal.content, "Expand Wolves").cb()
check(joined(journal):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", ""):gsub("%s+", " "):find("Given by: Captain Hale", 1, true) ~= nil,
  "expanded journal row renders the quest detail")
check(#H.gmcpSent == beforeExpand, "a cached detail expands without a new request")

-- A row with no cached detail requests it once and shows the loading state,
-- and repeated repaints must NOT re-request (the in-flight guard).
findByHint(journal.content, "Expand First Steps").cb()
check(H.gmcpSent[#H.gmcpSent]:find('Char.Quest.Detail {"id":2}', 1, true) ~= nil,
  "expanding an uncached row requests its detail")
check(joined(journal):find("Loading...", 1, true) ~= nil, "uncached row shows the loading state")
local beforeReflow = #H.gmcpSent
mdw.refreshWidgetContent(journal)
check(#H.gmcpSent == beforeReflow, "repaints do not re-request an in-flight detail")
gmcp.Char.Quest = { Detail = { id = 2, name = "First Steps", completed = true,
  completion = "Bram nods you off with a wave.", has_reward = false } }
raiseEvent("gmcp.Char.Quest.Detail")
check(joined(journal):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", ""):gsub("%s+", " "):find("Bram nods you off", 1, true) ~= nil,
  "the arriving detail replaces the loading state")

-- Wrapped detail lines keep their own indent. Mudlet can indent wrapped lines
-- console-wide (setWindowWrapIndent for the first segment,
-- setWindowWrapHangingIndent for continuations), but each is ONE value per
-- console and these levels nest - headers flush, prose at 2, objectives and
-- rewards at 4 - so the renderer wraps and indents per line instead.
mdwui.state.questDetailCache["8"].description =
  "The gate is under attack and the wolves keep coming from the deep wood beyond the palisade."
journal._wrapWidth = 40
mdwui.renderJournal()
local proseLines, deepLines, lostIndent, tooWide = 0, 0, false, false
for line in joined(journal):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", ""):gmatch("[^\n]+") do
  local inProse = line:find("deep wood", 1, true) or line:find("palisade", 1, true)
  local inDeep = line:find("Wolves slain", 1, true) or line:find("experience", 1, true)
  if inProse or inDeep then
    if #line > 40 then tooWide = true end
    if inProse then
      proseLines = proseLines + 1
      if line:sub(1, 2) ~= "  " or line:sub(3, 3) == " " then lostIndent = true end
    else
      deepLines = deepLines + 1
      if line:sub(1, 4) ~= "    " then lostIndent = true end
    end
  end
end
-- The web client's italics and line-through, which decho renders with its
-- <i> and <s> tags (Mudlet parses b/i/r/u/s/o inline).
local journalRaw = joined(journal):gsub("<[%d,]+>", "")
check(journalRaw:find("<i>", 1, true) ~= nil
  and journalRaw:find('<i>"The gate is under attack', 1, true) ~= nil,
  "the quest hook renders italic (.qj-detail-quote)")
check(journalRaw:find("<s>Warn the farmers</s>", 1, true) ~= nil,
  "a completed objective renders struck through (.qst-obj-done)")
check(journalRaw:find("<i>Tip: They den to the north.</i>", 1, true) ~= nil,
  "the step tip renders italic (.qj-detail-meta)")
-- Every wrapped chunk carries its own tags: a decho resets the format at both
-- ends, so an <i> opened on one line cannot reach the next.
local italicChunks = select(2, journalRaw:gsub("<i>", ""))
check(italicChunks >= 3, "each wrapped chunk repeats the attribute tag")

check(proseLines >= 2, "the long description genuinely wrapped onto continuation lines")
check(not lostIndent, "wrapped lines keep their indent (prose at 2, objectives/rewards at 4)")
check(not tooWide, "no wrapped detail line exceeds the console width")
check(deepLines >= 2, "objectives and rewards sit one level deeper, like the web client")
journal._wrapWidth = nil
mdwui.renderJournal()

-- Filters: status narrows the list, and the selection survives repaints.
local statusLink = findLink(journal.content, "All statuses")
statusLink.cb()
H.callbacks["MDW_ContextMenuItem5"].click() -- "Completed"
journalPlain = joined(journal):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", "")
check(journalPlain:find("First Steps") and not journalPlain:find("Wolves at the Gate")
  and not journalPlain:find("Something stirs"),
  "status filter keeps only completed rows")
findLink(journal.content, "Completed").cb()
H.callbacks["MDW_ContextMenuItem4"].click() -- "Rumors"
journalPlain = joined(journal):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", "")
check(journalPlain:find("Something stirs") and not journalPlain:find("First Steps"),
  "status filter switches to rumors")
findByHint(journal.content, "Expand this rumor").cb()
check(joined(journal):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", ""):gsub("%s+", " "):find("Heard from a farmer | Fields", 1, true) ~= nil,
  "a rumor expands to its masked attribution line, not a GMCP pull")

-- Zone filter, keyed on Room.Info.Basic.area like the Quests widget's Here
gmcp.Room = { Info = { Basic = { area = "Elsewhere" } } }
findLink(journal.content, "Rumors").cb()
H.callbacks["MDW_ContextMenuItem1"].click() -- back to "All statuses"
findLink(journal.content, "All zones").cb()
H.callbacks["MDW_ContextMenuItem2"].click() -- "Current zone"
check(joined(journal):find("Nothing matches these filters.", 1, true) ~= nil,
  "current-zone filter in an empty zone shows the web's empty text")
gmcp.Room = { Info = { Basic = { area = "Fields" } } }
raiseEvent("gmcp.Room.Info.Basic")
journalPlain = joined(journal):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", "")
check(journalPlain:find("Grain Thief") and journalPlain:find("Something stirs"),
  "moving into the zone repaints the current-zone rows")
findLink(journal.content, "Current zone").cb()
H.callbacks["MDW_ContextMenuItem1"].click() -- back to "All zones"

-- The completed list is OMITTED from progress-only pushes (guide 5.9): the
-- cached copy must survive, or the history vanishes mid-session.
gmcp.Char.Quests.completed = nil
raiseEvent("gmcp.Char.Quests")
check(joined(mdw.widgets["Journal"]):find("First Steps", 1, true) ~= nil,
  "a progress-only push reuses the cached completed list")
-- A character switch is the one thing that must drop that cache - and it
-- closes the open category with it, since every id and index belonged to the
-- previous character. Re-open Quests, or the check below would pass merely
-- because the front page carries no quest names.
gmcp.Char.Info.name = "Someone Else"
raiseEvent("gmcp.Char.Info")
check(mdwui.state.pjCategory == nil, "a character switch closes the open category")
mdwui.state.pjCategory = "quests"
mdwui.renderJournal()
check(joined(mdw.widgets["Journal"]):find("First Steps") == nil,
  "a character switch drops the previous character's completed history")
gmcp.Char.Info.name = "Morquin"
raiseEvent("gmcp.Char.Info")

-- 7b. The same widget's other five categories - the player journal proper
-- (guide 5.15, Char.Journal.*). Three tiers: pushed counts, pulled header
-- pages, pulled entry content, because a character can hold thousands.
mdwui.state.pjCategory = "quests"
mdwui.renderJournal()
findLink(journal.content, "back").cb()
check(mdwui.state.pjCategory == nil, "the crumb returns from Quests to the categories")
raiseEvent("gmcp.Char.Journal", "gmcp.Char.Journal")
local pjournal = journal
local pjPlain = joined(pjournal)
check(pjPlain:find("Books") and pjPlain:find("Observations") and pjPlain:find("Notes"),
  "front page lists the category counts")
check(pjPlain:find("Total"), "front page totals the entries")

-- Opening a category pulls its first page of headers.
local requestsBefore = #H.gmcpSent
findLink(pjournal.content, "Books").cb()
check(H.gmcpSent[#H.gmcpSent]:find('Char.Journal.List {"category":"books","page":1}', 1, true) ~= nil,
  "opening a category requests its first page")
check(joined(pjournal):find("Loading...", 1, true) ~= nil,
  "the category shows a loading state until its page lands")

gmcp.Char.Journal.List = {
  category = "books", page = 1, page_size = 30, total = 2,
  entries = {
    { id = 12, index = 1, kind = "book", title = "The Dark Forest Vol. 1",
      summary = "Field notes from beyond the willow's protection.", source = "",
      room_title = "A Mossy Hollow", zone = "Dark Willowdale Forest",
      added_at = 1771200000, is_book = true, available = true },
    { id = 4, index = 2, kind = "book", title = "", summary = "", source = "",
      room_title = "", zone = "", added_at = 1771100000, is_book = true, available = false },
  },
}
-- Mudlet raises an event for EVERY path segment of a GMCP key, so a List
-- arrival also fires gmcp.Char.Journal. Drive it exactly as Mudlet would.
raiseEvent("gmcp.Char.Journal", "gmcp.Char.Journal.List")
raiseEvent("gmcp.Char.Journal.List", "gmcp.Char.Journal.List")
local pjRows = joined(pjournal)
check(pjRows:find("The Dark Forest Vol. 1", 1, true) ~= nil, "the page's headers render")
check(pjRows:find("[no longer in the world]", 1, true) ~= nil,
  "an entry whose source left the world renders our stub")
check(#H.gmcpSent == requestsBefore + 1,
  "a List arrival does not re-request the list (the parent-event guard)")

-- A row title sends the real command, built from INDEX (never the cached id).
findLink(pjournal.content, "The Dark Forest").cb()
check(H.sent[#H.sent] == "journal books 1",
  "a row title sends journal <category> <index>")

-- Expanding a row pulls its content by STABLE id.
findByHint(pjournal.content, "Expand The Dark Forest").cb()
check(H.gmcpSent[#H.gmcpSent]:find('Char.Journal.Entry {"id":12}', 1, true) ~= nil,
  "expanding a row requests the entry by its stable id")
local pendingBefore = #H.gmcpSent
mdw.refreshWidgetContent(pjournal)
check(#H.gmcpSent == pendingBefore, "repaints do not re-request an in-flight entry")

-- Books arrive whole as a JSON document and are paginated client-side; prose
-- carries \n as two literal characters that must become real breaks.
gmcp.Char.Journal.Entry = {
  id = 12, index = 1, kind = "book", title = "The Dark Forest Vol. 1",
  summary = "Field notes from beyond the willow's protection.", source = "Fintan",
  room_title = "A Mossy Hollow", zone = "Dark Willowdale Forest",
  added_at = 1771200000, is_book = true, available = true, category = "books",
  content = '{"title":"Beyond the Willow","pages":["Day 1.\\nThe canopy closes.","Day 2. Tracks."]}',
}
raiseEvent("gmcp.Char.Journal", "gmcp.Char.Journal.Entry")
raiseEvent("gmcp.Char.Journal.Entry", "gmcp.Char.Journal.Entry")
-- Whitespace-flattened: provenance lines wider than the dock wrap, and these
-- checks are about content (the indent behaviour is asserted in 7a).
local pjEntry = joined(pjournal):gsub("<[%d,]+>", ""):gsub("</?[biruso]>", ""):gsub("%s+", " ")
check(pjEntry:find("Beyond the Willow", 1, true) ~= nil, "the book's own title renders")
check(pjEntry:find("page 1 of 2", 1, true) ~= nil, "a book is paginated client-side")
check(pjEntry:find("Day 1.", 1, true) and pjEntry:find("The canopy closes.", 1, true)
  and not pjEntry:find("\\n", 1, true),
  "the literal \\n in prose becomes a real line break")
check(pjEntry:find("Day 2. Tracks.", 1, true) == nil, "only the current book page shows")
check(pjEntry:find("Heard from Fintan", 1, true)
  and pjEntry:find("Found in A Mossy Hollow (Dark Willowdale Forest)", 1, true),
  "the entry's provenance lines render")
findLink(pjournal.content, "next page").cb()
check(joined(pjournal):find("Day 2. Tracks.", 1, true) ~= nil, "the book pager turns the page")

-- A counts push means "re-request the category you are showing", and it must
-- drop the entry cache with it (content can have been rewritten).
local beforeCounts = #H.gmcpSent
raiseEvent("gmcp.Char.Journal", "gmcp.Char.Journal")
local afterCounts = table.concat(H.gmcpSent, "|", beforeCounts + 1, #H.gmcpSent)
check(afterCounts:find('Char.Journal.List {"category":"books","page":1}', 1, true) ~= nil,
  "a counts push re-requests the open category")
check(afterCounts:find('Char.Journal.Entry {"id":12}', 1, true) ~= nil,
  "a counts push refetches the expanded entry too (its text can be rewritten)")

-- Back to the front page, and a character switch clears the whole widget.
findLink(pjournal.content, "back").cb()
check(joined(pjournal):find("Total", 1, true) ~= nil, "the back link returns to the categories")
mdwui.state.pjCategory = "books"
gmcp.Char.Info.name = "Someone Else"
raiseEvent("gmcp.Char.Info")
check(mdwui.state.pjCategory == nil and next(mdwui.state.pjEntries) == nil,
  "a character switch clears the player journal's ids and caches")
gmcp.Char.Info.name = "Morquin"
raiseEvent("gmcp.Char.Info")

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

-- 10. Numpad walking (web client input.js codeShortcuts). It ships as the
-- package's own native key folder, so the checks are on the JSON Mudlet
-- installs and on the folder's enabled state - not on temp keys. NumLock-on
-- codes ONLY: macOS stamps the Keypad modifier on the main keyboard's arrow
-- keys too, so a NumLock-off twin would walk on every arrow press.
check(mdwui.numpadWalking(), "numpad walking defaults on, as in the web client")
check(H.nativeKeys[mdwui.config.numpadKeyFolder] ~= nil,
  "config names the native key folder that keys.json ships")
local WEB_KEYPAD = {
  ["keypad+1"] = "southwest", ["keypad+2"] = "south", ["keypad+3"] = "southeast",
  ["keypad+4"] = "west", ["keypad+5"] = "look", ["keypad+6"] = "east",
  ["keypad+7"] = "northwest", ["keypad+8"] = "north", ["keypad+9"] = "northeast",
  ["keypad+minus"] = "up", ["keypad+plus"] = "down",
}
local keysMatch = (#numpadKeyDefs == 11)
for _, def in ipairs(numpadKeyDefs) do
  if WEB_KEYPAD[def.keys] ~= def.command or def.isActive ~= "yes"
    or def.isFolder ~= "no" or def.script ~= "" then
    keysMatch = false
  end
end
check(keysMatch, "keys.json binds keypad 1-9, minus and plus to the web client's codeShortcuts")
local NAV_TWINS = { up = true, down = true, left = true, right = true, home = true,
  ["end"] = true, pgup = true, pgdn = true, clear = true }
local noTwins = true
for _, def in ipairs(numpadKeyDefs) do
  for part in def.keys:gmatch("[^%+]+") do
    if NAV_TWINS[part] then noTwins = false end
  end
end
check(noTwins, "no NumLock-off twins: macOS stamps the keypad modifier on the arrow keys, "
  .. "so keypad+up would walk on every arrow press")
check(H.nativeKeys["Numpad Walking"] == true, "the native folder is enabled at build")
mdwui.buildUI()
H.flushTimers()
check(H.nativeKeys["Numpad Walking"] == true, "a rebuild re-applies the folder state")

-- Off hands the keypad back to typing numbers, which means DISABLING the
-- folder: a matched key eats the press whatever its script does.
mdwui.setNumpadWalking(false)
check(H.nativeKeys["Numpad Walking"] == false,
  "turning numpad walking off disables the folder - a disabled key lets the digit "
  .. "through to the command line")
check(mdw.gameSettings[mdwui.packageName].keys.numpad == false,
  "the choice lands in MDW's game settings (persisted with the layout)")
check(mdwui.toggleNumpadWalking() == true and H.nativeKeys["Numpad Walking"] == true,
  "toggling back on enables it again")

-- 10b. Keyboard control: the `ui` command (Commands.lua). One
-- dispatcher serves the shipped alias and this suite, so driving
-- mdwui.command directly is exactly what the alias runs.
-- Everything it says goes to the MAIN console, which the stub captures.
local function uiRun(text)
  H.main._echoed, H.main._links = {}, {}
  mdwui.command(text)
  return table.concat(H.main._echoed)
end
local function uiLink(pattern)
  for _, link in ipairs(H.main._links) do
    if link.text:find(pattern, 1, true) then return link end
  end
  return nil
end

local sentBeforeUi = #H.sent
local overview = uiRun("")
check(overview:find("Welcome to the WillowdaleMUD UI", 1, true) ~= nil,
  "bare ui opens with the welcome banner")
-- The placeholders survive the echo: cecho hands a tag it does not recognise
-- straight to the text stream (Mudlet's _Echos.Process), so the overview can
-- spell an argument the same way the README does. The rows drop the `ui`
-- itself - the game's config screen lists bare setting names, and the footer
-- says the word once.
check(overview:find("show <widget>", 1, true) ~= nil
  and overview:find("journal", 1, true) ~= nil
  and overview:find("refresh", 1, true) ~= nil,
  "the overview lists every command, angle brackets intact")
check(overview:find(mdwui.version, 1, true) ~= nil and overview:find(mdw.version, 1, true) ~= nil
  and overview:find("Mapper 9.9.9", 1, true) ~= nil,
  "the overview reads all three versions through the exposure convention")
-- Every command line in the overview is a link running that command, which is
-- the only way a mouse-free player discovers the surface.
local themeLink = uiLink("theme")
H.main._echoed = {}
themeLink.cb()
check(table.concat(H.main._echoed):find("Themes:", 1, true) ~= nil,
  "an overview link runs its own command")

-- The screen IS the settings table: three columns, the on/off rows first, so
-- "what is on right now" is on the screen a player opens first. uiRun hands
-- back the RAW cecho text, so the layout checks strip the colour tags (which
-- takes the literal <px>/<size> placeholders with them) while the colour
-- checks read the raw copy.
local ovPlain = (overview:gsub("<[%w_]+>", ""))
check(ovPlain:find("Command:%s+Value:%s+Options:") ~= nil,
  "the overview prints the Command/Value/Options header")
local atToggles, atLayout = ovPlain:find("On/off:", 1, true), ovPlain:find("Layout:", 1, true)
local atQuests = ovPlain:find("Quests and Journal widget:", 1, true)
check(atToggles ~= nil and atLayout ~= nil and atQuests ~= nil
  and atToggles < atLayout and atLayout < atQuests,
  "on/off toggles come first, then the sections")
check(ovPlain:find("prompt vitals%s+off%s+on|off") ~= nil
  and ovPlain:find("numpad%s+on%s+on|off") ~= nil
  and ovPlain:find("sidebar left%s+on%s+on|off") ~= nil,
  "each toggle row carries its live value and its options")
check(ovPlain:find("width left%s+%d+") ~= nil
  and ovPlain:find("theme%s+" .. mdw.config.theme) ~= nil
  and ovPlain:find("font main%s+%d+") ~= nil,
  "the layout and look rows read MDW's live state")
check(ovPlain:find("comm%s+" .. mdw.widgets["Comm"]:getActiveTab()) ~= nil,
  "a widget's own state (the Comm tab) is a row too")
check(overview:find("<green>on", 1, true) ~= nil and overview:find("<firebrick>off", 1, true) ~= nil,
  "on green, off red, as the game's config table")
-- The palette the ui command may use, VERIFIED against Mudlet's color_table in
-- GUIUtils.lua: a name missing there prints literally ("<dark_gray>on|off"
-- once did), and the stub's cecho accepts anything - so add a name here only
-- after checking the real table. The guard holds every tag the overview emits
-- to this list or to the argument placeholders it spells out on purpose.
local UI_COLOURS = { sky_blue = true, cyan = true, grey = true, white = true, gold = true,
  green = true, firebrick = true, dim_gray = true, light_slate_gray = true, yellow = true,
  YellowGreen = true, DodgerBlue = true, OliveDrab = true }
local PLACEHOLDERS = { widget = true, other = true, px = true, n = true, size = true, tab = true,
  id = true, category = true, page = true, value = true, command = true,
  what = true, path = true, name = true }
local strayTag
for tag in overview:gmatch("<([%w_]+)>") do
  if not (UI_COLOURS[tag] or PLACEHOLDERS[tag]) then strayTag = tag end
end
check(strayTag == nil, "every tag the overview emits is a Mudlet colour or a spelled-out placeholder"
  .. (strayTag and (" (stray: " .. strayTag .. ")") or ""))
-- 80 columns is what the table is written for, and the Options column wraps to
-- keep it. Measured on a copy stripped of the PALETTE tags only: <widget> and
-- friends are unrecognised tags that really do print, so they count.
local ovWide = (overview:gsub("<([%w_]+)>", function(tag) return UI_COLOURS[tag] and "" or nil end))
local widest, inTable = 0, false
for text in (ovWide .. "\n"):gmatch("([^\n]*)\n") do
  if text:find("^Command:") then inTable = true end
  -- the vocabulary line ("Widgets: affects(aff) ...") ends the table; the
  -- section title above it is the bare word, so the space tells them apart
  if text:find("^Widgets: ") then inTable = false end
  if inTable and #text > widest then widest = #text end
end
check(widest <= 80, "every table line fits 80 columns (explanations wrap), widest is " .. widest)
check(ovPlain:find("\n" .. string.rep(" ", 39) .. "%S") ~= nil,
  "a long explanation continues on a second line under the Options column")

-- Clicking a row is how a mouse-only player changes a setting, so a toggle's
-- line has to flip it - the bare form's contract.
local numpadLink = uiLink("numpad")
numpadLink.cb()
check(mdwui.numpadWalking() == false, "clicking a toggle row flips it")
uiRun("numpad on")
check(mdwui.numpadWalking() == true, "and back on again")

local unknownOut = uiRun("wibble")
check(unknownOut:find("[ UI - ", 1, true) ~= nil and unknownOut:find("Unknown command", 1, true) ~= nil,
  "an unknown command is named, tagged like MDW's own messages")
check(uiRun("show quets"):find("No widget matches", 1, true) ~= nil, "an unknown widget is named")
check(uiRun("show c"):find("Character", 1, true) ~= nil,
  "an ambiguous widget prefix lists the candidates by title")
-- The server has no `ui` command; half-shadowing a future one would be worse
-- than saying "unknown", so nothing typed here may reach the game.
check(#H.sent == sentBeforeUi, "no ui input is ever forwarded to the game")

uiRun("hide quests")
check(mdw.widgets["Quests"].stackId == nil
  and mdw.widgets["Quests"]._lastStackId == "MDWUI_Comms", "ui hide closes the widget's tab")
uiRun("show quests")
check(mdw.widgets["Quests"].stackId == "MDWUI_Comms"
  and mdw.widgets["MDWUI_Comms"].activeMember == "Quests",
  "ui show puts it back in its old group and fronts it")
uiRun("toggle quests")
check(mdw.widgets["Quests"].stackId == nil, "ui toggle hides a shown widget")
uiRun("toggle quests")
check(mdw.widgets["Quests"].stackId == "MDWUI_Comms", "and shows a hidden one")
uiRun("focus comm")
check(mdw.widgets["MDWUI_Comms"].activeMember == "Comm" and mdwui.state.focusWidget == "Comm",
  "ui focus fronts the tab and records the focused widget")
uiRun("show eq")
check(mdw.widgets["MDWUI_Items"].activeMember == "Equipment", "the eq synonym resolves")
uiRun("show inv")
check(mdw.widgets["MDWUI_Items"].activeMember == "Inventory", "and inv")
uiRun("sh que")
check(mdw.widgets["MDWUI_Comms"].activeMember == "Quests",
  "a prefix subcommand and a prefix widget name both resolve")
check(uiRun("list"):find("Left dock", 1, true) ~= nil and uiRun("list"):find("Sidebars", 1, true) ~= nil,
  "ui list reports docks and chrome")
-- The old Willowdale UI's words for two of these are kept as aliases, so a
-- returning player's fingers still land somewhere.
check(uiRun("containers"):find("Layout:", 1, true) ~= nil,
  "ui containers is ui list under its old name")
check(uiRun("color"):find("Themes:", 1, true) ~= nil, "ui color is ui theme under its old name")
check(uiRun("help show"):find("ui show <widget>", 1, true) ~= nil,
  "ui help prints one command's usage, brackets and all")

-- Refresh re-asks the server for data it already pushed once. Form A requests
-- (guide 3): the package name IS the node, the body an empty object.
local sentBeforeData = #H.sent
uiRun("refresh")
check(H.gmcpSent[#H.gmcpSent] == "GMCP SendFullPayload",
  "bare ui refresh re-requests the whole payload")
uiRun("refresh equipment")
check(H.gmcpSent[#H.gmcpSent] == "Char.Inventory.Worn {}",
  "a named part goes out as one Form A node request")
local beforeInventory = #H.gmcpSent
uiRun("refresh inv")
check(table.concat(H.gmcpSent, "|", beforeInventory + 1, #H.gmcpSent)
  == "Char.Inventory.Backpack.Items {}|Char.Inventory.Backpack.Summary {}",
  "a prefix resolves and pulls every node that widget feeds on")
local beforeUnknownPart = #H.gmcpSent
check(uiRun("refresh nosuch"):find("Nothing called", 1, true) ~= nil
  and #H.gmcpSent == beforeUnknownPart,
  "an unknown part names the ones that exist and asks for nothing")

-- Diagnostics: what a bug report needs, and the payload behind a widget.
local debugOut = uiRun("debug")
check(debugOut:find(mdw.layoutFile, 1, true) ~= nil
  and debugOut:find("MDW " .. mdw.version, 1, true) ~= nil,
  "ui debug reports the layout file and the versions in play")
check(uiRun("debug gmcp Char.Vitals"):find("health", 1, true) ~= nil,
  "ui debug gmcp dumps the subtree at a dotted path")
check(uiRun("debug gmcp No.Such"):find("No GMCP data", 1, true) ~= nil,
  "a path with nothing behind it says so instead of dumping everything")
check(#H.sent == sentBeforeData, "refresh and debug speak GMCP, never the command line")

-- Comm is a tabbed widget: the tab is the thing the keyboard needs to reach.
uiRun("comm tells")
check(mdw.widgets["Comm"]:getActiveTab() == "Tells", "ui comm switches the channel tab")
check(uiRun("comm"):find("Tells*", 1, true) ~= nil, "bare ui comm marks the tab showing")
uiRun("comm clear")
check(#mdw.widgets["Comm"].tabsByName["Tells"]._buffer == 0, "ui comm clear empties that tab")
uiRun("comm all")

-- Chrome: dock width and row height. The default layout still stands here, so
-- MDWUI_Char is the auto-filled bottom row of the left dock.
uiRun("width left 300")
check(mdw.config.leftDockWidth == 300, "ui width sets the dock width")
uiRun("width left +20")
check(mdw.config.leftDockWidth == 320, "a relative width applies to the current one")
uiRun("height affects 200")
check(mdw.widgets["MDWUI_Status"].container:get_height() == 200,
  "ui height resizes the row the widget sits in")
local charRowHeight = mdw.widgets["MDWUI_Char"].container:get_height()
check(uiRun("height character 100"):find("fills the bottom", 1, true) ~= nil
  and mdw.widgets["MDWUI_Char"].container:get_height() == charRowHeight,
  "an auto-fill row refuses a height and says what to resize instead")

-- Fonts and theme. A setter must never open the Font Size menu - that side
-- effect belongs to the menu layer (MDW's own check 2 guards the other half).
uiRun("font main 13")
check(mdw.config.mainFontSize == 13 and mdw.menus.layout == false,
  "ui font sets a size without opening the Font Size menu")
local questFontSize = mdw.getFontSizes().widgets["Quests"]
uiRun("font quests +2")
check(mdw.getFontSizes().widgets["Quests"] == questFontSize + 2,
  "a relative widget font size applies to its effective size")
check(uiRun("font"):find("main 13", 1, true) ~= nil, "bare ui font lists every size")

-- The typeface arrived in MDW 0.5 (mdw.setFontFamily). This package guards
-- every MDW call on existence instead of pinning a version, so the suite has
-- to hold against BOTH sides of that guard - which is also what a player on
-- either MDW gets.
if mdw.setFontFamily then
  local preferred = mdw.getFontFamily()
  check(uiRun("font family"):find(preferred, 1, true) ~= nil,
    "ui font family names the typeface in use")
  check(uiRun("font family Bitstream Vera Sans Mono"):find("Bitstream Vera Sans Mono", 1, true) ~= nil
    and select(2, mdw.getFontFamily()) == "Bitstream Vera Sans Mono",
    "and sets it, a name with spaces and all")
  check(uiRun("font family Nonesuch Mono"):find("installed", 1, true) ~= nil,
    "a font nobody has is answered, never sent to the server")
  uiRun("font family " .. preferred) -- leave the session as it was found
else
  check(uiRun("font family Whatever"):find("newer MDW", 1, true) ~= nil,
    "under an MDW without it, the typeface verb says so rather than erroring")
end
uiRun("theme ruby")
check(mdw.config.theme == "ruby", "ui theme switches theme")
uiRun("theme next")
check(mdw.config.theme ~= "ruby", "ui theme next cycles")
check(uiRun("theme"):find("*", 1, true) ~= nil, "bare ui theme marks the current one")
check(uiRun("theme nosuch"):find("No theme named", 1, true) ~= nil, "an unknown theme is refused")

-- The two settings menus, by name. Same setters the vertical-ellipsis rows
-- call, so the keyboard and the mouse cannot drift apart.
uiRun("prompt vitals on")
check(mdw.gameSettings[mdwui.packageName].promptBar.vitals == true
  and joined(mdw.promptBar):find("HP:80 AE:45>", 1, true) ~= nil,
  "ui prompt turns a bar element on and repaints the bar")
check((uiRun(""):gsub("<[%w_]+>", "")):find("prompt vitals%s+on%s+on|off") ~= nil,
  "the overview follows a setting change")
uiRun("prompt vitals off")
check(uiRun("prompt"):find("worth on", 1, true) ~= nil, "bare ui prompt lists the toggles")
uiRun("combat ae on")
check(mdw.widgets["Combat"]._rows["ae"] ~= nil, "ui combat turns a widget section on")
uiRun("combat ae off")
uiRun("prompt bar off")
check(mdw.visibility.promptBar == false, "ui prompt bar hides the bar itself")
uiRun("prompt bar on")
check(mdw.visibility.promptBar == true, "and brings it back")

-- ui music writes through the same silent node the widget does (guide 5.16),
-- so the keyboard and the mouse cannot describe the audio differently - and
-- the keyboard surface still speaks, since the player typed a question.
-- Its own do block, like section 5b: 200 locals per chunk.
do
local function lastGmcp() return H.gmcpSent[#H.gmcpSent] end
local sentBeforeMusicUi = #H.sent
local musicState = (uiRun("music"):gsub("<[%w_]+>", ""))
check(musicState:find("Music: playlist mode, playing Air.", 1, true) ~= nil
  and musicState:find("repeat off  shuffle off", 1, true) ~= nil
  and musicState:find("Playlist Air, Ballad", 1, true) ~= nil
  and musicState:find("music 75  combat 75  movement 60", 1, true) ~= nil,
  "bare ui music reports the mode, the track, the flags, the playlist and the levels")
uiRun("music repeat on")
check(lastGmcp() == 'Char.Audio.Set {"repeat":true}', "ui music repeat writes the flag")
uiRun("music shuffle")
check(lastGmcp() == 'Char.Audio.Set {"shuffle":true}',
  "a missing on/off toggles what Char.Audio says is stored")
uiRun("music mode server")
check(lastGmcp() == 'Char.Audio.Set {"mode":"server"}', "ui music mode switches who picks")
uiRun("music next")
check(lastGmcp() == 'Char.Audio.Set {"next":true}', "ui music next skips a track")
uiRun("music stop")
check(lastGmcp() == 'Char.Audio.Set {"track":""}', "ui music stop empties the track")
uiRun("music volume music 20")
check(lastGmcp() == 'Char.Audio.Set {"music_volume":20}', "the music level has its own field")
uiRun("mus vol c 40")
check(lastGmcp() == 'Char.Audio.Set {"volumes":{"combat":40}}',
  "a category level resolves by prefix all the way down")
-- Bad input answers and writes nothing: this surface never guesses, and it
-- never forwards to the game either.
local gmcpBeforeBadMusic = #H.gmcpSent
check(uiRun("music wibble"):find("No music setting", 1, true) ~= nil,
  "an unknown music setting is named")
check(uiRun("music s"):find("shuffle, stop", 1, true) ~= nil,
  "an ambiguous one lists the candidates instead of guessing")
check(uiRun("music repeat maybe"):find("Say on or off", 1, true) ~= nil,
  "a flag needs on or off")
check(uiRun("music mode wibble"):find("No music mode", 1, true) ~= nil,
  "an unknown mode is refused")
check(uiRun("music mode"):find("Which mode?", 1, true) ~= nil, "and a missing one asks")
check(uiRun("music volume"):find("Which level?", 1, true) ~= nil,
  "a volume with no name asks which")
check(uiRun("music volume nosuch 40"):find("No volume called", 1, true) ~= nil,
  "an unknown level name is named")
check(uiRun("music volume music 400"):find("level from 0 to 100", 1, true) ~= nil,
  "and a level outside 0-100 is refused")
check(#H.gmcpSent == gmcpBeforeBadMusic, "none of that wrote anything")
check(#H.sent == sentBeforeMusicUi, "and ui music never reaches the command line")
check((uiRun(""):gsub("<[%w_]+>", "")):find("music%s+playlist%s+repeat|shuffle") ~= nil,
  "the overview carries a music row reading the live mode")
check(uiRun("help music"):find("ui music [repeat|shuffle", 1, true) ~= nil,
  "ui help music prints its usage")
end

-- Quests and journal: the in-widget navigation the chevrons and crumbs do.
uiRun("quest 8")
check(mdwui.state.questDetailId == 8 and mdw.widgets["MDWUI_Comms"].activeMember == "Quests",
  "ui quest opens one quest's detail view and fronts the widget")
uiRun("quest back")
check(mdwui.state.questDetailId == nil, "ui quest back returns to the list")
uiRun("quest expand 8")
check(joined(mdw.widgets["Quests"]):find("Wolves slain", 1, true) ~= nil,
  "ui quest expand opens the objective lines")
uiRun("quest collapse 8")
check(joined(mdw.widgets["Quests"]):find("Wolves slain", 1, true) == nil, "and collapse folds them")

uiRun("journal books")
check(mdwui.state.pjCategory == "books"
  and H.gmcpSent[#H.gmcpSent]:find('Char.Journal.List {"category":"books","page":1}', 1, true) ~= nil,
  "ui journal opens a category and pulls its first page")
uiRun("journal page 2")
check(mdwui.state.pjPage == 2
  and H.gmcpSent[#H.gmcpSent]:find('"category":"books","page":2', 1, true) ~= nil,
  "ui journal page turns the page and requests it")
uiRun("journal page 1")
uiRun("journal open 1")
check(mdwui.state.pjExpanded["12"] == true, "ui journal open expands the row carrying that [index]")
uiRun("journal close 1")
check(mdwui.state.pjExpanded["12"] == nil, "and close folds it")
check(uiRun("journal b"):find("Did you mean", 1, true) ~= nil,
  "an ambiguous journal word (back, book, books) asks instead of guessing")
uiRun("journal back")
check(mdwui.state.pjCategory == nil, "ui journal back returns to the categories")
uiRun("journal quests")
uiRun("journal status ready")
check(mdwui.state.journalFilters.status == "ready", "ui journal status sets the quest filter")
check(uiRun("journal status nosuch"):find("Status is one of", 1, true) ~= nil,
  "an unknown status names the valid ones")
uiRun("journal status all")
uiRun("journal zone current")
check(mdwui.state.journalFilters.zone == "current", "ui journal zone sets the zone filter")
uiRun("journal zone all")
uiRun("journal back")

-- Scroll and read: the no-mouse half. Scrolling is Mudlet 4.17+, and
-- reading prints the widget's text where a reader can actually reach it.
uiRun("scroll comm up 5")
local commWidget = mdw.widgets["Comm"]
local lastScroll = H.scrolls[#H.scrolls]
check(lastScroll.fn == "scrollUp" and lastScroll.arg == 5
  and lastScroll.window == commWidget.tabObjects[commWidget.activeTabIndex].console.name,
  "ui scroll scrolls the named widget's active tab")
uiRun("focus affects")
uiRun("scroll up")
lastScroll = H.scrolls[#H.scrolls]
check(lastScroll.window == mdw.widgets["Affects"].content.name and lastScroll.arg == 10,
  "without a widget it scrolls the focused one, ten lines by default")
uiRun("scroll bottom")
check(H.scrolls[#H.scrolls].fn == "scrollTo" and H.scrolls[#H.scrolls].arg == nil,
  "bottom scrolls to the end of the buffer")
check(uiRun("read affects"):find("Sanctuary", 1, true) ~= nil,
  "ui read prints the widget's text to the main console")

-- Placement by name. The mouse drags tabs between groups; these are the same
-- moves spoken.
uiRun("dock affects right")
check(mdw.widgets[mdw.widgets["Affects"].stackId].docked == "right",
  "ui dock moves a widget into its own group on the other side")
uiRun("group affects keyring")
check(mdw.widgets["Affects"].stackId == mdw.widgets["Keyring"].stackId,
  "ui group puts it back as a tab of another widget's group")
uiRun("float map")
check(mdw.widgets[mdw.widgets["Map"].stackId].docked == nil, "ui float undocks a group")
uiRun("dock map right")
check(mdw.widgets[mdw.widgets["Map"].stackId].docked == "right", "ui dock docks it again")
uiRun("ungroup combat")
local combatGroup = mdw.widgets[mdw.widgets["Combat"].stackId]
check(combatGroup ~= nil and combatGroup.name ~= "MDWUI_Char" and combatGroup.docked == "left",
  "ui ungroup gives a tab its own group on the same side")
check(uiRun("ungroup combat"):find("already alone", 1, true) ~= nil,
  "ungrouping a sole member says so")
uiRun("group combat character")
check(mdw.widgets["Combat"].stackId == mdw.widgets["Character"].stackId, "ui group restores it")

-- A whole sidebar, and what a widget stowed with it may say. Last of the
-- layout checks because MDW returns stowed groups FLOATING when the sidebar
-- comes back (a keyboard reveal is the one path that re-homes them); the
-- reset below puts the docks back.
uiRun("sidebar left off")
check(mdw.visibility.leftSidebar == false, "ui sidebar left off hides the dock")
check(uiRun("show character"):find("left sidebar is off", 1, true) ~= nil,
  "revealing a widget stowed with its sidebar names the fix instead of forcing it")
uiRun("left on")
check(mdw.visibility.leftSidebar == true, "the ui left shorthand brings it back")

-- Reset is two-step on purpose: it throws the whole arrangement away.
local widthBeforeReset = mdw.config.leftDockWidth
check(uiRun("reset"):find("ui reset confirm", 1, true) ~= nil, "ui reset arms and says what it will do")
check(mdw.config.leftDockWidth == widthBeforeReset, "arming changes nothing")
uiRun("reset confirm")
H.flushTimers()
check(mdw.config.leftDockWidth == mdw.layoutDefaults.leftDockWidth
  and mdw.config.theme == mdw.layoutDefaults.theme
  and mdw.visibility.leftSidebar and mdw.visibility.rightSidebar and mdw.visibility.promptBar,
  "ui reset confirm restores the factory layout")
check(mdw.widgets["Combat"] ~= nil and mdw.widgets["Comm"].tabsByName["Global"] ~= nil
  and mdw.widgets["Character"].stackId == "MDWUI_Char", "and rebuilds our widgets and groups")
check(mdw.gameSettings[mdwui.packageName].promptBar.enemy == true,
  "a plain reset keeps this package's own settings")
uiRun("reset all")
uiRun("reset all confirm")
H.flushTimers()
check(mdw.gameSettings[mdwui.packageName].promptBar.enemy == false,
  "ui reset all wipes them back to the defaults")
uiRun("prompt enemy on") -- restore it: the sections below expect that gauge
uiRun("rebuild")
H.flushTimers()
check(mdw.isSetUp and mdw.widgets["Journal"] ~= nil, "ui rebuild rebuilds the UI in place")

-- The numpad folder through the command surface: `ui numpad` runs the same
-- applyNumpadKeys pass a build does, so the toggle and the folder agree.
uiRun("numpad off")
check(mdwui.numpadWalking() == false and H.nativeKeys["Numpad Walking"] == false,
  "ui numpad off disables the keypad folder")
uiRun("numpad on")
check(mdwui.numpadWalking() == true and H.nativeKeys["Numpad Walking"] == true,
  "ui numpad on enables it")
H.main._echoed = {}
mdwui.buildUI()
H.flushTimers()
check(table.concat(H.main._echoed):find("Type ui for", 1, true) == nil,
  "the one-time hint does not repeat on later builds")

-- 10c. The self-updater (Update.lua). The feed is the package's OWN
-- CHANGELOG.md read from GitHub - no manifest, no URLs in the data - and the
-- download URL is built from the release contract in Config. The stub
-- records downloads instead of performing them, so every step here is driven
-- by writing the file Mudlet would have written and raising the event Mudlet
-- would have raised.
-- The fixture's versions are DERIVED from the installed one, never literals:
-- tools/release.sh bumps mdwui.version and then runs this suite, so a feed
-- pinned to "0.9.0" would quietly stop being newer than the package the day a
-- release passed it, and every check below would fail on the release that did
-- it. Majors above the installed one can never collide.
local function aheadBy(steps)
  return ((tonumber(mdwui.version:match("^(%d+)")) or 0) + steps) .. ".0.0"
end
local V_LATEST, V_NEXT, V_INSTALLED = aheadBy(2), aheadBy(1), mdwui.version
-- The feed is the game server's releases.json, newest entry first - the same
-- shape the mapper package ships against. It is JSON now, not the changelog:
-- the server copies releases/releases.json out of this repo on every push to
-- main, so the file the player reads is generated, never hand-edited.
local function feedJson(entries)
  local out = {}
  for _, e in ipairs(entries) do
    local changes = {}
    for _, c in ipairs(e[3]) do changes[#changes + 1] = '"' .. c .. '"' end
    -- e[4], when given, is the MDW that release requires. It travels in the
    -- feed because the pin lives inside the package being installed.
    local mdwField = e[4] and string.format('"mdw":"%s",', e[4]) or ""
    out[#out + 1] = string.format('{"version":"%s","released":"%s",%s"changes":[%s]}',
      e[1], e[2], mdwField, table.concat(changes, ","))
  end
  return "[" .. table.concat(out, ",") .. "]"
end
local FEED = feedJson({
  { V_LATEST, "2026-09-01", { "A **big** new thing with `code` in it", "A bug" } },
  { V_NEXT, "2026-08-22", { "Something else" } },
  { V_INSTALLED, "2026-08-01", { "The first release" } },
})

local releases = mdwui.parseReleases(FEED)
check(#releases == 3 and releases[1].version == V_LATEST and releases[1].date == "2026-09-01"
  and releases[3].version == V_INSTALLED, "the feed parser reads releases newest-first, with dates")
check(releases[1].notes[1].kind == "bullet"
  and releases[1].notes[1].text == "A big new thing with code in it",
  "changes become bullets, and inline markdown is stripped from the text")
-- Remote text arrives from a server that could be having a bad day. Every one
-- of these is skipped rather than thrown: an error inside the download handler
-- would cost the player the update path entirely.
check(#mdwui.parseReleases("") == 0, "an empty feed parses as no releases")
check(#mdwui.parseReleases("<html>404</html>") == 0, "an error page parses as no releases")
check(#mdwui.parseReleases('{"version":"9.0.0"}') == 0, "a feed that is not an array is refused")
check(#mdwui.parseReleases('[{"released":"2026-01-01","changes":["x"]}]') == 0,
  "an entry with no version is skipped")
check(#mdwui.parseReleases('[{"version":"9.9.9"}]') == 1,
  "an entry with no changes is still a release")
-- The MDW a release needs travels in the feed: minMdwVersion lives INSIDE the
-- package, so a running client cannot read the next version's requirement any
-- other way - and it has to know BEFORE installing, because a package
-- installed against too old an MDW refuses to build.
local mdwFeed = mdwui.parseReleases('[{"version":"9.9.9","mdw":"1.2.3"}]')
check(mdwFeed[1].mdw == "1.2.3", "a release's MDW requirement is read from the feed")
check(mdwui.parseReleases('[{"version":"9.9.9"}]')[1].mdw == nil,
  "and an entry without one asks for nothing extra")
check(mdwui.parseReleases('[{"version":"9.9.9","mdw":7}]')[1].mdw == nil,
  "a wrong-typed requirement is dropped, not trusted")
local odd = mdwui.parseReleases('[{"version":"9.9.9","released":7,"changes":"nope"}]')
check(#odd == 1 and odd[1].date == nil and #odd[1].notes == 0,
  "wrong-typed fields are dropped, not trusted")
check(#mdwui.newerReleases(releases, V_LATEST) == 0, "nothing in the feed outranks the newest release")
check(#mdwui.newerReleases(releases, V_INSTALLED) == 2,
  "two releases are newer than the installed one (the same comparator, asked twice)")

-- WHEN the automatic check happens is the whole point of it. A build is
-- profile load, which on a live client is the connection banner, the username
-- prompt and the character list - so a check armed there printed its offer
-- straight through the one stretch of a session a player has to read. The
-- trigger is the first Char.Info instead (the server sends it once a
-- character is selected), and even that only ARMS a timer, so the game's own
-- login block finishes before anything of ours appears under it.
local downloadsBefore = #H.downloads
-- Back to a session that has not checked yet. updateBusyAt goes with the two
-- flags: the build-time check this suite has already driven is still counted
-- as in flight (its feed arrives further down), and the in-flight guard would
-- refuse everything below on that alone.
mdwui.state.updateCheckedThisSession, mdwui.state.updateCheckArmedAt = nil, nil
mdwui.state.updateBusyAt = nil
mdwui.buildUI()
H.flushTimers()
check(#H.downloads == downloadsBefore, "building the UI asks the server for nothing at all")
raiseEvent("gmcp.Char.Info")
check(#H.downloads == downloadsBefore,
  "and reaching the game only arms the check - it does not print over the login")
H.flushTimers()
check(#H.downloads == downloadsBefore + 1
  and H.downloads[#H.downloads].url == mdwui.releasesUrl,
  "the armed check then asks the server for releases.json")
-- One check per SESSION, not per Char.Info: the server pushes it again on a
-- level, a class change and every full-payload refresh.
raiseEvent("gmcp.Char.Info")
H.flushTimers()
check(#H.downloads == downloadsBefore + 1, "later Char.Info pushes do not re-check")
-- And a rebuild does not either - MDW runs buildUI on every setup.
mdwui.buildUI()
H.flushTimers()
check(#H.downloads == downloadsBefore + 1, "nor does a rebuild")
local feedPath = H.downloads[#H.downloads].path
local function writeFile(path, text)
  local fh = assert(io.open(path, "wb"))
  fh:write(text)
  fh:close()
end
local function fileText(path)
  local fh = io.open(path, "rb")
  if not fh then return nil end
  local text = fh:read("*a")
  fh:close()
  return text
end
--- Answer the fetch in flight with `text`, and hand back what it printed.
local function feed(text)
  writeFile(feedPath, text)
  H.main._echoed, H.main._links = {}, {}
  raiseEvent("sysDownloadDone", feedPath)
  return table.concat(H.main._echoed)
end

local offer = feed(FEED)
check(offer:find(mdwui.packageName, 1, true) ~= nil and offer:find(V_INSTALLED, 1, true) ~= nil
  and offer:find("->", 1, true) ~= nil and offer:find(V_LATEST, 1, true) ~= nil,
  "the offer names the package, the installed version and the one available")
check(offer:find("2026-09-01", 1, true) ~= nil, "with the release date")
-- Only the NEWEST release's notes, however far behind the player is. Showing
-- every one of them is what turned an offer into a wall of changelog across
-- someone's login; the rest is one line pointing at `ui update notes`.
check(offer:find("A big new thing", 1, true) ~= nil,
  "and the newest release's notes")
check(offer:find("Something else", 1, true) == nil,
  "but NOT the notes of every older release behind it")
check(offer:find("and 1 earlier release", 1, true) ~= nil,
  "which is counted instead, with a pointer to the full list")
-- The offer prints the version and date in its own first line, so the notes
-- under it do not repeat the pair as a heading.
local _, headings = offer:gsub(V_LATEST, "")
check(headings == 1, "the newest version is named once, not once more as a heading")
check(offer:find("**", 1, true) == nil and offer:find("`", 1, true) == nil,
  "no raw markdown reaches the console")
-- Remote text: a bullet reading "<b>" must print, not paint.
local injected = feed(FEED:gsub("A bug", "<b>bold<r> and <green>green"))
-- "green>green" is the changelog's own "<green>green" with the bracket gone;
-- the tag the OFFER paints with is ours, further up the same string.
check(injected:find("bold", 1, true) ~= nil and injected:find("<b>", 1, true) == nil
  and injected:find("<r>", 1, true) == nil and injected:find("green>green", 1, true) ~= nil,
  "colour markup in the changelog is stripped, not obeyed")
local installLink = uiLink("[Install update now]")
check(installLink ~= nil, "the offer ends in a clickable install line")

-- The offer arrives unasked, between a room description and whatever the
-- player types next, so it needs room around it or it reads as part of one or
-- the other. A headline says what it is before any numbers, and blank lines
-- fence the block off - at both ends and between the notes and the call to
-- action. Asserted on the TEXT, with the colour tags stripped, so the shape of
-- the block is not pinned to the palette that paints it.
local plainOffer = (offer:gsub("<[^>]*>", ""))
check(plainOffer:find("A new " .. mdwui.packageName .. " is ready to install", 1, true) ~= nil,
  "an unasked-for offer leads with a headline saying what it is")
check(plainOffer:sub(1, 1) == "\n", "with a blank line above it")
check(plainOffer:find("\n\n[ UI - " .. mdwui.packageName, 1, true) ~= nil,
  "another between the headline and the version line")
check(plainOffer:find("\n\n[Install update now]", 1, true) ~= nil,
  "another between the notes and the call to action")
check(plainOffer:sub(-2) == "\n\n", "and one below the whole block")
-- The headline is the one line here that has to catch an eye already reading
-- something else. Its TAG must not move with it: the marker a player scans
-- back for is the same gold on every line the client prints.
local headline
for row in offer:gmatch("[^\n]+") do
  if row:find("A new ", 1, true) then headline = row end
end
check(headline ~= nil and headline:find("<magenta>A new ", 1, true) ~= nil,
  "the headline itself is magenta")
check(headline ~= nil and headline:find("<gold>[ UI - ", 1, true) == 1,
  "while its [ UI - ] tag stays gold, like every other line the client prints")
-- A player who TYPED the question is already looking at the answer: a headline
-- above it would be a third tagged line and the wall this spacing exists to
-- break up.
mdwui.state.updateBusyAt = nil
uiRun("update")
local typedOffer = feed(FEED)
check(typedOffer:find("is ready to install", 1, true) == nil,
  "but ui update skips the headline - the player is already looking")
check(typedOffer:find(V_LATEST, 1, true) ~= nil, "and still gets the offer itself")

-- `ui update notes`: the reading room the offer deliberately is not. It reads
-- the list the check already parsed, so the full history costs no second
-- download - the offer that sent the player here came off it seconds ago.
feed(FEED)
local downloadsBeforeNotes = #H.downloads
local notes = uiRun("update notes")
check(#H.downloads == downloadsBeforeNotes, "ui update notes asks the server for nothing")
check(notes:find("A big new thing", 1, true) ~= nil
  and notes:find("Something else", 1, true) ~= nil,
  "and prints every release newer than the installed one, not just the newest")
check(notes:find(V_LATEST, 1, true) ~= nil and notes:find(V_NEXT, 1, true) ~= nil,
  "each under its own version heading, which is what separates one from the next")
check(notes:find("The first release", 1, true) == nil,
  "and stops at the installed one - its own notes are not news")
check(notes:find("since " .. V_INSTALLED, 1, true) ~= nil,
  "the heading names the version being read forward from")
check(uiRun("update n"):find("A big new thing", 1, true) ~= nil,
  "prefix-matched like every other word in this surface")
-- Nothing on offer must clear the list, or one left over from before an
-- install would read as current.
mdwui.state.updateBusyAt = nil
mdwui.checkForUpdate(false)
feed(feedJson({ { mdwui.version, "2026-08-01", { "The first release" } } }))
check(uiRun("update notes"):find("run ui update first", 1, true) ~= nil,
  "and a check that found nothing leaves no stale notes behind")
check(uiRun("update sideways"):find("install or notes", 1, true) ~= nil,
  "an unknown word names both options rather than guessing")

-- Silence is the automatic check's default: only `ui update` answers when
-- there is nothing to install.
local SAME_FEED = feedJson({ { mdwui.version, "2026-08-01", { "The first release" } } })
mdwui.checkForUpdate(false)
check(feed(SAME_FEED) == "", "an automatic check with nothing to offer prints nothing at all")
check(uiRun("update"):find("Checking for a newer", 1, true) ~= nil,
  "ui update says it is asking")
check(uiRun("update"):find("already running", 1, true) ~= nil,
  "a second check while one is in flight is refused, not queued")
check(feed(SAME_FEED):find("You are on the latest version (" .. mdwui.version .. ")", 1, true) ~= nil,
  "and ui update answers when the installed version is the latest")

-- Back to an update pending, then take it. The download URL is FIXED - the
-- server keeps one copy at one path - so a feed cannot point the installer
-- anywhere, and the version it named cannot disagree with what arrives.
feed(FEED)
uiLink("[Install update now]").cb()
local assetUrl = H.downloads[#H.downloads].url
check(assetUrl == mdwui.packageUrl,
  "the install link downloads the package the server hosts, at its fixed path")

-- A package Mudlet would accept: zip magic, and past the size floor.
local PACKAGE_BYTES = "PK\003\004" .. string.rep("m", 20100)

-- MDW FIRST when the release needs a newer one. Installing the package first
-- leaves it unable to BUILD until the framework catches up - its gate refuses
-- and the player is left with no UI and a line of explanation, which is the
-- window a live client fell into. Asking first means the package lands on an
-- MDW that already satisfies it.
local orderVersion = mdw.version
mdw.version = "0.4.0" -- older than anything the feed below asks for
mdwui.state.updateBusyAt, mdwui.state.mdwFetchedFor, mdwui.state.mdwFile = nil, nil, nil
mdwui.checkForUpdate(true)
feed(feedJson({ { V_LATEST, "2026-09-01", { "needs a newer framework" }, "9.9.9" } }))
uiRun("update install")
local askedFor = H.downloads[#H.downloads].url
check(askedFor:find("MDW.mpackage", 1, true) ~= nil,
  "an update needing a newer MDW fetches MDW first, not the package")
check(askedFor:find("v9.9.9", 1, true) ~= nil,
  "and fetches the version the FEED named, not this package's own pin")
-- MDW lands, and the held-back update carries on by itself.
local mdwLanded = H.downloads[#H.downloads].path
writeFile(mdwLanded, PACKAGE_BYTES)
mdw.version = "9.9.9"
raiseEvent("sysDownloadDone", mdwLanded)
raiseEvent("sysInstallPackage", "MDW")
H.flushTimers()
check(H.downloads[#H.downloads].url == mdwui.packageUrl,
  "and once MDW is in, the package download resumes on its own")
-- Straight out of the event, not from a timer: MDW answers this same event by
-- re-running setup, and that teardown kills our timers - a deferred resume
-- would be destroyed before it could fire.
mdw.version = orderVersion
mdwui.state.updateBusyAt, mdwui.state.updateMdw = nil, nil

-- A GitHub error page is not a package: verification runs BEFORE anything is
-- uninstalled, because the running UI is the only copy the player has.
local uninstallsBefore = #H.uninstalled
local badPath = H.downloads[#H.downloads].path
writeFile(badPath, "<!DOCTYPE html>" .. string.rep("x", 30000))
H.main._echoed, H.main._links = {}, {}
raiseEvent("sysDownloadDone", badPath)
local rejected = table.concat(H.main._echoed)
check(rejected:find("not a Mudlet package", 1, true) ~= nil
  and rejected:find("Nothing was changed", 1, true) ~= nil,
  "a download that is not a zip is refused by its first two bytes")
check(#H.uninstalled == uninstallsBefore, "and NOTHING is uninstalled on a bad download")
check(io.exists(badPath) == false, "the bad file is removed")
mdwui.installUpdate()
writeFile(H.downloads[#H.downloads].path, "PK\003\004tiny")
H.main._echoed = {}
raiseEvent("sysDownloadDone", H.downloads[#H.downloads].path)
check(table.concat(H.main._echoed):find("only %d+ bytes") ~= nil
  and #H.uninstalled == uninstallsBefore, "a truncated download is refused by size, again with no swap")

-- Installed as a MODULE: Mudlet reloads a module from its own file, so the
-- verified download becomes that file - copied only after verification, or a
-- bad fetch would have destroyed the working copy on the way in.
local modulePath = H.homeDir .. "/mdwui-module-copy.mpackage"
writeFile(modulePath, "the previous module")
H.modulePaths[mdwui.packageName] = modulePath
mdwui.installUpdate()
local modDownload = H.downloads[#H.downloads].path
writeFile(modDownload, PACKAGE_BYTES)
raiseEvent("sysDownloadDone", modDownload)
check(H.reloaded[#H.reloaded] == mdwui.packageName and #H.uninstalled == uninstallsBefore,
  "a module install reloads the module instead of swapping the package")
check(fileText(modulePath) == PACKAGE_BYTES, "the verified download replaced the module file")
os.remove(modulePath)
H.modulePaths[mdwui.packageName] = nil

-- The offer's link is a mouse affordance, and this surface is a keyboard one:
-- a player who would rather not reach for the mouse needs a typed form, and
-- bare `ui update` only
-- re-checks. So the install has a typed form, prefix-matched like the rest.
local beforeTyped = #H.downloads
uiRun("update i")
check(#H.downloads == beforeTyped + 1 and H.downloads[#H.downloads].url == assetUrl,
  "ui update install starts the same download the offer's link does")
check(uiRun("update sideways"):find("Say install", 1, true) ~= nil,
  "and any other word is answered, never sent to the server")
-- Refused by size, which clears the in-flight guard without swapping anything.
writeFile(H.downloads[#H.downloads].path, "PK\003\004tiny")
raiseEvent("sysDownloadDone", H.downloads[#H.downloads].path)

-- A refused swap is known AT ONCE, in a context that still exists, instead of
-- being discovered twenty seconds later by a watchdog. "At once" is one tick,
-- not one call: the swap is armed on a tempTimer(0) so that installing a
-- package never registers handlers into the table Mudlet is walking to reach
-- this handler (see installDownloaded). Tested before the real swap below,
-- because a swap uninstalls this package - and with it the very handlers that
-- carry the next download event.
local realSwap = mdw.swapPackage
mdw.swapPackage = function() return false, "Mudlet refused the install" end
mdwui.installUpdate()
local refusedPath = H.downloads[#H.downloads].path
writeFile(refusedPath, PACKAGE_BYTES)
H.main._echoed, H.main._links = {}, {}
raiseEvent("sysDownloadDone", refusedPath)
H.flushTimers()
local watch = table.concat(H.main._echoed)
check(watch:find("Update failed", 1, true) ~= nil and watch:find("refused", 1, true) ~= nil,
  "a refused swap says so immediately, with the reason MDW gave")
check(watch:find(refusedPath, 1, true) ~= nil, "and hands the saved package back")
check(watch:find("firebrick", 1, true) ~= nil,
  "painted as a failure, not as ordinary output")
check(uiLink("[Click here to manually install the update]") ~= nil,
  "with a link that spells out what it will do, and really is clickable")
mdw.swapPackage = realSwap
os.remove(refusedPath)
mdwui.state.updateBusyAt = nil

-- The real swap. MDW does it: MDW is not the package being removed, so it
-- uninstalls and installs back to back and returns what Mudlet said. A package
-- cannot do that for itself - the code is inside the thing being uninstalled -
-- which is why this used to be uninstall, tempTimer(1), install, and a
-- watchdog to notice when that guess was wrong.
mdwui.state.updateVersion = "9.9.9"
-- Mudlet runs the new package's scripts INSIDE installPackage, which is where
-- this package's late-join rebuilds its UI. Doing it after the fact, as this
-- suite used to, never exercised that.
H.onInstallScripts = function()
  for _, name in ipairs(UI_ORDER) do
    assert(pcall(dofile, "src/scripts/" .. name .. ".lua"), "failed reloading " .. name)
  end
end
mdwui.installUpdate()
local swapPath = H.downloads[#H.downloads].path
writeFile(swapPath, PACKAGE_BYTES)
H.main._echoed, H.main._links = {}, {}
local installsBeforeSwap = #H.installed
raiseEvent("sysDownloadDone", swapPath)
-- NOTHING may happen inside the dispatch itself. Mudlet walks its handler
-- table with pairs() to reach this handler, and installing a package runs that
-- package's scripts, which register handlers INTO that table - a rehash mid-walk,
-- reported as "invalid key to 'next'" from the dispatcher, with every remaining
-- handler for the event skipped. A live client reported that error taking 0.2.2.
check(#H.uninstalled == uninstallsBefore and #H.installed == installsBeforeSwap,
  "no package is swapped from inside the event dispatch that asked for it")
H.flushTimers()
check(H.uninstalled[#H.uninstalled] == mdwui.packageName and #H.uninstalled == uninstallsBefore + 1,
  "a verified download uninstalls the running package")
check(H.installed[#H.installed] == swapPath and #H.installed == installsBeforeSwap + 1,
  "and installs the replacement back to back in that same tick - no waiting, nothing to guess")
-- Mudlet runs the new scripts inside installPackage, and the late-join they
-- carry is ARMED there rather than run: the layout MDW restores from belongs
-- to the copy being replaced, and a build that ran here would stamp this
-- package's first-run defaults over it before anything could read it (see the
-- bottom of Init.lua). A tick later it builds - still with nothing activating
-- it, which is the whole point of the seeds.
check(mdw.widgets["Journal"] == nil,
  "the swap itself does not rebuild - the late-join is armed, not run")
H.flushTimers()
check(mdw.widgets["Journal"] ~= nil and mdw.widgets["Comm"].tabsByName["Global"] ~= nil,
  "and a tick later the new scripts have rebuilt the UI, with nothing to activate")
local accepted = table.concat(H.main._echoed)
check(accepted:find("Update failed", 1, true) == nil
  and accepted:find("did not finish", 1, true) == nil,
  "a swap Mudlet accepted reports no failure - the new package announces itself")

-- Now the other half: Mudlet runs the new package's scripts, then raises
-- sysInstallPackage. mdwui.state survives in the Lua state, which is how the
-- watchdog from the old script run would have learned to stay quiet.
local downloadsBeforeSwap = #H.downloads
for _, name in ipairs(UI_ORDER) do
  assert(pcall(dofile, "src/scripts/" .. name .. ".lua"), "failed reloading " .. name)
end
H.flushTimers()
H.main._echoed = {}
raiseEvent("sysInstallPackage", mdwui.packageName)
check(mdwui.state.updateInstalled == true, "the reinstalled package reports back on sysInstallPackage")
-- A silent success reads exactly like the failure it replaced: the swap says
-- "Installing..." and then, until now, nothing at all. Say when it is over.
local doneLine = table.concat(H.main._echoed)
check(doneLine:find("installed - done", 1, true) ~= nil
  and doneLine:find(mdwui.version, 1, true) ~= nil,
  "a finished swap says so, and names the version now running")
check(io.exists(swapPath) == false, "and the temp package file is cleaned up after it lands")
-- A live client came back from a swap with its prompt gauges and nothing else:
-- the widgets HAD been built, and something reaped them afterwards - the old
-- copy's uninstall bookkeeping arriving late, against an ownership stamp the
-- new copy shares. `ui rebuild` put it right, so the swap now asks for that
-- itself rather than leaving a player to work it out.
mdw.cleanupGame(mdwui.packageName) -- exactly what reaps a stamped owner's things
check(mdw.widgets["Journal"] == nil, "a late reap can still take the fresh widgets")
-- The swap ends in a full MDW setup, always. The half-state cannot be detected
-- from here: a live client had mdw.widgets["Comm"] present while the docks were
-- empty, so a check on the registry passed and said nothing while the player
-- looked at an empty sidebar. Unconditional for that reason - it is idempotent,
-- it is what a player was typing by hand every time, and it is the only
-- sequence observed to produce a whole UI after a swap.
H.onInstallScripts() -- the new copy's scripts re-seed the registration
local setupsBefore = SETUPS
raiseEvent("sysInstallPackage", mdwui.packageName)
check(SETUPS > setupsBefore,
  "the swap always runs a full MDW setup, whatever the registry says")
check(mdw.widgets["Journal"] ~= nil and mdw.widgets["Comm"].tabsByName["Global"] ~= nil,
  "so the UI is whole afterwards, with nothing timed and nothing guessed")


check(mdw.widgets["Journal"] ~= nil and mdw.widgets["Comm"].tabsByName["Global"] ~= nil,
  "the swapped-in package rebuilt the whole UI from its seeds")
check(#H.downloads == downloadsBeforeSwap, "the rebuild after the swap does not re-check the feed")
check(uiRun("update install"):find("No update is pending", 1, true) ~= nil,
  "with the offer spent, a typed install asks for a check first instead of re-downloading it")

-- One release with sixty notes is capped too: however few releases a player is
-- behind, an offer must not scroll their session away, and the pointer at the
-- rest is the same one the earlier-releases line uses.
local big = {}
for i = 1, 60 do big[#big + 1] = "Change number " .. i end
mdwui.state.updateBusyAt = nil
mdwui.checkForUpdate(false)
local capped = feed(feedJson({ { aheadBy(3), "2026-12-31", big } }))
local printedBullets = select(2, capped:gsub("Change number", ""))
check(printedBullets <= 12 and capped:find("ui update notes", 1, true) ~= nil,
  "a long release note list is capped and points at ui update notes for the rest")
check(select(2, uiRun("update notes"):gsub("Change number", "")) == 60,
  "which prints all sixty of them")

-- The verb and its overview row, the rule for every player-facing toggle.
check(uiRun("help update"):find("ui update", 1, true) ~= nil, "ui help update explains the verb")

-- A row that is the wrong size is the only reason this verb gets typed, so the
-- bare form answers with the number instead of explaining the syntax.
local heightReport = uiRun("height equipment")
check(heightReport:find("row is", 1, true) ~= nil and heightReport:find("px", 1, true) ~= nil
  and heightReport:find("% of a", 1, true) ~= nil,
  "bare ui height reports the row's height and its share of the window")
check(heightReport:find("Give a height", 1, true) == nil,
  "and does not answer a question with the syntax")

-- Client.GUI: the game drives this package's lifecycle over the same message
-- Mudlet uses to install it natively, so the mudletui guard is what keeps the
-- two apart.
gmcp.Client = { GUI = { version = "1", url = "https://example/WillowdaleMudletUI.mpackage" } }
local guiUninstalls, guiDownloads = #H.uninstalled, #H.downloads
H.main._echoed = {}
raiseEvent("gmcp.Client.GUI")
H.flushTimers()
check(#H.uninstalled == guiUninstalls and #H.downloads == guiDownloads
  and table.concat(H.main._echoed) == "",
  "Mudlet's own install payload (version/url) is left entirely alone")

-- The server renamed this key; an unknown key is not a command. Anything the
-- guard does not recognise has to fall through as silently as the install
-- payload does, or a future rename removes somebody's UI.
gmcp.Client.GUI = { gomudui = "remove" }
H.main._echoed = {}
raiseEvent("gmcp.Client.GUI")
H.flushTimers()
check(#H.uninstalled == guiUninstalls and table.concat(H.main._echoed) == "",
  "the retired gomudui key is ignored, not obeyed")

gmcp.Client.GUI = { mudletui = "update" }
raiseEvent("gmcp.Client.GUI")
check(#H.downloads == guiDownloads + 1 and H.downloads[#H.downloads].url == mdwui.releasesUrl,
  "mudletui update asks the server for the feed")
-- Manual, not the silent session check: the game asked, so it answers either way.
check(feed(feedJson({ { mdwui.version, "2026-08-01", { "The first release" } } }))
  :find("You are on the latest version", 1, true) ~= nil,
  "and answers even when there is nothing to install")

-- "Remove the UI" means the interface, not the half carrying our name: MDW's
-- full uninstall takes every registered game package, the saved layout, the
-- font it applied, and MDW itself. Leaving behind the framework THIS package
-- installed is not a removal, it is a mess. Spied rather than run, because
-- actually tearing MDW down here would end the suite.
local realUninstall = mdw.uninstall
local fullUninstallCalled = false
mdw.uninstall = function() fullUninstallCalled = true end
gmcp.Client.GUI = { mudletui = "remove" }
raiseEvent("gmcp.Client.GUI")
check(not fullUninstallCalled,
  "remove does not uninstall from inside the event handler it is standing in")
H.flushTimers()
check(fullUninstallCalled,
  "a deferred tick runs MDW's full uninstall - the framework goes with the UI")
mdw.uninstall = realUninstall
gmcp.Client.GUI = nil

local ovUpdate = (uiRun(""):gsub("<[%w_]+>", ""))
check(ovUpdate:find("update%s+" .. (mdwui.version:gsub("%.", "%%."))) ~= nil,
  "the overview carries a ui update row whose value is the installed version")

-- 11. JSON null tolerance: OLDER server builds marshaled nil Go slices/maps
-- as null, which Mudlet's decoder turns into a truthy userdata sentinel -
-- `or {}` passes it through and ipairs/# blow up (the reinstall-time
-- renderAll crashed on ipairs(Group.Info.members)). The current server
-- guarantees []/{} instead; the mdwui.tbl guards stay as defense-in-depth
-- for old builds, and this step keeps them honest. newproxy() stands in for
-- the sentinel. Called unprotected on purpose: bindRenderer and
-- mdw.runReadyCallbacks both pcall, and would swallow a regression.
local NULL = newproxy()
gmcp = {
  Char = {
    Info = { name = "Newborn" },
    Affects = NULL,
    Inventory = {
      Worn = NULL,
      Backpack = { Items = NULL, Summary = { count = 0, max = 20 } },
      Keyring = NULL,
      Ingredients = { items = NULL, count = 0, max = 30 },
    },
    Combat = { Enemies = NULL, Target = { id = 5, name = "a goblin" } },
    Quests = { active = NULL, completed = NULL, rumors = NULL },
    Quest = { Detail = { id = 8, name = "Wolves at the Gate", has_reward = true,
      objectives = NULL, reward_items = NULL } },
  },
  Group = { Info = { members = NULL, invited = NULL }, Vitals = NULL },
  Comm = { History = NULL },
  Room = { Info = { Basic = NULL } },
}
mdwui.state.inCombat = true -- force the enemy-list loop to run
mdwui.renderAll()
check(mdw.widgets["Group"]._rows["none"] ~= nil, "null group members render as empty")
check(joined(mdw.widgets["Affects"]):find("No active affects"), "null affects map renders as empty")
check(joined(mdw.widgets["Inventory"]):find("backpack is empty"), "null backpack renders as empty")
check(joined(mdw.widgets["Keyring"]):find("keyring is empty"), "null keyring renders as empty")
check(joined(mdw.widgets["Equipment"]):find("-nothing-", 1, true) ~= nil,
  "null worn map renders all slots empty")
check(mdwui.inShop() == false, "null room shape reads as not-a-shop")
check(joined(mdw.widgets["Quests"]):find("No tracked quests") ~= nil
  and joined(mdw.widgets["Quests"]):find("Nothing nearby") ~= nil,
  "null quest lists and room render both empty quest sections")
raiseEvent("gmcp.Char.Combat.Enemies") -- auto-target path takes #Enemies
mdwui.state.questDetailId = 8
mdwui.renderQuests() -- detail view walks objectives and reward_items
check(findLink(mdw.widgets["Quests"].content, "back to quests") ~= nil,
  "quest detail with null lists still renders")
mdwui.state.questDetailId = nil
mdwui.state.inCombat = false

-- 12. MDW update mid-session: our widgets and groups come back unaided
-- (gmcp still holds the null-laden shape - the rebuild must survive it too).
-- MDW's teardown must run our onTeardown hook: the affects ticker stops
-- while its widget still exists, and buildUI restarts it on the setup.
local tickerIds = {}
for i, id in ipairs(mdwui.state.timers) do tickerIds[i] = id end
mdwui.setNumpadWalking(false) -- read back from the layout file after setup
-- The prompt-gauge memos must not outlive the gauges they describe: MDW
-- rebuilds the row from its declared styles, so a surviving memo would make
-- the first payload after a build skip the restyle it needs.
mdwui.state.aeTrackCss = "stale"
mdw.teardown()
check(mdwui.state.aeTrackCss == nil, "MDW teardown clears the prompt-gauge memos")
check(H.nativeKeys["Numpad Walking"] == false,
  "numpad folder stays disabled through the teardown gap")
check(#tickerIds > 0 and #mdwui.state.timers == 0,
  "MDW teardown ran our onTeardown hook (timer registry cleared)")
local tickerAlive = false
for _, id in ipairs(tickerIds) do
  if H.timers[id] then tickerAlive = true end
end
check(not tickerAlive, "affects ticker stopped by the teardown hook")
mdw.setup()
H.flushTimers()
check(mdw.widgets["Combat"] ~= nil and mdw.widgets["Comm"] ~= nil,
  "widgets rebuilt after an MDW update")
check(mdw.widgets["Equipment"].stackId ~= nil, "grouping restored after update")
-- Heights survive a full MDW setup, and are still not MDW's default. This is
-- the ordering trap: MDW auto-fills the BOTTOM row of a dock, and a stack
-- sized while it is still the bottom row has that height DISCARDED - when the
-- row later stops filling, reorganizeDock restores the height captured before
-- the call. Sizing before every group exists therefore does nothing at all,
-- silently, which is how every default here sat at 200px in a live client
-- while the suite reported it fine.
check(mdw.widgets["MDWUI_Items"].container:get_height() ~= mdw.config.widgetHeight,
  "the items group keeps a real height through an MDW setup, not MDW's default")
check(mdw.widgets["MDWUI_Items"].fill ~= true,
  "and it is not the fill row, which cannot be sized at all")
check(mdw.widgets["Items"] == nil, "demo widgets stay suppressed across MDW updates")
check(H.labels["MDW_PromptGauge_hp_back"] ~= nil, "prompt gauges rebuilt after an MDW update")
check(H.labels["MDW_PromptGauge_enemy_back"] ~= nil,
  "toggled-on enemy gauge survives the update (settings persisted)")
check(H.labels["MDW_PromptBarMenuBtn"] ~= nil, "prompt bar settings button rebuilt")
check(mdw.bars["WillowdaleTop"] ~= nil, "top bar rebuilt after an MDW update")
-- loadLayout restores gameSettings one step before it runs our onReady, so
-- the rebuild sees the saved choice rather than the default.
check(mdwui.numpadWalking() == false and H.nativeKeys["Numpad Walking"] == false,
  "numpad walking stays off across an MDW update (settings persisted)")
mdwui.setNumpadWalking(true)
check(H.nativeKeys["Numpad Walking"] == true, "and comes back when switched on again")

-- 12b. THE dev scenario: MDW's scripts re-run over the live session (script
-- editor save / package reload without install events). MDW_Config wipes
-- MDW's registries out from under the on-screen UI, but now schedules its
-- own rebuild; our onReady seed survives the re-run, so our widgets come
-- back with no manual step. Before MDW's fix, resetProfile() was the only
-- way to recover this state - reloading this package could not.
for _, name in ipairs(MDW_ORDER) do
  assert(pcall(dofile, MDW_SRC .. name .. ".lua"), "failed reloading " .. name)
end
check(mdw.widgets["Combat"] == nil, "in-place MDW reload wiped the live registry (the breakage)")
H.flushTimers() -- MDW's self-scheduled rebuild
H.flushTimers() -- setup()'s deferred dock reorganize
check(mdw.isSetUp and mdw.widgets["Combat"] ~= nil and mdw.widgets["Comm"] ~= nil,
  "our widgets rebuilt after an in-place MDW reload, no resetProfile needed")
check(mdw.widgets["Comm"].tabsByName["Global"] ~= nil, "rebuilt Comm carries our tab set")
check(mdw.widgets["Items"] == nil, "demo widgets stay suppressed through the reload")

-- 12c. Our own scripts re-run mid-session (editor save): mdwui.state is
-- preserved across re-runs, so buildUI's killAllTimers can still see the
-- previous affects ticker - a wiped registry would stack a duplicate.
local function liveTimerCount()
  local n = 0
  for _ in pairs(H.timers) do n = n + 1 end
  return n
end
for _ = 1, 2 do
  for _, name in ipairs(UI_ORDER) do
    assert(pcall(dofile, "src/scripts/" .. name .. ".lua"), "failed reloading " .. name)
  end
end
-- Two, not one: every build arms the affects ticker AND the deferred
-- typeface assert (12e). The number is the point - it must not grow with the
-- number of re-runs.
check(liveTimerCount() == 2, "script re-runs replace our timers instead of stacking them")

-- 12d. Bootstrapping MDW (Update.lua). Mudlet resolves no package
-- dependencies - the mfile's "dependencies" field never leaves the exporter -
-- so this package installs the framework it hard-requires. Driven like 10c:
-- the stub records downloads instead of performing them, and the suite writes
-- the file Mudlet would have written and raises the event it would have
-- raised. mdw.version is faked here and comes back for real at the end of the
-- section, when the "new" MDW's scripts load.
H.packages = { "MDW" } -- what getPackages() reports in a profile that has it
local bootDownloads, bootUninstalls = #H.downloads, #H.uninstalled

mdwui.ensureMdw()
check(#H.downloads == bootDownloads, "an MDW that already satisfies the minimum is not fetched at all")

mdw.version = "9.9.9"
mdwui.ensureMdw()
check(#H.downloads == bootDownloads and #H.uninstalled == bootUninstalls,
  "an MDW NEWER than the minimum is left untouched - the pin is a floor, never a downgrade")

-- MDW installed as a MODULE is not ours to swap: getPackages() does not list
-- modules, so the bootstrap would read "absent" and leave a package named MDW
-- beside the module - two copies of the singleton over one UI.
mdw.version = "0.3.0"
H.modulePaths["MDW"] = H.homeDir .. "/MDW.mpackage"
H.main._echoed = {}
check(mdwui.ensureMdw() == false and #H.downloads == bootDownloads,
  "an MDW installed as a module is left alone, never swapped")
check(table.concat(H.main._echoed):find("as a module", 1, true) ~= nil
  and table.concat(H.main._echoed):find(mdwui.mdwUrl, 1, true) ~= nil,
  "and the player is told, with the URL to update it by hand")
H.modulePaths["MDW"] = nil
-- That attempt spent the session's one try; the checks below are about the
-- ordinary package case.
mdwui.state.mdwFetchedFor = nil

-- Too old. The gate is what a player with no network is left holding, so it
-- keeps the manual instruction even while the download is under way.
mdw.version = "0.3.0"
H.main._echoed = {}
mdwui.buildUI()
check(table.concat(H.main._echoed):find("0.3.0", 1, true) ~= nil
  and table.concat(H.main._echoed):find("fetching", 1, true) ~= nil
  and table.concat(H.main._echoed):find(mdwui.mdwUrl, 1, true) ~= nil,
  "buildUI's gate names the MDW installed, says it is being fetched, and still gives the URL")
check(mdw.widgets["Combat"] ~= nil, "and the refused build left the running session untouched")

H.main._echoed = {}
raiseEvent("sysLoadEvent")
check(#H.downloads == bootDownloads + 1 and H.downloads[#H.downloads].url == mdwui.mdwUrl,
  "a profile load with MDW too old downloads the pinned MDW release")
check(table.concat(H.main._echoed):find("fetching it now", 1, true) ~= nil, "saying so in one line")
raiseEvent("sysLoadEvent")
check(#H.downloads == bootDownloads + 1, "and only once a session, however often a trigger fires")

-- A GitHub error page must never cost a player the MDW they are running:
-- verification comes before anything is uninstalled here too.
local mdwPath = H.downloads[#H.downloads].path
writeFile(mdwPath, "<!DOCTYPE html>" .. string.rep("x", 30000))
H.main._echoed = {}
raiseEvent("sysDownloadDone", mdwPath)
check(table.concat(H.main._echoed):find("not a Mudlet package", 1, true) ~= nil
  and table.concat(H.main._echoed):find(mdwui.mdwUrl, 1, true) ~= nil,
  "a bad MDW download is refused, with the URL to install by hand")
check(#H.uninstalled == bootUninstalls, "and the MDW that is running is NOT uninstalled")
check(io.exists(mdwPath) == false, "the bad file is removed")

-- The other failure mode: nothing arrives at all.
mdwui.state.mdwFetchedFor = nil
mdwui.ensureMdw()
H.main._echoed = {}
raiseEvent("sysDownloadError", "host not found", H.downloads[#H.downloads].path)
check(table.concat(H.main._echoed):find("host not found", 1, true) ~= nil
  and table.concat(H.main._echoed):find(mdwui.mdwUrl, 1, true) ~= nil,
  "a download error names the failure and hands the URL over")
check(mdwui.state.updateBusyAt == nil and mdwui.state.mdwFile == nil,
  "and clears the in-flight guard the updater shares")

-- The ordinary case: this package installed on its own, MDW nowhere in the
-- profile - which is also the second trigger, since our own install is the
-- first moment the package can find that out.
H.packages = {}
mdwui.state.mdwFetchedFor = nil
local bootInstalls = #H.downloads
raiseEvent("sysInstallPackage", mdwui.packageName)
check(#H.downloads == bootInstalls,
  "our own install defers the bootstrap a tick rather than re-entering Mudlet's installer")
H.flushTimers()
check(#H.downloads == bootInstalls + 1 and H.downloads[#H.downloads].url == mdwui.mdwUrl,
  "and then fetches MDW, which the profile has none of")
mdwPath = H.downloads[#H.downloads].path
writeFile(mdwPath, PACKAGE_BYTES)
bootInstalls = #H.installed
raiseEvent("sysDownloadDone", mdwPath)
check(#H.uninstalled == bootUninstalls, "MDW absent: nothing is uninstalled on the way in")
check(#H.installed == bootInstalls,
  "and nothing is installed from inside the download event either")
-- One tick out of the dispatch, then uninstall and install back to back inside
-- it: THIS package is not the one being removed, which is the whole reason a
-- package built on MDW is what moves MDW. The mirror of mdw.swapPackage, in the
-- direction MDW cannot do for itself.
H.flushTimers()
check(H.installed[#H.installed] == mdwPath and #H.installed == bootInstalls + 1,
  "and MDW installs on the next tick, with nothing to wait out after that")

-- An MDW that is merely too old: uninstall FIRST (Mudlet refuses to install
-- over a name it holds), and only once the replacement is proven on disk.
H.packages = { "MDW" }
mdwui.state.mdwFetchedFor = nil
mdwui.ensureMdw()
mdwPath = H.downloads[#H.downloads].path
writeFile(mdwPath, PACKAGE_BYTES)
bootInstalls = #H.installed
raiseEvent("sysDownloadDone", mdwPath)
H.flushTimers() -- the tick that takes the swap out of the download dispatch
check(H.uninstalled[#H.uninstalled] == "MDW" and #H.uninstalled == bootUninstalls + 1,
  "a verified download uninstalls the old MDW - only now, with the replacement on disk")
check(mdw.isSetUp == false, "MDW's teardown ran inside that uninstall (our onTeardown hook with it)")
-- Our own timers died in that teardown, which does not matter: there are none
-- to survive. This package is still running - it is not the one being removed -
-- so it installs the replacement in the same breath and reads the answer.
check(H.installed[#H.installed] == mdwPath and #H.installed == bootInstalls + 1,
  "and the replacement goes in immediately, teardown or no teardown")

-- The bootstrap guard, keyed on the version asked for rather than the session.
local mdwVersionForRace = mdw.version
mdw.version = "0.4.0" -- too old, so the bootstrap actually fetches
H.packages = { "MDW" }
mdwui.state.mdwFetchedFor = nil
mdwui.state.mdwFile = nil
mdwui.state.updateBusyAt = nil
local downloadsBeforeHeld = #H.downloads
mdwui.ensureMdw()
check(#H.downloads == downloadsBeforeHeld + 1, "an MDW below the minimum is fetched again")
local heldPath = H.downloads[#H.downloads].path
writeFile(heldPath, PACKAGE_BYTES)
local heldInstalls = #H.installed
raiseEvent("sysDownloadDone", heldPath)
H.flushTimers()
check(H.installed[#H.installed] == heldPath and #H.installed == heldInstalls + 1,
  "a raised minimum installs its MDW on the next tick, exactly once")
mdw.version = mdwVersionForRace

-- The guard is per REQUIREMENT, not per session. It used to be a plain "have
-- we fetched this session" boolean, and mdwui.state survives a package swap by
-- design - so a client that had bootstrapped MDW once could never bootstrap it
-- again. A live client hit exactly that: an update raised minMdwVersion, the
-- build gate refused, and the bootstrap returned in silence because it had
-- fetched the OLD minimum hours earlier. The UI was left unable to complete
-- its own update.
local pinForGuard, versionForGuard = mdwui.minMdwVersion, mdw.version
-- The in-flight download from the step above is restored afterwards: the swap
-- it belongs to is still being followed further down.
local mdwFileInFlight, busyInFlight = mdwui.state.mdwFile, mdwui.state.updateBusyAt
mdw.version = "0.4.0" -- below any pin, so the requirement is genuinely unmet
mdwui.state.mdwFetchedFor = pinForGuard -- an attempt was already made for THIS pin
mdwui.state.updateBusyAt, mdwui.state.mdwFile = nil, nil
local guardDownloads = #H.downloads
mdwui.ensureMdw()
check(#H.downloads == guardDownloads,
  "an attempt already made for this requirement is not repeated")
mdwui.minMdwVersion = "0.5.9" -- as a package swap raising the pin would
mdwui.ensureMdw()
check(#H.downloads == guardDownloads + 1,
  "but a raised minimum gets an attempt of its own, in the same session")
mdwui.minMdwVersion, mdw.version = pinForGuard, versionForGuard
mdwui.state.mdwFetchedFor = nil
mdwui.state.mdwFile, mdwui.state.updateBusyAt = mdwFileInFlight, busyInFlight

-- Mudlet unpacks the new MDW, runs its scripts, then raises sysInstallPackage.
-- Nothing in this package activates anything: MDW's install runs setup ->
-- onReady -> buildUI, and our onReady seed was there the whole time.
for _, name in ipairs(MDW_ORDER) do
  assert(pcall(dofile, MDW_SRC .. name .. ".lua"), "failed loading " .. name)
end
raiseEvent("sysInstallPackage", "MDW")
H.flushTimers()
H.flushTimers()
check(mdwui.mdwSatisfied(), "the installed MDW's own scripts carry a satisfying version again")
check(mdw.isSetUp and mdw.widgets["Combat"] ~= nil
  and mdw.widgets["Comm"].tabsByName["Global"] ~= nil,
  "the UI built itself from its seeds when MDW landed, with nothing to activate")
check(io.exists(mdwPath) == false, "and the downloaded MDW package is cleaned up once it lands")

-- 12e. The typeface is asserted AFTER the build, not during it. Mudlet
-- registers a package's TTF with Qt separately from running that package's
-- scripts, so MDW's setup-time resolution can look for ours a moment before
-- it is loadable, fall back to Bitstream Vera Sans Mono, and put the GAME's
-- own text in it. On an ordinary profile load nothing re-checks - MDW's
-- re-validation is driven by other packages coming and going - so the check
-- is this package's to make.
H.availableFonts["Fira Code Willowdale"] = nil
mdw.revalidateFontFamily() -- the answer a setup() racing the font would get
check(mdw.config.effectiveFontFamily == "Bitstream Vera Sans Mono"
  and H.mainFont == "Bitstream Vera Sans Mono",
  "a font Qt has not registered yet drops the whole UI onto MDW's fallback")
check(mdw.config.fontFamily == "Fira Code Willowdale",
  "and the preference survives it, so there is something to come back to")
mdwui.buildUI() -- every build arms the ladder, as its last act
H.flushTimers() -- whose first pass still cannot see the font
check(H.mainFont == "Bitstream Vera Sans Mono", "the fallback stands while the font is missing")
H.availableFonts["Fira Code Willowdale"] = true
H.flushTimers() -- the pass that first one armed for itself
check(mdw.config.effectiveFontFamily == "Fira Code Willowdale"
  and H.mainFont == "Fira Code Willowdale",
  "the post-build assert repairs the main console when the font lands late")

-- Bounded, never a poll: a font that is genuinely gone must stop asking
-- rather than re-arm for the rest of the session.
mdwui.killAllTimers()
H.timers = {}
H.availableFonts["Fira Code Willowdale"] = nil
mdwui.assertFont()
local fontRounds = 0
while next(H.timers) ~= nil and fontRounds < 8 do
  fontRounds = fontRounds + 1
  H.flushTimers()
end
check(fontRounds == 3, "the assert ladder runs out instead of polling all session")
H.availableFonts["Fira Code Willowdale"] = true
mdwui.buildUI() -- leave the session as it was found: font applied, ticker armed
H.flushTimers()
check(H.mainFont == "Fira Code Willowdale", "and a build with the font present settles on the first pass")

-- 12f. AN UPDATE MUST NOT COST THE PLAYER THEIR LAYOUT. A package update is
-- an uninstall immediately followed by an install, and the saved layout is
-- the only record of where the player put things - so everything that runs in
-- between has to leave that record alone. Three separate things used to erase
-- it, and each is checked here:
--
--   * our own uninstall handler destroys our widgets, and every destroy asks
--     MDW to save - which rewrites the file from the LIVE registry, i.e.
--     without the widgets it just destroyed (Core.lua holds the save lock);
--   * the late-join at the bottom of Init.lua ran INSIDE installPackage, before
--     MDW could restore anything, and stamped this package's first-run
--     defaults over the saved layout (it is armed a tick late now);
--   * defaultGroup regrouped widgets a second build had not created, which is
--     what MDW's onReady re-assert on sysInstallPackage is (the `created` map).
--
-- The contrast is the point: this is the UPDATE path, where the file must
-- survive. The REMOVE path deliberately deletes it (mdw.uninstall, spied
-- above) - that is the difference between the two modes.
mdw.addToStack("MDWUI_Status", "Quests")   -- dragged out of the right dock
mdw.setWidgetFontSize("Combat", (mdw.getFontSizes().widgets["Combat"] or 11) + 3)
mdw.widgets["Forage"]:hide()               -- closed a widget they never use
mdw.setDockWidth("left", 333)
mdw.saveLayout()
local wantMembers = table.concat(mdw.widgets["MDWUI_Status"].members, ",")
local wantFont = mdw.widgets["Combat"].fontAdjust
check(wantMembers:find("Quests", 1, true) ~= nil and wantFont ~= 0,
  "the player rearranged: Quests dragged into the status group, Combat's font bumped")

local function savedLayout()
  local t = {}
  pcall(table.load, mdw.layoutFile, t)
  return t
end
raiseEvent("sysUninstallPackage", mdwui.packageName)
H.flushTimers()
local held = savedLayout()
check(held.widgets and held.widgets["Quests"] and held.widgets["Quests"].stackId == "MDWUI_Status",
  "an ordinary uninstall leaves the saved layout intact - an UPDATE fires one too")
check(held.widgets["Combat"].fontAdjust == wantFont and held.widgets["Forage"].visible == false,
  "with every per-widget choice still in it")

for _, name in ipairs(UI_ORDER) do
  assert(pcall(dofile, "src/scripts/" .. name .. ".lua"), "failed reloading " .. name)
end
check(savedLayout().widgets["Quests"].stackId == "MDWUI_Status",
  "the new copy's scripts do not stamp the default layout over it on their way in")
raiseEvent("sysInstallPackage", mdwui.packageName)
H.flushTimers(); H.flushTimers()
check(table.concat(mdw.widgets["MDWUI_Status"].members, ","):find("Quests", 1, true) ~= nil,
  "and the player's grouping is what comes back after the update")
check(mdw.widgets["Combat"].fontAdjust == wantFont, "with their per-widget font size")
check(mdw.widgets["Forage"].visible == false, "and the widget they closed still closed")
check(mdw.config.leftDockWidth == 333, "and the sidebar width they set")

-- 13. Uninstalling this package removes everything ours, leaves MDW running.
-- The event carries the mfile package name - packageName must match it.
-- An open context menu holds closures into this package, so it must go too.
--
-- This is the ORDINARY path - a player removing the package from Mudlet's own
-- package manager. Its invariant is that MDW keeps running; the game's remove
-- command is a different thing and is covered separately above.
mdw.showContextMenu("stale actions", { { label = "Noop", onClick = function() end } }, 100, 100)
raiseEvent("sysUninstallPackage", mdwui.packageName)
check(mdw.menus.context == false and H.labels["MDW_ContextMenuBg"] == nil,
  "open context menu closed by our uninstall")
check(mdw.widgets["Combat"] == nil and mdw.widgets["Comm"] == nil, "our widgets destroyed on uninstall")
check(mdw.onReady[mdwui.packageName] == nil, "onReady registration removed")
check(mdw.onTeardown[mdwui.packageName] == nil, "onTeardown registration removed")
check(mdw.gamePackages[mdwui.packageName] == nil, "co-removal registration removed")
check(mdw.bars["WillowdaleTop"] == nil and H.labels["MDW_Bar_WillowdaleTop_Bg"] == nil,
  "top bar removed on uninstall")
check(H.labels["MDW_PromptGauge_hp_back"] == nil and mdw.promptGaugeDefs == nil,
  "prompt-gauge declaration withdrawn on uninstall")
check(H.labels["MDW_PromptBarMenuBtn"] == nil and mdw.promptBarMenuItems == nil,
  "prompt bar settings button withdrawn on uninstall")
check(H.labels["MDW_Combat_Row_hp_back"] == nil and H.labels["MDW_Combat_MenuBtn"] == nil,
  "combat rows and settings button died with their widget")
-- mdw.gameMenu survives a teardown by design, so this one is ours to withdraw
-- (MDW's ownership reap would get it too, but only if its handler ran first).
-- No local of its own: Lua 5.1 allows 200 per chunk and this suite is one,
-- and it is full. Ours is the only package declaring a row here, so the count
-- IS the answer.
check(#(mdw.gameMenu or {}) == 0, "our gear-menu row withdrawn on uninstall")
check(mdw.isSetUp, "MDW itself unaffected")

print("\nSMOKE PASSED")
