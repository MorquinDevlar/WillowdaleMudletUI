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

--- The top chrome bar: session and identity strip between the header and the
-- main console, split left/right. Left is who you are (Char.Info name,
-- class and level) plus the connection timer counting up from
-- mdwui.state.loginAt;
-- right is the version-exposure convention in action - ours, MDW's and the
-- mapper's, all read at render time with guarded lookups so no package needs
-- the others installed. The two groups are padded apart to the bar console's
-- own wrap width (the same mdw.calculateWrap MDW applies to it in
-- layoutBars), which is what keeps the right group flush at the bar's right
-- edge as the window and sidebars change size.
function mdwui.renderTopBar()
  local bar = mdw and mdw.bars and mdw.bars["WillowdaleTop"]
  if not (bar and bar.console) then return end
  local C = mdwui.config.colors
  local info = mdwui.tbl(gmcp and gmcp.Char and gmcp.Char.Info)
  local name = info.name or "-"
  local cls = mdwui.titleCase(info.class or "-")
  local lvl = (info.level == nil) and "-" or tostring(info.level)
  local secs = math.max(0, os.time() - (mdwui.state.loginAt or os.time()))
  local hrs, mins, sec =
    math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60
  local connText = string.format("%02dh %02dm %02ds", hrs, mins, sec)
  local uiVersion = tostring(mdwui.version)
  local mdwVersion = (mdw and mdw.version) or "-"
  local mapperVersion = (mapper and mapper.version) or "-"

  -- Measure on the plain text first, then colorize: byte length is the
  -- character count here (names and classes are ASCII).
  local leftPlain = string.format("%s - %s Lvl. %s    Con. Time: %s",
    name, cls, lvl, connText)
  local rightPlain = string.format("UI v%s MDW v%s Mapper v%s",
    uiVersion, mdwVersion, mapperVersion)
  local cols = mdw.calculateWrap and bar.console.get_width
    and mdw.calculateWrap(bar.console:get_width(), mdw.config.contentFontSize) or 0
  -- One column short of the wrap, and no trailing newline: the bar is a
  -- single text row, and either would push the line onto a second row that
  -- the bar is not tall enough to show.
  local gap = math.max(4, (cols - 1) - #leftPlain - #rightPlain)

  -- Colorized twins of the two measured strings above - tags only, so the
  -- padding still lands. Digits body text, unit letters the class gold.
  local connDecho = string.format("<%s>%02d<%s>h <%s>%02d<%s>m <%s>%02d<%s>s",
    C.text, hrs, C.charGold, C.text, mins, C.charGold, C.text, sec, C.charGold)
  -- Only the package name carries its hue; the "v" is dim and the version
  -- itself is the same body text as the clock's digits, so the strip reads
  -- as three colored labels over one uniform kind of number.
  local function versionDecho(label, version, color)
    return string.format("<%s>%s <%s>v<%s>%s", color, label, C.dim, C.text, version)
  end

  bar.console:clear()
  bar.console:decho(string.format(
    "<%s>%s <%s>- %s <%s>Lvl. <%s>%s    <%s>Con. Time: <%s>%s%s%s %s %s",
    C.charHeader, name, C.charGold, cls,
    C.charLabel, C.text, lvl,
    C.charLabel, C.text, connDecho,
    string.rep(" ", gap),
    versionDecho("UI", uiVersion, C.verUI),
    versionDecho("MDW", mdwVersion, C.verMDW),
    versionDecho("Mapper", mapperVersion, C.verMapper)))
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
  mdwui.renderTopBar()
  mdwui.updatePromptBar()
  mdwui.updatePromptGauges()
  mdwui.onCommHistory()
end

--- Create the full widget set. Runs on every MDW setup (registered in
-- MDWUI_Config via mdw.onReady), so it must be idempotent: Widget:new
-- returns existing widgets, defaultGroup respects saved layouts, and the
-- ticker replaces itself.
function mdwui.buildUI()
  -- One hard gate instead of a guard per MDW call: under an older MDW the
  -- player gets one useful line on the main console rather than a nil error
  -- part-way through the build. It must run BEFORE any side effect
  -- (killAllTimers, widget creation) so a refused build leaves the session
  -- untouched. No retry logic needed: MDW re-runs the onReady registration on
  -- its next setup, which is exactly when the player updates MDW.
  if not mdwui.mdwSatisfied() then
    local have = (mdw and mdw.version) or "older than 0.3.0"
    -- The bootstrap (mdwui.ensureMdw) is already fetching MDW by the time an
    -- old MDW gets this far, so the line says so - but it keeps the manual
    -- instruction and the URL, because this gate is exactly what a player
    -- with no network or a blocked GitHub is left holding.
    -- Two sentences on two lines: one of them is a URL, and a single
    -- ~150-character line wraps mid-URL on a narrow main window.
    local msg = string.format("%s needs MDW %s or newer (installed: %s) - fetching MDW now.\n"
      .. "If it does not arrive, install it by hand from %s",
      mdwui.packageName, mdwui.minMdwVersion, have, mdwui.mdwUrl)
    -- mdw.notify only exists from MDW 0.3 on, hence the plain-echo fallback.
    if mdw and mdw.notify then mdw.notify(msg) else echo(msg .. "\n") end
    return
  end

  mdwui.killAllTimers()

  -- MDW's demo widgets share names with ours ("Affects", "Map", "Comm") and
  -- already exist when this package installs MID-SESSION - the
  -- loadExamples=false seed only stops future setups. Widget:new would hand
  -- us the demo instead (worst case the demo Comm, whose different tab set
  -- would silently eat our Global/Tells routing), so clear demo leftovers we
  -- did not create ourselves. "Items" is demo-only and would linger otherwise.
  for _, name in ipairs({ "Items", "Affects", "Map", "Comm" }) do
    local existing = mdw.widgets[name]
    if existing and not mdwui.state.widgets[name] and existing.destroy then
      existing:destroy()
    end
  end

  -- The journals used to be two widgets; they are one now (the web client
  -- merged them the same way). A saved layout from that version still
  -- restores "PlayerJournal", so retire it rather than leave an empty panel
  -- docked forever.
  local stale = mdw.widgets["PlayerJournal"]
  if stale and stale.destroy then stale:destroy() end
  mdwui.state.widgets["PlayerJournal"] = nil

  -- The gameConfig seeds merge only during MDW setup; a mid-session install
  -- builds without one, so apply the live-relevant settings directly
  -- (configure re-applies them immediately; harmless when already merged).
  if mdw.configure then
    mdw.configure({ usePromptTrigger = false, uiName = mdw.gameConfig.uiName })
  end

  local defs = {
    -- name, renderer, options (creation order = default row order). `title`
    -- overrides the tab label: the widget NAME is the saved-layout key, so
    -- the two journals are retitled rather than renamed.
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
    -- One Journal widget holding the whole `journal` command: the player
    -- journal's categories plus a Quests category carrying the quest journal
    -- (see MDWUI_Journal.lua). The Quests widget above stays lean.
    { "Journal", mdwui.renderJournal, { dock = "right" } },
  }
  for _, def in ipairs(defs) do
    local title = def[3].title or def[1]
    local widget = mdw.Widget:new({ name = def[1], title = title, dock = def[3].dock })
    -- Widget:new hands back an EXISTING widget untouched, so a retitle on an
    -- already-built session has to be applied explicitly.
    if widget.title ~= title and widget.setTitle then widget:setTitle(title) end
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
  --
  -- Heights are a FRACTION of the window, not pixels, because the web client
  -- sizes this dock by percentage (Affects 25%, items 50%, character 25% -
  -- dockview-widgets.js) and a pixel count cannot express that. The items
  -- group gets by far the most: an inventory is a LIST, and the one thing a
  -- player wants from it on a first run is to see all of it without
  -- scrolling, while Affects is a handful of timers that never needed the
  -- 180px it used to hold.
  --
  -- Proportional also because MDWUI_Char below is MDW's FILL row - it absorbs
  -- whatever these two do not claim, and its budget clamps at zero
  -- (reorganizeDock's fillRowBudget). A fixed height large enough to show a
  -- full inventory on a big screen would therefore collapse the character
  -- group entirely on a laptop, silently. Scaling both keeps the ratio
  -- wherever the window lands.
  --
  -- All first-run only: defaultGroup skips any widget whose placement a saved
  -- layout already owns.
  local _, winH = getMainWindowSize()
  defaultGroup({ "Affects", "Keyring" }, "MDWUI_Status", "left", math.floor(winH * 0.18))
  defaultGroup({ "Equipment", "Inventory", "Forage" }, "MDWUI_Items", "left", math.floor(winH * 0.46))
  defaultGroup({ "Character", "Combat", "Group" }, "MDWUI_Char", "left")
  defaultGroup({ "Comm", "Quests", "Journal" }, "MDWUI_Comms", "right")
  local map = mdw.widgets["Map"]
  if map and not map._pendingStackId and map.stackId then
    mdw.resizeWidgetClass(mdw.widgets[map.stackId], nil, 380)
  end

  -- The prompt-layer gauges render in MDW's prompt bar, not in a widget, so
  -- they are re-declared here alongside the widget builds - as are the two
  -- vertical-ellipsis settings menus (prompt bar + Combat widget).
  mdwui.setupPromptGauges()
  mdwui.setupPromptBarMenu()
  mdwui.setupWidgetMenus()

  -- Numpad walking. Not a widget, but this is the first point where the
  -- player's saved choice exists: MDW restores mdw.gameSettings in
  -- loadLayout, one step before it runs these callbacks. Idempotent by
  -- kill-then-bind, like the ticker below.
  mdwui.applyNumpadKeys()
  -- Guarded like every cross-module call at build time; one line, once per
  -- session (announceCommands remembers).
  if mdwui.announceCommands then mdwui.announceCommands() end
  -- The session's only automatic update check (MDWUI_Update remembers it
  -- ran, so the rebuilds MDW triggers do not re-check). Nothing is printed
  -- unless a newer release exists, and nothing is downloaded but the
  -- changelog until the player says so.
  mdwui.checkForUpdateOnce()

  -- Top chrome bar: session/identity/version strip. Unguarded - the version
  -- gate at the top of buildUI guarantees the MDW 0.4 createBar API. loginAt
  -- starts the connection timer, and is seeded here as a fallback for
  -- mid-session installs - the real value comes from sysConnectionEvent.
  mdwui.state.loginAt = mdwui.state.loginAt or os.time()
  mdw.createBar({ name = "WillowdaleTop", edge = "top", console = true })

  -- Paint from cached data, then ask the server for everything fresh. The
  -- full payload includes Comm.History (guide 8.22); Client.Map wakes the
  -- native mapper feed - never a Map.Nearby reimplementation (guide 5.12).
  mdwui.renderAll()
  mdwui.requestFullPayload()
  mdwui.request("Client.Map")

  -- Affects countdowns are driven locally (no per-second push from the
  -- server), so a 1s ticker repaints the panel while durations run down. The
  -- top bar rides along: its connection clock ticks on the same beat, and
  -- this repaint is also what re-pads the right-aligned version group after
  -- a window or sidebar resize - mdw.layoutBars resizes the bar console with
  -- no callback to hook, so the bar simply catches up within a second.
  local tid = tempTimer(1, function()
    mdwui.renderAffects()
    mdwui.renderTopBar()
  end, true)
  if tid then mdwui.addTimer(tid) end
end

---------------------------------------------------------------------------
-- EVENT WIRING
-- One table, one registration loop. Named handlers, so re-running this
-- script replaces rather than duplicates, and uninstall can remove them all.
---------------------------------------------------------------------------

local handlers = {
  -- Character panel aggregates the web client's updateCharacterPanel
  -- triggers: Info, Attributes, and Worth. Info also feeds the top bar's
  -- name/class strip.
  ["gmcp.Char.Info"] = function()
    -- Name first: a character switch mid-session invalidates the quest
    -- caches, and the journal render below must not reuse the old
    -- character's completed history.
    mdwui.onCharName(mdwui.tbl(gmcp.Char and gmcp.Char.Info).name)
    mdwui.renderCharacter()
    mdwui.renderTopBar()
  end,
  ["gmcp.Char.Attributes"] = function() mdwui.renderCharacter() end,
  ["gmcp.Char.Worth"] = function() mdwui.renderCharacter() end,

  ["gmcp.Char.Vitals"] = function() mdwui.onVitals() end,
  ["gmcp.Char.Balance"] = function() mdwui.onBalance() end,
  ["gmcp.Char.Combat.Enemies"] = function() mdwui.onCombatEnemies() end,
  ["gmcp.Char.Combat.Status"] = function() mdwui.onCombatStatus() end,
  ["gmcp.Char.Combat.Ended"] = function() mdwui.setInCombat(false) end,
  ["gmcp.Char.Combat.Target"] = function()
    local target = (gmcp.Char and gmcp.Char.Combat and gmcp.Char.Combat.Target) or {}
    if target.name and target.name ~= "" then
      -- setInCombat renders and updates the prompt gauges itself, and a
      -- fight opening with a Target push fronts the Combat tab (web parity:
      -- the Target handler also calls setCombatActive).
      mdwui.setInCombat(true)
    else
      mdwui.renderCombat()
      mdwui.updatePromptGauges() -- the prompt bar's enemy gauge tracks Target
    end
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

  -- Journal counts (guide 5.15). The counts handler takes the event's second
  -- argument - Mudlet raises gmcp.Char.Journal for List and Entry arrivals
  -- too, and only the real key tells them apart.
  ["gmcp.Char.Journal"] = function(event, key) mdwui.onJournalCounts(event, key) end,
  ["gmcp.Char.Journal.List"] = function() mdwui.onJournalList() end,
  ["gmcp.Char.Journal.Entry"] = function() mdwui.onJournalEntry() end,

  ["gmcp.Char.Quests"] = function() mdwui.onQuests() end,
  ["gmcp.Char.Quest.Detail"] = function() mdwui.onQuestDetail() end,
  -- The Quests widget's Here section and the Journal's "Current zone" filter
  -- are both keyed on the current zone, so a room change repaints them (the
  -- web client re-renders updateQuestsPanel from its Room.Info handler).
  -- Cheap pure repaints, same as the affects ticker.
  ["gmcp.Room.Info.Basic"] = function()
    mdwui.renderQuests()
    mdwui.renderJournal()
  end,

  ["gmcp.Comm.Channel"] = function() mdwui.onCommChannel() end,
  ["gmcp.Comm.History"] = function() mdwui.onCommHistory() end,

  -- Server hot-reload: cached state may be stale - re-request everything
  -- (guide 8.15).
  ["gmcp.Engine.Copyover"] = function() mdwui.requestFullPayload() end,

  -- Start of the top bar's connection timer: each (re)connection restarts it.
  ["sysConnectionEvent"] = function()
    mdwui.state.loginAt = os.time()
    mdwui.renderTopBar()
  end,

  -- The game's own lifecycle commands for this package (MDWUI_Update):
  -- gomudui = "remove" / "update". Guarded on that key, because Mudlet's
  -- native package install arrives on the same message.
  ["gmcp.Client.GUI"] = function() mdwui.onClientGui() end,

  ["sysUninstallPackage"] = function(event, package) mdwui.onUninstall(event, package) end,

  -- Self-update (MDWUI_Update). Mudlet raises the download events for EVERY
  -- download in the profile - the mapper's, MDW's - so those handlers match
  -- on the exact path we asked for; sysInstallPackage closes the swap and
  -- is what tells the watchdog to stay quiet.
  ["sysDownloadDone"] = function(event, path) mdwui.onDownloadDone(event, path) end,
  ["sysDownloadError"] = function(event, err, path) mdwui.onDownloadError(event, err, path) end,
  ["sysInstallPackage"] = function(event, package) mdwui.onInstallPackage(event, package) end,

  -- MDW bootstrap (MDWUI_Update): Mudlet resolves no package dependencies, so
  -- a profile carrying this package but no MDW installs MDW here. Every
  -- script in the profile has loaded by the time this fires, which is why
  -- mdw.version - a load-time assignment - can be trusted; calling ensureMdw
  -- at script-load time instead would read a version that arrives a moment
  -- later and throw away the load-order freedom the MDW contract gives us.
  ["sysLoadEvent"] = function() mdwui.ensureMdw() end,
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
