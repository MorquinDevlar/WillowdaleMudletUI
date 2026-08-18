--[[
  MDWUI_Config.lua
  Namespace, static configuration, and the MDW integration seeds for the
  Willowdale MUD UI.

  This package is a CONSUMER of MDW (Mudlet Dockable Widgets). It follows
  MDW's integration contract: at load time it only seeds tables into the
  shared `mdw` namespace - it never calls MDW functions - so it works no
  matter which package loads or installs first. MDW runs mdwui.buildUI()
  every time it builds its UI, including after MDW package updates.

  Data contract: documentation/Mudlet_Widget_GMCP_Guide.md in the
  WillowdaleMUD repo describes every GMCP package, field, and cadence this
  UI consumes. Field names below mirror that guide exactly.

  Dependencies: none (root module of this package).
]]

mdwui = mdwui or {}
mdwui.packageName = "MDW_UI"

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

  -- Char.Inventory.Worn slot keys, in display order.
  wornSlots = {
    "weapon", "offhand", "head", "neck", "body", "back", "belt", "gloves",
    "ringmainhand", "ringoffhand", "legs", "feet",
  },

  -- Text gauges (Combat widget). Width in characters; color thresholds match
  -- the web client (low <= 33%, mid <= 66%).
  gaugeWidth = 16,
  hpLowPct = 0.33,
  hpMidPct = 0.66,

  -- decho color triplets used across the renderers, named for intent so a
  -- reskin is one edit here rather than a hunt through every renderer.
  colors = {
    label   = "198,183,138", -- section labels / slot names
    text    = "200,200,200", -- default body text
    dim     = "120,120,120", -- empty slots, timestamps, de-emphasis
    good    = "95,225,95",   -- healthy / positive
    warn    = "225,200,80",  -- mid health / attention
    bad     = "225,90,90",   -- low health / hostile
    aether  = "95,200,225",  -- AE pool
    link    = "140,190,235", -- clickable actions
    badge   = "190,150,225", -- item detail badges (cursed/enchanted/...)
    balance = "225,225,225", -- balance gauge
  },
}

-- Runtime state shared across the modules. Rebuilt values only - everything
-- here can be regenerated from the gmcp table, so losing it on reload is fine.
mdwui.state = {
  widgets = {},        -- our widget names -> true (for cleanup on uninstall)
  handlers = {},       -- named event handlers we registered (for cleanup)
  timers = {},         -- repeating timers we own (for cleanup)
  affectsReceivedAt = 0, -- os.time() when Char.Affects last arrived (local countdown)
  questDetailId = nil, -- quest id whose detail view is showing (nil = list view)
}

---------------------------------------------------------------------------
-- MDW INTEGRATION SEEDS
-- Tables only - no MDW calls - so Mudlet's script/install order is free.
---------------------------------------------------------------------------

mdw = mdw or {}

-- Our widgets replace the demo set (and reuse some of its names).
mdw.loadExamples = false

mdw.gameConfig = mdw.gameConfig or {}
-- The server drives the prompt bar through GMCP (Char.Vitals.prompt/prompt2
-- arrive as real ANSI), so MDW's line-capture trigger must stay out of the way.
mdw.gameConfig.usePromptTrigger = false

-- MDW runs this on every UI build (install, profile load, MDW update). The
-- closure indirection matters: buildUI is defined in a later script, but is
-- only CALLED at setup time, long after every script has loaded.
mdw.onReady = mdw.onReady or {}
mdw.onReady[mdwui.packageName] = function()
  mdwui.buildUI()
end
