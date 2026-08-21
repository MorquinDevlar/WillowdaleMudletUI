--[[
  MDWUI_Config.lua
  Namespace, static configuration, and the MDW integration seeds for the
  WillowdaleMUD UI.

  This package is a CONSUMER of MDW (Mudlet Dockable Widgets). It follows
  MDW's integration contract: at load time it only seeds tables into the
  shared `mdw` namespace - it never calls MDW functions - so it works no
  matter which package loads or installs first. MDW runs mdwui.buildUI()
  every time it builds its UI, including after MDW package updates.

  Data contract: the game's Mudlet widget GMCP guide describes every GMCP
  package, field, and cadence this UI consumes. Field names below mirror
  that guide exactly.

  Dependencies: none (root module of this package).
]]

mdwui = mdwui or {}
-- Must match the mfile "package" name exactly: Mudlet reports this name in
-- sysUninstallPackage, and onUninstall's cleanup only fires on a match.
mdwui.packageName = "WillowdaleMudletUI"
-- Version-exposure convention shared by the Willowdale packages (mdw.version,
-- mapper.version): a plain string matching the mfile "version", assigned at
-- script-load time so any other script can read it at runtime with a guarded
-- lookup. Bump together with mfile - the smoke suite enforces the match.
mdwui.version = "0.1.16"
-- Hard requirement, not a preference: this package is built on the MDW 0.4
-- APIs (createBar, setPromptGauges/setPromptBarMenu, setWidgetRows/
-- setWidgetMenu, showContextMenu, findWidget and the scripted-control
-- functions, gameSettings, gamePackages ownership reaping) plus MDW 0.5's
-- font family (setFontFamily and the applyMainFont seed below). buildUI gates
-- ONCE on this minimum instead of guarding every call. mdw.version exists
-- from MDW 0.3.0 on, so nil means an older MDW still. Bump when we adopt a
-- newer MDW API.
--
-- 0.5.x rather than 0.4.x because the font family is the delivery mechanism
-- for it: a player sitting on 0.4.1 satisfies a 0.4.0 minimum, so ensureMdw
-- would leave them there and applyMainFont would never take effect. The
-- typeface verb itself stays guarded through capability() regardless.
--
-- 0.6.0 IS an API adoption: mdw.swapPackage. The package swap goes through it
-- because MDW is not the package being removed and so can uninstall and
-- install back to back and return what Mudlet actually said - which a package
-- cannot do for itself. The pre-0.6.0 path is kept as a fallback, because the
-- version gate stops this package BUILDING under an older MDW but `ui update
-- install` still works there, and that is how a player gets out of it.
mdwui.minMdwVersion = "0.6.1"
-- The MDW release this package installs when MDW is missing or too old
-- (mdwui.ensureMdw, MDWUI_Update.lua). Mudlet has NO package dependency
-- resolution - the mfile "dependencies" field is read by the package exporter
-- and by nothing else - so the pin above is only half a requirement without a
-- place to get it from. THE TWO MOVE TOGETHER: adopting a newer MDW API means
-- raising the minimum and this URL in the same edit, and never pinning
-- "latest" - MDW never updates itself, by design, so this package is the only
-- thing that ever moves its framework.
--
-- MDW's release tooling keeps the tag format (v<version>) and the asset name
-- (MDW.mpackage) as a contract, the same shape as our own releaseUrlFormat
-- below. Verify a tag exists before pinning it: an unpublished version here
-- makes every bootstrap download a GitHub error page instead of a package.
-- DERIVED, not a second literal: the updater has to be able to fetch an MDW
-- version this package's own constant does not name. When a release requires a
-- newer MDW than the one running, the requirement arrives in the feed (the
-- `mdw` field of releases.json) and the URL for it is built from the same
-- contract - which also makes it impossible for the pin and the URL to drift
-- apart, the thing the smoke suite had to check for before.
mdwui.mdwUrlFormat = "https://github.com/MorquinDevlar/mdw/releases/download/v%s/MDW.mpackage"
mdwui.mdwUrl = string.format(mdwui.mdwUrlFormat, mdwui.minMdwVersion)

-- Where the self-updater (MDWUI_Update.lua) looks. The GAME SERVER hosts both
-- files, and a player's client reads nothing else: a push to this repo's main
-- fires the server's GitHub webhook, which copies build/*.mpackage and
-- releases/releases.json out of the repo into static/resources/ui/. GitHub
-- releases are our own archive, not a distribution channel - nothing
-- player-facing points at them, so the tag scheme is no longer a contract.
--
-- The package file carries NO version in its name: the server keeps exactly
-- one copy, the newest, at a fixed path. The version lives in the feed
-- instead - releases.json, newest entry first, the same shape the mapper
-- package already ships against:
--   [ { "version": "3.0.0", "released": "2026-08-21", "changes": [ "..." ] } ]
--
-- Consequence for the release process: PUSHING MAIN IS DEPLOYING. There is no
-- separate publish step, and tools/release.sh is what keeps build/ and
-- releases/releases.json in step with the version before it pushes.
mdwui.updateBaseUrl = "https://updates.willowdalemud.com/static/resources/ui"
mdwui.releasesUrl = mdwui.updateBaseUrl .. "/releases.json"
mdwui.packageUrl = mdwui.updateBaseUrl .. "/" .. mdwui.packageName .. ".mpackage"

---------------------------------------------------------------------------
-- CONFIGURATION
---------------------------------------------------------------------------

mdwui.config = {
  -- Communication channel -> tab routing (mirrors the web client's
  -- channelToTab map in gmcp-ui.js). Unlisted channels land in Global.
  commTabs = { "All", "Room", "Global", "Tells", "Group" },
  channelToTab = {
    say = "Room", sayto = "Room", shout = "Room",
    broadcast = "Global", login = "Global", logins = "Global", chat = "Global",
    tell = "Tells", otell = "Tells",
    group = "Group",
  },

  -- Char.Inventory.Worn slot keys grouped as the web client's equipment
  -- panel (webclient-pure.html .eq-section markup): section header, then
  -- { wire slot key, display label } rows - the ring slots relabel as
  -- Mainhand/Offhand under Jewelry there.
  wornSections = {
    { header = "Weapons", slots = {
      { "weapon", "Mainhand" }, { "offhand", "Offhand" } } },
    { header = "Armor", slots = {
      { "head", "Head" }, { "body", "Body" }, { "back", "Back" },
      { "belt", "Belt" }, { "gloves", "Gloves" }, { "legs", "Legs" },
      { "feet", "Feet" } } },
    { header = "Jewelry", slots = {
      { "neck", "Neck" }, { "ringmainhand", "Mainhand" },
      { "ringoffhand", "Offhand" } } },
  },

  -- HP gauge color thresholds, matching the web client (low <= 33%,
  -- mid <= 66%).
  hpLowPct = 0.33,
  hpMidPct = 0.66,

  -- Graphical gauges (prompt layer, Combat widget, Group widget). The Qt
  -- colors transcribe webclient.css exactly: translucent track, 60%-alpha
  -- fill, #333 frame, 4px radius; HP's fill shifts amber/red at the shared
  -- thresholds, Balance dims while draining, group members band by percent.
  gauges = {
    frame = "border: 1px solid #333333; border-radius: 4px;",
    hpTrack = "rgba(40,130,55,20%)",
    hpFill = "rgba(60,160,80,60%)",
    hpFillMid = "rgba(200,160,40,60%)",
    hpFillLow = "rgba(220,60,50,70%)",
    aeTrack = "rgba(120,50,160,20%)",
    aeFill = "rgba(140,70,200,60%)",
    balTrack = "rgba(40,80,160,20%)",
    balFill = "rgba(60,110,200,60%)",
    balFillDrain = "rgba(50,90,160,50%)",
    enemyTrack = "rgba(180,50,50,20%)",   -- .combat-enemy-gauge-bar
    enemyFill = "rgba(200,60,60,60%)",
    grpTrack = "#111111",                 -- .gauge-bar base (group rows)
    grpHigh = "rgba(80,160,80,60%)",      -- .grp-hp-* bands
    grpMid = "rgba(190,170,60,60%)",
    grpLow = "rgba(200,120,50,60%)",
    grpCritical = "rgba(200,60,60,60%)",
    grpHeight = 14,                       -- .grp-gauge height
    grpGap = 7,                           -- .grp-member gap, drawn as the divider rule
    textColor = "#dddddd",
    -- pt, not px: 10pt (~13px) reads comfortably inside the 16px bar; the
    -- web client's 10px CSS label proved too small in Qt.
    fontSize = 10,
    headerFontSize = 8,                   -- .combat-section-header 10px CSS
    headerHeight = 14,
  },

  -- Which prompt-bar / Combat-widget elements show, before the player's own
  -- saved choices (the vertical-ellipsis menus persist into
  -- mdw.gameSettings). Values mirror the web client's promptBarSettings and
  -- combatWidgetSettings defaults; `info` is the enemy-names section.
  promptBarDefaults = { vitals = false, worth = true, hp = true, ae = true,
    balance = true, enemy = false },
  combatDefaults = { hp = true, ae = false, balance = false, enemy = true,
    info = true },

  -- Numpad walking is the package's own native key folder (src/keys/keys.json
  -- and src/keys/<folder>/keys.json): Mudlet installs and removes it with the
  -- package and shows it in the Keys editor; `ui numpad` only flips the folder
  -- with enableKey/disableKey, so this name must match the JSON exactly (the
  -- smoke suite checks).
  numpadKeyFolder = "Numpad Walking",

  -- The numpad walking toggle (MDWUI_Keys, `ui numpad`): on by default to
  -- match the web client, where it is unconditional; off hands the keypad
  -- back to typing numbers.
  keyDefaults = { numpad = true },

  -- decho color triplets used across the renderers, named for intent so a
  -- reskin is one edit here rather than a hunt through every renderer.
  colors = {
    label   = "198,183,138", -- section labels / slot names
    text    = "200,200,200", -- default body text
    dim     = "120,120,120", -- empty slots, timestamps, de-emphasis
    faint   = "102,102,102", -- empty-state texts (-nothing-, empty lists; #666)
    good    = "95,225,95",   -- healthy / positive
    warn    = "225,200,80",  -- mid health / attention
    bad     = "225,90,90",   -- low health / hostile
    aether  = "95,200,225",  -- AE pool
    link    = "140,190,235", -- clickable actions
    balance = "225,225,225", -- balance gauge

    -- Equipment item flags [C][E][Q] (webclient.css .eq-flag-*)
    flagBracket   = "128,128,128", -- .eq-flag brackets (#808080)
    flagCursed    = "175,0,0",     -- (#af0000)
    flagEnchanted = "136,136,255", -- (#8888ff)
    flagQuest     = "230,168,0",   -- (#e6a800)

    -- Shared web-client panel palette: webclient.css .char-* transcribed
    -- exactly, reused wherever the web client reuses the same hex - the
    -- keychain table's .key-type is this gold, .key-location this parchment,
    -- .key-where and every header row this label gray.
    charHeader  = "232,220,200", -- .char-header-name / .key-location (#e8dcc8)
    charGold    = "196,163,90",  -- .char-header-class / .key-type (#c4a35a)
    charAttr    = "109,186,109", -- .char-attr core attributes (#6dba6d)
    charCyan    = "92,179,179",  -- .char-cyan defense column (#5cb3b3)
    charBlue    = "122,158,199", -- .char-blue power column (#7a9ec7)
    charLabel   = "136,136,136", -- .char-label / .key-where (#888)
    charDivider = "58,53,48",    -- .char-header / .char-divider rule (#3a3530)
    itemTeal    = "92,179,165",  -- .eq-value / .inv-name / .key-sequence (#5cb3a5)

    -- Top bar version strip: one hue per package so the three versions read
    -- apart at a glance without separators. Only the digits take these -
    -- the "v" and the dots stay dim, so the punctuation reads as structure
    -- rather than as part of the number.
    verUI       = "92,179,165",  -- this package
    verMDW      = "122,158,199", -- the MDW framework
    verMapper   = "168,123,209", -- the mapper package

    -- Group widget (webclient.css .grp-*). The web client carries
    -- leader/aggro on the member card's BORDER, which a row of Qt labels
    -- has nowhere to put, so those two colors land on the member's name.
    -- Green rather than the web client's gold .grp-member.is-leader border:
    -- on a name (not a border) gold reads as another class/tag color, so the
    -- leader takes green against the aggro red the same column can show.
    grpLeader   = "109,186,109", -- leader name + "(leader)"
    grpTag      = "138,131,120", -- .grp-tag and .grp-location (#8a8378)
    grpClass    = "156,143,176", -- .grp-class (#9c8fb0)
    grpAuto     = "111,175,111", -- .grp-auto.is-on (#6faf6f)
    grpManual   = "111,106,99",  -- .grp-auto, the quiet default (#6f6a63)

    -- Quests widget (webclient.css .qst-*): the status colors mirror the
    -- telnet ansi aliases - gold ready, azure active, purple rumor.
    questReady   = "224,176,32",  -- .qst-status-ready (#e0b020)
    questActive  = "74,163,214",  -- .qst-status-active (#4aa3d6)
    questRumor   = "168,123,209", -- .qst-rumor / .qst-status-rumor (#a87bd1)
    questObj     = "153,153,153", -- .qst-obj objective lines (#999)
    questObjDone = "79,122,79",   -- .qst-obj-done (#4f7a4f)
    questDone    = "79,165,95",   -- .qst-status-done (#4fa55f)

    -- Journal widget (webclient.css .qj-detail-*): the expanded per-row
    -- quest detail block.
    qjDesc = "184,172,152", -- .qj-detail-desc step/completion prose (#b8ac98)
    qjKv   = "201,189,166", -- .qj-detail-kv / -quote / -reward (#c9bda6)
    qjKey  = "138,127,109", -- .qj-detail-key muted label (#8a7f6d)
    qjBeat = "184,154,106", -- .qj-detail-beat giver's recalled counsel (#b89a6a)
  },
}

-- Runtime state shared across the modules. Preserved (`or`) across script
-- re-runs, NOT reset: the widget/handler/timer registries are the only record
-- of what a previous run created, and wiping them mid-session would orphan a
-- live ticker or widget from lifecycle cleanup (buildUI's killAllTimers could
-- no longer see the old affects ticker, so re-runs would stack duplicates).
mdwui.state = mdwui.state or {
  widgets = {},        -- our widget names -> true (for cleanup on uninstall)
  handlers = {},       -- named event handlers we registered (for cleanup)
  timers = {},         -- repeating timers we own (for cleanup)
  affectsReceivedAt = 0, -- os.time() when Char.Affects last arrived (local countdown)
  questDetailId = nil, -- quest id whose detail view is showing (nil = list view)
  questExpanded = {},  -- quest id -> true while its objective lines are open;
                       -- module-lifetime like the web client's questExpanded,
                       -- so frequent re-renders don't snap an open quest shut
  -- Quest/Journal caches, all seeded lazily (see MDWUI_Quests seedState) so a
  -- state table preserved from an older script run gains them on the fly:
  --   questDetailCache   id -> Char.Quest.Detail payload (web questDetailCache)
  --   questDetailPending id -> true while a detail request is in flight
  --   questCompletedCache last full completed list (progress-only pushes omit it)
  --   journalExpanded    row key -> true for expanded Journal rows
  --   journalFilters     { zone, status, category } filter selections
  --   charName           last Char.Info.name, to spot a character switch
  -- loginAt (runtime): os.time() of the current connection - the start the
  -- top bar's connection timer counts up from; refreshed by
  -- sysConnectionEvent, seeded at build as a fallback for mid-session
  -- installs.
  -- hpFillCss / balFillCss (runtime): last-applied prompt-gauge fill
  -- styles, so the per-payload updates only restyle on a band crossing
  -- Self-update keys (MDWUI_Update, all runtime): updateBusyAt (os.time() of
  -- the download in flight - a timestamp, so a stalled one goes stale),
  -- updateFeedPath / updateFile / updateUrl (what we asked for, matched
  -- against sysDownloadDone's path), updateVersion (the release on offer),
  -- updateManual (`ui update` speaks even with nothing to say; the session
  -- check does not), updateCheckedThisSession, and updateInstalled - the
  -- all-clear the watchdog reads, which only works because this table
  -- survives the package swap in the Lua state.
  -- MDW bootstrap keys (MDWUI_Update, runtime): mdwFile (the download in
  -- flight, matched against sysDownloadDone's path) and mdwFetchedFor - the
  -- minMdwVersion the last bootstrap attempt was made for, so a dead network
  -- cannot turn into a retry loop while an update that RAISES the pin still
  -- gets an attempt of its own. It is not a boolean for that reason: this
  -- table survives a package swap, and a boolean made a session that had ever
  -- fetched MDW unable to ever fetch it again.
}

---------------------------------------------------------------------------
-- MDW INTEGRATION SEEDS
-- Tables only - no MDW calls - so Mudlet's script/install order is free.
---------------------------------------------------------------------------

mdw = mdw or {}

-- Our widgets replace the demo set (and reuse some of its names).
mdw.loadExamples = false

mdw.gameConfig = mdw.gameConfig or {}
-- Brand MDW's chrome as this game's UI: the admin menu reads
-- "Uninstall WillowdaleUI", the ready message names it likewise.
mdw.gameConfig.uiName = "WillowdaleUI"
-- The face this UI is drawn in, and the reason the package ships
-- FiraCodeWillowdale-Regular.ttf: Mudlet loads a package's fonts on install and
-- unloads them on uninstall, so the font is ours to supply and ours to name.
-- Seeded rather than assumed - MDW's own default is a neutral monospace, and
-- gameConfig is the seam where a game states its preference (MDW validates it
-- against getAvailableFonts and falls back on its own if it is missing).
-- The name is the font's own family string, not the file name - Mudlet
-- matches on family. Fira Code is what the web client and the website render
-- in, so a player moving between them sees one face. The bundled build is the
-- web side's own: no ligature features (its GSUB carries only ccmp and locl,
-- so "->" stays two characters) and the full box-drawing range the tinymap
-- needs. It is a SUBSET though - any glyph outside it, like U+2228, is
-- silently drawn from another family at another width, so check a character
-- is in the font before printing it.
--
-- Renamed from plain "Fira Code" because Mudlet registers a package font
-- with QFontDatabase::addApplicationFont, which does not disambiguate two
-- families of the same name: a player with stock Fira Code installed would
-- get one or the other, unpredictably, ligatures and all. The web client
-- keeps the plain name - there @font-face binds the name to a downloaded
-- file, so no system font can shadow it. Re-syncing the font from the web
-- side means re-applying this rename.
mdw.gameConfig.fontFamily = "Fira Code Willowdale"
-- ...and ask MDW to put the MAIN console in it too, so the game's own text
-- matches the widgets instead of sitting in whatever face the profile had.
-- MDW keeps this opt-in and captures the player's original family before it
-- applies one, restoring it on a full uninstall. Inert before MDW 0.5, which
-- is where applyMainFont arrived - an unknown gameConfig key is merged into
-- mdw.config and simply never read.
mdw.gameConfig.applyMainFont = true
-- The server drives the prompt bar through GMCP (Char.Vitals.prompt/prompt2
-- arrive as real ANSI), so MDW's line-capture trigger must stay out of the way.
mdw.gameConfig.usePromptTrigger = false
-- Room for the gauge row plus the one default text line (Worth) on a fresh
-- install; a player's own saved bar height still wins (gameConfig merges as
-- defaults). Re-enabling the Vitals line grows the bar via
-- ensurePromptBarHeight at toggle time.
mdw.gameConfig.promptBarHeight = 48

-- MDW runs this on every UI build (install, profile load, MDW update). The
-- closure indirection matters: buildUI is defined in a later script, but is
-- only CALLED at setup time, long after every script has loaded.
mdw.onReady = mdw.onReady or {}
mdw.onReady[mdwui.packageName] = function()
  mdwui.buildUI()
end

-- The teardown mirror: stop our repeating timers (the affects ticker) while
-- the widgets they render into still exist - buildUI restarts them on the
-- next setup. Same closure indirection as onReady.
mdw.onTeardown = mdw.onTeardown or {}
mdw.onTeardown[mdwui.packageName] = function()
  if mdwui and mdwui.killAllTimers then mdwui.killAllTimers() end
end

-- Register for co-removal: MDW's one-button full uninstall removes this
-- package first (mdwui.onUninstall runs while MDW's APIs are still alive),
-- then MDW itself - so the player's "Uninstall WillowdaleUI" takes down the
-- whole UI.
mdw.gamePackages = mdw.gamePackages or {}
mdw.gamePackages[mdwui.packageName] = true
