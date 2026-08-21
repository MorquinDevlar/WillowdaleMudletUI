--[[
  MDWUI_Commands.lua
  The `ui` command: this whole interface under keyboard control.

  Why it exists: everything the mouse can do to the UI - reveal a widget,
  regroup it, resize a dock, switch a channel tab, page the journal - must be
  doable from the keyboard too, for the many players who would rather not let
  go of it mid-session. One dispatcher (mdwui.command) serves both callers:
  the shipped `ui` alias, and the smoke suite, which drives it directly with
  no Qt in the room.

  Output goes to the MAIN console, never into a widget: it is where the
  command was typed, it survives whatever the player has hidden or closed,
  and it scrolls, searches and copies like the rest of the session. The layout
  work itself belongs to MDW's set-semantics capability functions (0.4+); every
  one is looked up guarded, so an older MDW answers with a message instead of
  an error - the same style as the rest of this package.

  Unknown input is never forwarded to the game. The server has no `ui` command
  (only `config <channel> ui`), and half-shadowing a future one would be worse
  than saying "unknown".

  This module speaks cecho with Mudlet's NAMED colours, unlike every widget
  renderer in the package (decho with the RGB palette transcribed from the web
  client's CSS). Two reasons: the main console prints literal English, where
  "<gold>" beside the words reads at a glance and "<196,163,90>" does not; and
  the widget palette exists to match a web page this text has nothing to do
  with, so sharing it would tie the `ui` output to changes in that page.

  Dependencies: MDWUI_Config.lua, MDWUI_Core.lua, MDWUI_Keys.lua (the numpad
  toggle), and the widget modules whose wrappers the verbs call.
]]

---------------------------------------------------------------------------
-- OUTPUT (main console)
-- NOTE on angle brackets: an UNRECOGNISED tag prints literally. Mudlet's
-- _Echos.Process (GUIUtils.lua) hands a "<word>" whose word is not in
-- color_table straight to the text stream, so "ui show <widget>" arrives
-- with its brackets intact. Only <r> <b> <i> <u> <s> <o> (the attribute
-- tags) and real colour names are swallowed, so placeholders avoid those.
-- Text that came from the GAME is the exception: a quest title could read
-- "<gold>", so game strings go through plain() before they are echoed.
---------------------------------------------------------------------------

--- The command surface's colours, by name. Verb colours group the overview's
-- sections by what a command touches, which is the only structure a table of
-- one-line commands has left once the grid is gone.
local P = {
  banner = "sky_blue",  -- the welcome line
  head   = "cyan",      -- headings and the labels of listings
  text   = "grey",      -- body text, descriptions, values
  name   = "white",     -- the names a state line is about (package versions)
  tag    = "gold",      -- the [ui] marker
  good   = "green",     -- a toggle that is on
  bad    = "firebrick", -- a toggle that is off (the game's config table: on green, off red)
  dim    = "dim_gray",  -- asides, the overview's footer lines
  -- The options/explanation column: the game paints it dim, but not as dark as
  -- dim_gray. Only names in Mudlet's color_table (GUIUtils.lua) may go here -
  -- anything else prints literally - and its greys are dim_gray, slate_gray,
  -- light_slate_gray, light_gray and gray; dark_gray is NOT one of them.
  opts   = "light_slate_gray",
  cfgHead = "yellow",   -- the Command:/Value:/Options: header, as the game paints its config table
  verbWidgets = "green",
  verbLayout  = "YellowGreen",
  verbLook    = "gold",
  verbPanels  = "DodgerBlue",
  verbMaint   = "OliveDrab",
}

--- Text that came from the game (a quest name, a widget's console line) can
-- hold a "<" of its own, and a colour name behind it would be read as a tag.
-- Drop them on the way out: a missing angle bracket beats a mangled line.
-- Player-typed text quoted back gets the same treatment.
local function plain(text)
  return (tostring(text):gsub("<", ""))
end

--- One result or error line, tagged so it reads apart from game text. Errors
-- and results share the tag on purpose: a player scanning back for what the
-- client said looks for one marker, not two.
function mdwui.say(text)
  if not cecho then return end
  cecho(string.format("<%s>[ui] <%s>%s\n", P.tag, P.text, tostring(text)))
end

--- A block line without the tag: listings, tables, the overview.
local function line(text)
  if cecho then cecho(tostring(text) .. "\n") end
end

local function emit(text)
  if cecho then cecho(tostring(text)) end
end

--- A clickable command on the main console. The callback re-enters the
-- dispatcher instead of send()ing: `ui` is a client command, so the outbound
-- rule (widget affordances send real game commands) simply does not apply -
-- there is no game command to send.
function mdwui.sayLink(text, command, hint)
  if not cechoLink then
    emit(text)
    return
  end
  cechoLink(text, function() mdwui.command(command) end, hint or ("ui " .. command), true)
end

--- Pad to a column width. Measured with # on purpose: every string padded
-- here is ASCII, and the colour tags are added after the padding.
local function cell(text, width)
  local gap = width - #text
  return text .. string.rep(" ", gap > 0 and gap or 1)
end

--- Greedy word wrap for the overview's last column, so no row runs past the
-- 80 columns a MUD screen is written for. A "|" ends a piece too (and stays
-- on the left): to a wrapper that only knows spaces, the theme list and
-- `<category>|back|page <n>|...` are one unbreakable word. A piece wider than
-- the column goes on a line of its own rather than being cut in half.
-- @return a list of lines, never nil (an empty text gives an empty list)
local function wrapText(text, width)
  local pieces = {}
  local from, len = 1, #text
  while from <= len do
    local at = text:find("[|%s]", from)
    if not at then
      pieces[#pieces + 1] = text:sub(from)
      break
    elseif text:sub(at, at) == "|" then
      pieces[#pieces + 1] = text:sub(from, at)
      from = at + 1
    else
      -- the run of spaces rides along with its word, so the wide gaps that
      -- separate an option list from its explanation survive the wrap
      local stop = at
      while stop <= len and text:sub(stop, stop):match("%s") do stop = stop + 1 end
      pieces[#pieces + 1] = text:sub(from, stop - 1)
      from = stop
    end
  end
  local out, current = {}, ""
  for _, piece in ipairs(pieces) do
    local candidate = current .. piece
    if current == "" or #(candidate:gsub("%s+$", "")) <= width then
      current = candidate
    else
      out[#out + 1] = (current:gsub("%s+$", ""))
      current = piece
    end
  end
  if current ~= "" then out[#out + 1] = (current:gsub("%s+$", "")) end
  return out
end

---------------------------------------------------------------------------
-- PARSING
---------------------------------------------------------------------------

local function tokenize(text)
  local words = {}
  for word in tostring(text or ""):gmatch("%S+") do words[#words + 1] = word end
  return words
end

--- The remainder of the line from token `i`, re-joined with single spaces.
-- None of the arguments that can hold spaces (a zone name, a bound command)
-- is whitespace-sensitive, so collapsing runs is harmless.
local function rest(words, i)
  return table.concat(words, " ", i, #words)
end

--- `+n` / `-n` relative to `current`, else an absolute number; nil when the
-- text is not a size at all.
local function parseSize(text, current)
  local sign, digits = tostring(text or ""):match("^([+-])(%d+)$")
  if sign then
    local delta = tonumber(digits)
    return (tonumber(current) or 0) + (sign == "-" and -delta or delta)
  end
  return tonumber(text)
end

local ON_WORDS = { on = true, yes = true, ["true"] = true, ["1"] = true, enable = true, show = true }
local OFF_WORDS = { off = true, no = true, ["false"] = true, ["0"] = true, disable = true, hide = true }

--- An on/off argument; a missing one TOGGLES, which is the bare form's whole
-- contract. Returns nil when the word is neither.
local function parseOnOff(text, current)
  if text == nil or text == "" then return not current end
  local key = tostring(text):lower()
  if ON_WORDS[key] then return true end
  if OFF_WORDS[key] then return false end
  return nil
end

--- Exact match first, then unique prefix - the rule every name in this
-- command follows (subcommands, option keys, channel tabs, journal
-- categories), so a spoken shorthand like `ui sh que` lands.
-- @return name on a hit; nil plus the candidate list when ambiguous/unknown
local function resolvePrefix(names, query)
  local q = tostring(query or ""):lower()
  if q == "" then return nil, {} end
  for _, name in ipairs(names) do
    if name:lower() == q then return name end
  end
  local matches = {}
  for _, name in ipairs(names) do
    if name:lower():sub(1, #q) == q then matches[#matches + 1] = name end
  end
  if #matches == 1 then return matches[1] end
  return nil, matches
end

--- At most five candidates, comma-joined: a longer list is noise on one line.
local function candidateText(candidates)
  local shown = {}
  for i = 1, math.min(5, #candidates) do shown[i] = candidates[i] end
  return table.concat(shown, ", ")
end

---------------------------------------------------------------------------
-- WIDGET VOCABULARY
-- Spoken shorthands the game's own words suggest, checked BEFORE MDW's
-- name/title matching so `eq` never has to be spelled out and `chat` finds
-- the widget whose title is Communications.
---------------------------------------------------------------------------

mdwui.widgetSynonyms = {
  eq = "Equipment", equip = "Equipment", worn = "Equipment",
  inv = "Inventory", bag = "Inventory",
  char = "Character", stats = "Character",
  chat = "Comm", comms = "Comm", comm = "Comm", channels = "Comm",
  quest = "Quests", log = "Journal",
  keys = "Keyring", herbs = "Forage",
  grp = "Group", party = "Group",
  fight = "Combat", buffs = "Affects", effects = "Affects",
}

--- Widgets are addressed by TITLE in output, matching the tab labels the
-- player sees; internal names (and group names) never print.
local function widgetTitle(w)
  return (w and (w.title or w.name)) or "?"
end

--- Resolve a typed widget reference, printing the failure itself - callers
-- read `local w = mdwui.resolveWidget(arg); if not w then return end`.
function mdwui.resolveWidget(query)
  local text = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    mdwui.say("Name a widget, for example: ui show quests")
    return nil
  end
  text = plain(text) -- quoted back below; the player could have typed a tag
  local synonym = mdwui.widgetSynonyms[text:lower()]
  if synonym and mdw.widgets and mdw.widgets[synonym] then
    return mdw.widgets[synonym]
  end
  if not mdw.findWidget then
    mdwui.say("Naming widgets needs MDW 0.4+ (mdw.findWidget is missing).")
    return nil
  end
  local w, candidates = mdw.findWidget(synonym or text)
  if w then return w end
  if candidates and #candidates > 0 then
    local titles = {}
    for i = 1, math.min(5, #candidates) do
      titles[i] = widgetTitle(mdw.widgets[candidates[i]])
    end
    mdwui.say(string.format("No widget matches '%s'. Try: %s", text, table.concat(titles, ", ")))
  else
    mdwui.say(string.format("No widget matches '%s'. Type ui for the list.", text))
  end
  return nil
end

---------------------------------------------------------------------------
-- MDW CAPABILITIES
---------------------------------------------------------------------------

--- Every MDW 0.4 function is looked up through here. This package installs
-- beside whatever MDW the player already has, so a missing capability must
-- name the fix rather than raise.
local function capability(name)
  local fn = mdw and mdw[name]
  if type(fn) == "function" then return fn end
  mdwui.say(string.format("That needs MDW 0.4 or newer (mdw.%s is missing).", name))
  return nil
end

--- Turn an MDW return code into the player's next step, so the same failure
-- always reads the same way whichever verb hit it.
local function explain(code, detail, subject)
  if code == "unknown_widget" then
    return string.format("No widget named '%s'. Type ui for the list.", tostring(detail or subject))
  elseif code == "sidebar_hidden" then
    return string.format("The %s sidebar is off - ui %s on", tostring(detail), tostring(detail))
  elseif code == "fill" then
    return string.format("%s fills the bottom of its dock; resize the rows above it instead.", subject)
  elseif code == "target_hidden" then
    return string.format("%s is hidden - show it first.", subject)
  elseif code == "same" then
    return "A widget cannot group with itself."
  elseif code == "alone" then
    return string.format("%s is already alone in its group.", subject)
  elseif code == "unsupported" then
    return "Scrolling widgets needs Mudlet 4.17 or newer."
  end
  return string.format("%s: %s", subject, tostring(code))
end

---------------------------------------------------------------------------
-- OPTION KEYS
-- Listed in the order the vertical-ellipsis menus show them, so the keyboard
-- and the mouse describe the same panel in the same sequence.
---------------------------------------------------------------------------

local PROMPT_KEYS = { "vitals", "worth", "hp", "ae", "balance", "enemy" }
local COMBAT_KEYS = { "hp", "ae", "balance", "enemy", "info" }
local JOURNAL_CATEGORIES = { "books", "documents", "quests", "rumors", "observations", "notes" }

--- Print one settings section as `key on  key off ...`. The colour goes on
-- the whole pair, not between the words: split colour would break "worth on"
-- into two separately painted words instead of one readable phrase. Green/red is the
-- game's own config palette, so `ui prompt`, `ui combat` and the overview's
-- value column answer the same question in the same two colours.
local function showToggles(label, keys, settings)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = string.format("<%s>%s %s", settings[key] and P.good or P.bad,
      key, settings[key] and "on" or "off")
  end
  mdwui.say(label .. ":")
  line("  " .. table.concat(parts, "  "))
end

---------------------------------------------------------------------------
-- REFRESH AND DEBUG
---------------------------------------------------------------------------

-- What `ui refresh <what>` asks for. These are Form A requests (guide 3):
-- the GMCP package name IS the node, the body an empty object. Grouped the
-- way a player thinks about the screen ("my equipment", "the map") rather
-- than the way the namespaces nest, so one word refills one widget.
local REFRESH_ORDER = { "all", "character", "vitals", "inventory", "equipment", "keyring",
  "forage", "affects", "quests", "journal", "comm", "room", "group", "map" }
local REFRESH_NODES = {
  character = { "Char.Info", "Char.Attributes", "Char.Worth" },
  vitals = { "Char.Vitals" },
  inventory = { "Char.Inventory.Backpack.Items", "Char.Inventory.Backpack.Summary" },
  equipment = { "Char.Inventory.Worn" },
  keyring = { "Char.Inventory.Keyring" },
  forage = { "Char.Inventory.Ingredients" },
  affects = { "Char.Affects" },
  quests = { "Char.Quests" },
  journal = { "Char.Journal" },
  comm = { "Comm.History" },
  room = { "Room.Info" },
  group = { "Group" },
  map = { "Client.Map" },
}

-- A whole payload is thousands of lines; the cap is what keeps `ui debug
-- gmcp` from scrolling a session's backlog away. Strings are clipped for the
-- same reason - a book's content is one field.
local DUMP_MAX_LINES = 400
local DUMP_MAX_DEPTH = 12
local DUMP_MAX_STRING = 120

local function dumpAdd(out, text)
  if #out.lines >= DUMP_MAX_LINES then
    out.cut = out.cut + 1
    return
  end
  out.lines[#out.lines + 1] = text
end

--- One GMCP value as sorted, indented lines. Written out longhand instead of
-- with display()/yajl: those print straight to Mudlet's console in their own
-- format, while everything `ui` says has to go through one tagged stream (and
-- the headless suite has neither function).
local dumpValue

local function dumpChildren(out, value, depth)
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, key in ipairs(keys) do dumpValue(out, tostring(key), value[key], depth) end
end

dumpValue = function(out, key, value, depth)
  local pad = string.rep("  ", depth)
  if type(value) ~= "table" then
    local text = tostring(value)
    if type(value) == "string" then
      text = #value > DUMP_MAX_STRING and (value:sub(1, DUMP_MAX_STRING) .. "...") or value
      text = '"' .. text .. '"'
    end
    dumpAdd(out, pad .. key .. " = " .. text)
  elseif depth >= DUMP_MAX_DEPTH then
    dumpAdd(out, pad .. key .. ": ...")
  elseif next(value) == nil then
    dumpAdd(out, pad .. key .. ": {}")
  else
    dumpAdd(out, pad .. key .. ":")
    dumpChildren(out, value, depth + 1)
  end
end

--- One settings section as sorted `key=value` pairs. A nested table folds onto
-- the same line: one level is all this package's settings ever have, and a
-- tree would bury the two lines that matter.
local function settingsText(section)
  local keys, parts = {}, {}
  for k in pairs(section) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local value = section[key]
    if type(value) == "table" then
      local inner = {}
      for k, v in pairs(value) do inner[#inner + 1] = tostring(k) .. "=" .. tostring(v) end
      table.sort(inner)
      parts[#parts + 1] = key .. "={" .. table.concat(inner, ", ") .. "}"
    else
      parts[#parts + 1] = key .. "=" .. tostring(value)
    end
  end
  return table.concat(parts, "  ")
end

local function countPairs(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

---------------------------------------------------------------------------
-- THE COMMAND TABLE
-- Ordered array of { name, aliases, usage, help, run }. `run` takes the
-- token array (words[1] is the verb itself) and the raw line.
---------------------------------------------------------------------------

local COMMANDS
local resolveCommand
local setSidebar

--- The occupant of one dock row / float, as `[Member Member* Member]` with
-- the front tab starred - the shape both `ui` and `ui list` print.
local function occupantText(occ)
  local parts = {}
  for _, member in ipairs(occ.members or {}) do
    parts[#parts + 1] = member.title .. (member.name == occ.active and "*" or "")
  end
  return "[" .. table.concat(parts, " ") .. "]"
end

--- Shared by show/hide/toggle/focus: resolve, call, report.
local function visibility(words, fnName, doneText, alreadyText)
  local w = mdwui.resolveWidget(rest(words, 2))
  if not w then return end
  local fn = capability(fnName)
  if not fn then return end
  local ok, code, detail = fn(w.name)
  if not ok then
    mdwui.say(explain(code, detail, widgetTitle(w)))
    return
  end
  if fnName ~= "hideWidget" then mdwui.state.focusWidget = w.name end
  mdwui.say(string.format("%s %s.", widgetTitle(w),
    code == "already" and alreadyText or doneText))
end

--- The Comm widget, or nil plus a message: every `ui comm` form needs it.
local function commWidget()
  local w = mdw.widgets and mdw.widgets["Comm"]
  if w and w.tabs then return w end
  mdwui.say("The Communications widget is not built.")
  return nil
end

--- The journal category slugs the server offered, or the six known ones when
-- no counts payload has landed yet. The server's titles are the capitalised
-- slugs, so matching slugs covers both spellings.
local function journalCategories()
  local out = {}
  for _, category in ipairs(mdwui.tbl(mdwui.tbl(mdwui.tbl(gmcp and gmcp.Char).Journal).categories)) do
    if category.slug then out[#out + 1] = category.slug end
  end
  if #out == 0 then
    for _, slug in ipairs(JOURNAL_CATEGORIES) do out[#out + 1] = slug end
  end
  return out
end

--- Which journal row key a quest id owns: active quests render as `a:<id>`,
-- completions as `d:<id>` (MDWUI_Quests renderQuestJournalInto).
local function questRowKey(id)
  local quests = mdwui.tbl(mdwui.tbl(gmcp and gmcp.Char).Quests)
  for _, quest in ipairs(mdwui.tbl(quests.active)) do
    if tostring(quest.id) == tostring(id) then return "a:" .. tostring(id) end
  end
  return "d:" .. tostring(id)
end

COMMANDS = {
  { name = "help", aliases = { "?" },
    usage = "ui help [<command>]",
    help = "Detail for one command. Bare `ui` lists the whole surface.",
    run = function(words)
      if not words[2] then
        mdwui.renderOverview()
        return
      end
      local cmd, candidates = resolveCommand(words[2])
      if not cmd then
        mdwui.say(string.format("Unknown command '%s'.%s", plain(words[2]),
          (candidates and #candidates > 0) and (" Did you mean: " .. candidateText(candidates)) or
          " Type ui for the list."))
        return
      end
      mdwui.say(cmd.usage)
      line("  " .. cmd.help)
    end },

  { name = "list", aliases = { "layout", "containers" },
    usage = "ui list",
    help = "The whole layout: docks, rows, groups, tabs, heights, floating, hidden, fonts, theme.",
    run = function()
      local fn = capability("describeLayout")
      if not fn then return end
      local info = fn()
      mdwui.say("Layout:")
      line(string.format("  <%s>Sidebars <%s>left %s %dpx  right %s %dpx   <%s>prompt bar %s   <%s>theme %s",
        P.head, P.text,
        info.sidebars.left.visible and "on" or "off", info.sidebars.left.width or 0,
        info.sidebars.right.visible and "on" or "off", info.sidebars.right.width or 0,
        P.text, info.promptBar.visible and "on" or "off",
        P.text, tostring(info.theme)))
      line(string.format("  <%s>Fonts <%s>main %s  menu %s  header %s  prompt %s",
        P.head, P.text, tostring(info.fonts.main), tostring(info.fonts.menu),
        tostring(info.fonts.header), tostring(info.fonts.prompt)))
      for _, side in ipairs({ "left", "right" }) do
        line(string.format("  <%s>%s dock:", P.head, mdwui.titleCase(side)))
        local rows = info.docks[side].rows
        if #rows == 0 then
          line(string.format("    <%s>empty", P.dim))
        end
        for _, row in ipairs(rows) do
          for _, occ in ipairs(row.occupants) do
            line(string.format("    <%s>%s <%s>%s", P.text, occupantText(occ), P.dim,
              occ.fill and "fills" or (tostring(math.floor(occ.height or 0)) .. "px")))
          end
        end
      end
      local floats = {}
      for _, occ in ipairs(info.floating) do floats[#floats + 1] = occupantText(occ) end
      line(string.format("  <%s>Floating <%s>%s", P.head, P.text,
        #floats > 0 and table.concat(floats, " ") or "none"))
      local hidden = {}
      for _, entry in ipairs(info.hidden) do
        hidden[#hidden + 1] = string.format("%s (%s)", entry.title, entry.reason)
      end
      line(string.format("  <%s>Hidden <%s>%s", P.head, P.text,
        #hidden > 0 and table.concat(hidden, ", ") or "none"))
    end },

  { name = "show",
    usage = "ui show <widget>",
    help = "Reveal a widget and front its tab. It returns where it was - its old group, "
      .. "else the end of its old dock - never floating in the middle.",
    run = function(words) visibility(words, "showWidget", "is showing", "was already at the front") end },

  { name = "hide",
    usage = "ui hide <widget>",
    help = "Close a widget's tab (its siblings stay), or hide the group when it is alone in one.",
    run = function(words) visibility(words, "hideWidget", "is hidden", "was already hidden") end },

  { name = "toggle",
    usage = "ui toggle <widget>",
    help = "Hide a shown widget, show a hidden one.",
    run = function(words)
      local w = mdwui.resolveWidget(rest(words, 2))
      if not w then return end
      if not (mdw.isWidgetShown and mdw.showWidget and mdw.hideWidget) then
        capability("showWidget")
        return
      end
      local shown = mdw.isWidgetShown(w)
      visibility(words, shown and "hideWidget" or "showWidget",
        shown and "is hidden" or "is showing", shown and "was already hidden" or "was already at the front")
    end },

  { name = "focus", aliases = { "front" },
    usage = "ui focus <widget>",
    help = "Front a widget's tab and raise it if it floats. Also the widget `ui scroll` uses by default.",
    run = function(words) visibility(words, "focusWidget", "is focused", "was already focused") end },

  { name = "float",
    usage = "ui float <widget>",
    help = "Pull a widget into its own floating group, centred (cascaded past other floats).",
    run = function(words)
      local w = mdwui.resolveWidget(rest(words, 2))
      if not w then return end
      local fn = capability("floatWidget")
      if not fn then return end
      local ok, code, detail = fn(w.name)
      mdwui.say(ok and string.format("%s %s.", widgetTitle(w),
        code == "already" and "already floats on its own" or "floats now")
        or explain(code, detail, widgetTitle(w)))
    end },

  { name = "dock",
    usage = "ui dock <widget> left|right [top|bottom]",
    help = "Put a widget in its own group docked at that side, at the top or (default) the bottom.",
    run = function(words)
      local w = mdwui.resolveWidget(words[2])
      if not w then return end
      local side = resolvePrefix({ "left", "right" }, words[3])
      if not side then
        mdwui.say("Which side? ui dock " .. (words[2] and plain(words[2]) or "<widget>")
          .. " left|right [top|bottom]")
        return
      end
      local position
      if words[4] then
        position = resolvePrefix({ "top", "bottom" }, words[4])
        if not position then
          mdwui.say("Position is top or bottom, not '" .. plain(words[4]) .. "'.")
          return
        end
      end
      local fn = capability("dockWidget")
      if not fn then return end
      local ok, code, detail = fn(w.name, side, position)
      mdwui.say(ok and string.format("%s %s on the %s.", widgetTitle(w),
        code == "already" and "was already docked" or "is docked", side)
        or explain(code, detail, widgetTitle(w)))
    end },

  { name = "group",
    usage = "ui group <widget> <other>",
    help = "Add a widget to another widget's group as a tab, and front it.",
    run = function(words)
      local w = mdwui.resolveWidget(words[2])
      if not w then return end
      local target = mdwui.resolveWidget(words[3])
      if not target then return end
      local fn = capability("groupWidget")
      if not fn then return end
      local ok, code, detail = fn(w.name, target.name)
      mdwui.say(ok and string.format("%s is grouped with %s.", widgetTitle(w), widgetTitle(target))
        or explain(code, detail, widgetTitle(target)))
    end },

  { name = "ungroup",
    usage = "ui ungroup <widget>",
    help = "Pull a widget out into its own group, directly below the old one (cascaded when floating).",
    run = function(words)
      local w = mdwui.resolveWidget(rest(words, 2))
      if not w then return end
      local fn = capability("ungroupWidget")
      if not fn then return end
      local ok, code, detail = fn(w.name)
      mdwui.say(ok and string.format("%s sits in its own group now.", widgetTitle(w))
        or explain(code, detail, widgetTitle(w)))
    end },

  { name = "sidebar",
    usage = "ui sidebar left|right [on|off]",
    help = "Show or hide a whole sidebar. Bare toggles it. Shorthand: ui left, ui right.",
    run = function(words)
      local side = resolvePrefix({ "left", "right" }, words[2])
      if not side then
        mdwui.say("Which sidebar? ui sidebar left|right [on|off]")
        return
      end
      setSidebar(side, words[3])
    end },

  { name = "left",
    usage = "ui left [on|off]",
    help = "The left sidebar. Bare toggles it.",
    run = function(words) setSidebar("left", words[2]) end },

  { name = "right",
    usage = "ui right [on|off]",
    help = "The right sidebar. Bare toggles it.",
    run = function(words) setSidebar("right", words[2]) end },

  { name = "width",
    usage = "ui width left|right <px|+n|-n>",
    help = "Set a dock's width, clamped to what the splitter drag allows.",
    run = function(words)
      local side = resolvePrefix({ "left", "right" }, words[2])
      if not side then
        mdwui.say("Which dock? ui width left|right <px|+n|-n>")
        return
      end
      local current = (side == "left") and mdw.config.leftDockWidth or mdw.config.rightDockWidth
      local px = parseSize(words[3], current)
      if not px then
        mdwui.say("Give a width in pixels, e.g. ui width " .. side .. " 300 (or +20).")
        return
      end
      local fn = capability("setDockWidth")
      if not fn then return end
      local ok, code, applied = fn(side, px)
      mdwui.say(ok and string.format("%s dock width %dpx.", mdwui.titleCase(side), applied)
        or explain(code, nil, side .. " dock"))
    end },

  { name = "height",
    usage = "ui height <widget> <px|+n|-n>",
    help = "Set the height of the widget's dock row. The bottom row of a dock auto-fills and refuses.",
    run = function(words)
      local w = mdwui.resolveWidget(words[2])
      if not w then return end
      local group = (w.stackId and mdw.widgets[w.stackId]) or w
      local current = (group.container and group.container:get_height()) or 0
      local px = parseSize(words[3], current)
      if not px then
        mdwui.say("Give a height in pixels, e.g. ui height "
          .. (words[2] and plain(words[2]) or "<widget>") .. " 200 (or +20).")
        return
      end
      local fn = capability("setWidgetHeight")
      if not fn then return end
      local ok, code, applied = fn(w.name, px)
      mdwui.say(ok and string.format("%s row height %dpx.", widgetTitle(w), applied)
        or explain(code, nil, widgetTitle(w)))
    end },

  { name = "scroll",
    usage = "ui scroll [<widget>] up|down|top|bottom [<n>]",
    help = "Scroll a widget's console (default 10 lines). Without a widget, the focused one. Mudlet 4.17+.",
    run = function(words)
      local ACTIONS = { "up", "down", "top", "bottom" }
      local index, name = 2
      local action = resolvePrefix(ACTIONS, words[2])
      if not action then
        local w = mdwui.resolveWidget(words[2])
        if not w then return end
        name, index = w.name, 3
        action = resolvePrefix(ACTIONS, words[3])
        if not action then
          mdwui.say("Scroll which way? up, down, top or bottom.")
          return
        end
      else
        name = mdwui.state.focusWidget
        if not (name and mdw.widgets[name]) then
          mdwui.say("No widget focused yet - name one: ui scroll comm up")
          return
        end
      end
      local lines = tonumber(words[index + 1]) or 10
      local fn = capability("scrollWidget")
      if not fn then return end
      local ok, code = fn(name, action, lines)
      if not ok then
        mdwui.say(explain(code, nil, widgetTitle(mdw.widgets[name])))
        return
      end
      mdwui.say(string.format("%s scrolled %s%s.", widgetTitle(mdw.widgets[name]), action,
        (action == "up" or action == "down") and (" " .. tostring(lines)) or ""))
    end },

  { name = "read",
    usage = "ui read <widget>",
    help = "Print a widget's current text to the main console, where it can be scrolled, "
      .. "searched and copied like any other output.",
    run = function(words)
      local w = mdwui.resolveWidget(rest(words, 2))
      if not w then return end
      local fn = capability("widgetText")
      if not fn then return end
      local lines, code = fn(w.name)
      if not lines then
        mdwui.say(code == "unsupported" and "Reading widget text needs Mudlet 4.17 or newer."
          or explain(code, nil, widgetTitle(w)))
        return
      end
      mdwui.say(string.format("%s (%d %s):", widgetTitle(w), #lines, #lines == 1 and "line" or "lines"))
      for _, text in ipairs(lines) do
        line(string.format("  <%s>%s", P.text, plain(text)))
      end
    end },

  { name = "font",
    usage = "ui font [main|menu|header|prompt|<widget>] [<size>|+n|-n]",
    help = "Show or set font sizes. Widget sizes are effective sizes, like the Font Size menu's.",
    run = function(words)
      local fn = capability("getFontSizes")
      if not fn then return end
      local sizes = fn()
      if not words[2] then
        mdwui.say(string.format("Fonts: main %s  menu %s  header %s  prompt %s",
          tostring(sizes.main), tostring(sizes.menu), tostring(sizes.header), tostring(sizes.prompt)))
        local parts = {}
        for name, size in pairs(sizes.widgets) do
          parts[#parts + 1] = string.format("%s %s", widgetTitle(mdw.widgets[name]), tostring(size))
        end
        table.sort(parts)
        line(string.format("  <%s>widgets: <%s>%s", P.head, P.text, table.concat(parts, "  ")))
        return
      end
      local target = resolvePrefix({ "main", "menu", "header", "prompt" }, words[2])
      local setter, current, label
      if target then
        setter = ({ main = "setMainFontSize", menu = "setMenuFontSize",
          header = "setWidgetHeaderFontSize", prompt = "setPromptFontSize" })[target]
        current, label = sizes[target], target
      else
        local w = mdwui.resolveWidget(words[2])
        if not w then return end
        setter, current, label = "setWidgetFontSize", sizes.widgets[w.name], widgetTitle(w)
        target = w.name
      end
      if not words[3] then
        mdwui.say(string.format("Font %s is %s.", label, tostring(current)))
        return
      end
      local size = parseSize(words[3], current)
      if not size then
        mdwui.say("Give a size, e.g. ui font " .. plain(words[2]) .. " 12 (or +1).")
        return
      end
      local apply = capability(setter)
      if not apply then return end
      local applied = (setter == "setWidgetFontSize") and apply(target, size) or apply(size)
      mdwui.say(string.format("Font %s is %s.", label, tostring(applied)))
    end },

  { name = "theme", aliases = { "color", "colour" },
    usage = "ui theme [<name>|next|prev]",
    help = "Switch the UI theme. Bare lists the themes with the current one marked. Also: ui color.",
    run = function(words)
      local names = capability("getThemeNames")
      if not names then return end
      names = names()
      local current = mdw.config.theme
      if not words[2] then
        local parts = {}
        for _, name in ipairs(names) do
          parts[#parts + 1] = name .. (name == current and "*" or "")
        end
        mdwui.say("Themes: " .. table.concat(parts, "  ") .. "   (* = current)")
        return
      end
      local word = words[2]:lower()
      if word == "next" or word == "prev" then
        local cycle = capability("cycleTheme")
        if not cycle then return end
        cycle(word == "next" and 1 or -1)
        mdwui.say("Theme " .. tostring(mdw.config.theme) .. ".")
        return
      end
      local name, candidates = resolvePrefix(names, word)
      if not name then
        mdwui.say(string.format("No theme named '%s'. Try: %s", plain(word),
          candidateText(#candidates > 0 and candidates or names)))
        return
      end
      local set = capability("setTheme")
      if not set then return end
      set(name)
      mdwui.say("Theme " .. name .. ".")
    end },

  { name = "comm", aliases = { "channel" },
    usage = "ui comm [<tab>|clear]",
    help = "Front the Communications widget, switch its channel tab, or clear the tab showing.",
    run = function(words)
      local widget = commWidget()
      if not widget then return end
      local focus = mdw.focusWidget
      if focus then
        focus("Comm")
        mdwui.state.focusWidget = "Comm"
      end
      if words[2] and words[2]:lower() == "clear" then
        local active = widget:getActiveTab()
        widget:clearTab(active)
        mdwui.say(string.format("Cleared the %s tab.", tostring(active)))
        return
      end
      if words[2] then
        local tab, candidates = resolvePrefix(widget.tabs, words[2])
        if not tab then
          mdwui.say(string.format("No channel tab '%s'. Tabs: %s", plain(words[2]),
            candidateText(#candidates > 0 and candidates or widget.tabs)))
          return
        end
        widget:selectTab(tab)
        mdwui.say("Communications: " .. tab .. ".")
        return
      end
      local active = widget:getActiveTab()
      local parts = {}
      for _, tab in ipairs(widget.tabs) do
        parts[#parts + 1] = tab .. (tab == active and "*" or "")
      end
      mdwui.say("Communications tabs: " .. table.concat(parts, "  ") .. "   (* = showing)")
    end },

  { name = "prompt",
    usage = "ui prompt [bar [on|off]] [<key> [on|off]]",
    help = "Prompt bar elements: vitals worth hp ae balance enemy. `ui prompt bar` hides or shows the bar itself.",
    run = function(words)
      local settings = mdwui.settings("promptBar", mdwui.config.promptBarDefaults)
      if not words[2] then
        showToggles("Prompt bar", PROMPT_KEYS, settings)
        return
      end
      if words[2]:lower() == "bar" then
        local on = parseOnOff(words[3], mdw.visibility.promptBar)
        if on == nil then
          mdwui.say("Say on or off, not '" .. plain(words[3]) .. "'.")
          return
        end
        local fn = capability("setPromptBarVisible")
        if not fn then return end
        fn(on)
        mdwui.say("Prompt bar " .. (on and "on" or "off") .. ".")
        return
      end
      local key, candidates = resolvePrefix(PROMPT_KEYS, words[2])
      if not key then
        mdwui.say(string.format("No prompt element '%s'. Keys: %s", plain(words[2]),
          candidateText(#candidates > 0 and candidates or PROMPT_KEYS)))
        return
      end
      local value = parseOnOff(words[3], settings[key])
      if value == nil then
        mdwui.say("Say on or off, not '" .. plain(words[3]) .. "'.")
        return
      end
      mdwui.setPromptBarOption(key, value)
      mdwui.say(string.format("Prompt %s %s.", key, value and "on" or "off"))
    end },

  { name = "combat",
    usage = "ui combat [<key> [on|off]]",
    help = "Combat widget sections: hp ae balance enemy info (info is the enemy name list).",
    run = function(words)
      local settings = mdwui.settings("combat", mdwui.config.combatDefaults)
      if not words[2] then
        showToggles("Combat widget", COMBAT_KEYS, settings)
        return
      end
      local key, candidates = resolvePrefix(COMBAT_KEYS, words[2])
      if not key then
        mdwui.say(string.format("No combat section '%s'. Keys: %s", plain(words[2]),
          candidateText(#candidates > 0 and candidates or COMBAT_KEYS)))
        return
      end
      local value = parseOnOff(words[3], settings[key])
      if value == nil then
        mdwui.say("Say on or off, not '" .. plain(words[3]) .. "'.")
        return
      end
      mdwui.setCombatOption(key, value)
      mdwui.say(string.format("Combat %s %s.", key, value and "on" or "off"))
    end },

  { name = "quest", aliases = { "quests" },
    usage = "ui quest [<id>|back|expand <id>|collapse <id>]",
    help = "The Quests widget: open one quest's detail view, go back, or fold its objective lines.",
    run = function(words)
      if mdw.focusWidget then
        mdw.focusWidget("Quests")
        mdwui.state.focusWidget = "Quests"
      end
      local word = words[2] and words[2]:lower() or nil
      if not word then
        local id = mdwui.state.questDetailId
        mdwui.say(id and ("Quests: detail for quest " .. tostring(id) .. " (ui quest back to leave).")
          or "Quests: the tracked list. ui quest <id> opens one.")
        return
      end
      if word == "back" then
        mdwui.hideQuestDetail()
        mdwui.say("Quests: back to the list.")
        return
      end
      if word == "expand" or word == "collapse" then
        local id = tonumber(words[3])
        if not id then
          mdwui.say("Which quest? ui quest " .. word .. " <id>")
          return
        end
        mdwui.setQuestExpanded(id, word == "expand")
        mdwui.say(string.format("Quest %d %s.", id, word == "expand" and "expanded" or "collapsed"))
        return
      end
      local id = tonumber(word)
      if not id then
        mdwui.say("ui quest takes a quest <id>, back, expand <id> or collapse <id>.")
        return
      end
      mdwui.showQuestDetail(id)
      mdwui.say("Quest " .. tostring(id) .. " detail.")
    end },

  { name = "journal", aliases = { "log" },
    usage = "ui journal [<category>|back|page <n>|open <n>|close <n>|book <n> <page>"
      .. "|zone|status|category <value>]",
    help = "The Journal widget: books documents quests rumors observations notes, its pager, "
      .. "its rows, and the quest category's zone/status/category filters.",
    run = function(words)
      if mdw.focusWidget then
        mdw.focusWidget("Journal")
        mdwui.state.focusWidget = "Journal"
      end
      local categories = journalCategories()
      if not words[2] then
        local parts = {}
        for _, category in ipairs(mdwui.tbl(mdwui.tbl(mdwui.tbl(gmcp and gmcp.Char).Journal).categories)) do
          parts[#parts + 1] = string.format("%s %s", plain(category.title or category.slug),
            tostring(tonumber(category.count) or 0))
        end
        mdwui.say("Journal: " .. (mdwui.state.pjCategory
          and (mdwui.state.pjCategory .. ", page " .. tostring(mdwui.state.pjPage or 1))
          or "the category front page"))
        line("  " .. (#parts > 0 and table.concat(parts, "   ") or table.concat(categories, " ")))
        return
      end
      -- One namespace for the actions and the category names, so an ambiguous
      -- shorthand (`ui journal b` - back, book, books) says so instead of
      -- guessing which of the three the player meant.
      local names = { "back", "page", "open", "close", "book", "zone", "status", "category" }
      for _, slug in ipairs(categories) do names[#names + 1] = slug end
      local word, candidates = resolvePrefix(names, words[2])
      if not word then
        mdwui.say(string.format("Unknown journal argument '%s'.%s", plain(words[2]),
          #candidates > 0 and (" Did you mean: " .. candidateText(candidates))
          or (" Categories: " .. table.concat(categories, " "))))
        return
      end
      if word == "back" then
        mdwui.journalBack()
        mdwui.say("Journal: back to the categories.")
        return
      end
      if word == "page" then
        local page = mdwui.state.pjPage or 1
        local arg = words[3] and words[3]:lower() or ""
        local target = (arg == "next" and page + 1) or (arg == "prev" and page - 1) or tonumber(arg)
        if not target then
          mdwui.say("Which page? ui journal page <n>|next|prev")
          return
        end
        mdwui.say("Journal page " .. tostring(mdwui.journalPage(target)) .. ".")
        return
      end
      if word == "open" or word == "close" then
        local open = (word == "open")
        local number = tonumber(words[3])
        if not number then
          mdwui.say("Which row? ui journal " .. word .. " <index>")
          return
        end
        if mdwui.state.pjCategory == "quests" then
          -- The quests category is keyed by quest id, not by list index: its
          -- rows come from Char.Quests, which Char.Journal.List never serves.
          mdwui.setJournalRowExpanded(questRowKey(number), open)
          mdwui.say(string.format("Quest %d %s.", number, open and "expanded" or "collapsed"))
          return
        end
        local entry = mdwui.journalEntryByIndex(number)
        if not entry then
          mdwui.say("No entry [" .. tostring(number) .. "] on this page.")
          return
        end
        mdwui.setJournalEntryExpanded(entry.id, open)
        mdwui.say(string.format("[%d] %s %s.", number, plain(entry.title or "entry"),
          open and "expanded" or "collapsed"))
        return
      end
      if word == "book" then
        local number, page = tonumber(words[3]), tonumber(words[4])
        if not (number and page) then
          mdwui.say("ui journal book <index> <page>")
          return
        end
        local entry = mdwui.journalEntryByIndex(number)
        if not entry then
          mdwui.say("No entry [" .. tostring(number) .. "] on this page.")
          return
        end
        mdwui.setJournalBookPage(entry.id, page)
        mdwui.say(string.format("[%d] page %d.", number, page))
        return
      end
      if word == "zone" or word == "status" or word == "category" then
        local value = rest(words, 3)
        if value == "" then
          mdwui.say(string.format("Journal %s is '%s'.", word,
            plain(tostring(mdwui.tbl(mdwui.state.journalFilters)[word]))))
          return
        end
        local ok, reason = mdwui.setJournalFilter(word, value)
        mdwui.say(ok and string.format("Journal %s: %s.", word, plain(value)) or reason)
        return
      end
      mdwui.journalOpen(word)
      mdwui.say("Journal: " .. word .. ".")
    end },

  { name = "numpad",
    usage = "ui numpad [on|off]",
    help = "Numpad walking. While it is on the keypad walks instead of typing digits "
      .. "(PC keypads: NumLock on).",
    run = function(words)
      local on = parseOnOff(words[2], mdwui.numpadWalking())
      if on == nil then
        mdwui.say("Say on or off, not '" .. plain(words[2]) .. "'.")
        return
      end
      mdwui.setNumpadWalking(on)
      mdwui.say(on and "Numpad walking on - the keypad walks instead of typing digits."
        or "Numpad walking off - the keypad types digits again.")
    end },

  { name = "refresh",
    usage = "ui refresh [<what>]",
    help = "Ask the server for its data again. Bare pulls the whole payload; name a part to pull "
      .. "just that: character vitals inventory equipment keyring forage affects quests journal "
      .. "comm room group map.",
    run = function(words)
      if not words[2] then
        mdwui.requestFullPayload()
        mdwui.say("Requested a full GMCP refresh.")
        return
      end
      local what, candidates = resolvePrefix(REFRESH_ORDER, words[2])
      if not what then
        mdwui.say(string.format("Nothing called '%s' to refresh. Try: %s", plain(words[2]),
          (#candidates > 0) and candidateText(candidates) or table.concat(REFRESH_ORDER, " ")))
        return
      end
      if what == "all" then
        mdwui.requestFullPayload()
        mdwui.say("Requested a full GMCP refresh.")
        return
      end
      local nodes = REFRESH_NODES[what]
      for _, node in ipairs(nodes) do mdwui.request(node) end
      mdwui.say(string.format("Requested %s: %s", what, table.concat(nodes, " ")))
    end },

  { name = "debug",
    usage = "ui debug [gmcp [<path>]]",
    help = "What the UI thinks it is doing: versions, live counts, the layout file and this "
      .. "package's settings. `ui debug gmcp` dumps the GMCP data, or one dotted path of it "
      .. "(ui debug gmcp Char.Vitals). Bring it when reporting a bug.",
    run = function(words)
      if words[2] then
        if not resolvePrefix({ "gmcp" }, words[2]) then
          mdwui.say(string.format("ui debug takes gmcp [<path>], not '%s'.", plain(words[2])))
          return
        end
        local node, label = gmcp or {}, "gmcp"
        if words[3] then
          for part in tostring(words[3]):gmatch("[^%.]+") do
            -- Indexed longhand, not `and ... or`: a leaf whose value is false
            -- is data, and that idiom would report it as missing.
            if type(node) == "table" then node = node[part] else node = nil end
            if node == nil then
              mdwui.say(string.format("No GMCP data at '%s'. Try ui debug gmcp on its own.",
                plain(words[3])))
              return
            end
          end
          label = plain(words[3])
        end
        local out = { lines = {}, cut = 0 }
        if type(node) == "table" and next(node) ~= nil then
          dumpChildren(out, node, 0) -- the tag line already names the root
        else
          dumpValue(out, label, node, 0)
        end
        mdwui.say(string.format("GMCP %s:", label))
        for _, text in ipairs(out.lines) do
          line(string.format("  <%s>%s", P.text, plain(text)))
        end
        if out.cut > 0 then
          line(string.format("  <%s>... %d more lines, not shown.", P.dim, out.cut))
        end
        return
      end
      mdwui.say("Diagnostics:")
      line(string.format("  <%s>WillowdaleUI %s   MDW %s   Mapper %s", P.name,
        tostring(mdwui.version), tostring((mdw and mdw.version) or "-"),
        -- Guarded, runtime-only lookup: neither package requires the other.
        tostring((mapper and mapper.version) or "-")))
      line(string.format("  <%s>built <%s>%s   <%s>focused <%s>%s   <%s>layout file <%s>%s",
        P.head, P.text, tostring(mdw.isSetUp and true or false),
        P.head, P.text, mdwui.state.focusWidget
          and widgetTitle(mdw.widgets[mdwui.state.focusWidget]) or "-",
        P.head, P.text, plain(tostring(mdw.layoutFile or "-"))))
      line(string.format("  <%s>widgets <%s>%d   <%s>handlers <%s>%d   <%s>timers <%s>%d",
        P.head, P.text, countPairs(mdwui.state.widgets),
        P.head, P.text, countPairs(mdwui.state.handlers),
        P.head, P.text, #mdwui.state.timers))
      local settings = mdwui.tbl(mdwui.tbl(mdw.gameSettings)[mdwui.packageName])
      local sections = {}
      for section in pairs(settings) do sections[#sections + 1] = section end
      table.sort(sections)
      for _, section in ipairs(sections) do
        line(string.format("  <%s>%s <%s>%s", P.head, section, P.text,
          plain(settingsText(settings[section]))))
      end
    end },

  { name = "reset",
    usage = "ui reset [all] confirm",
    help = "Throw the saved layout away and rebuild from the defaults. Your prompt/combat toggles "
      .. "and numpad choice survive unless you say `all`. Two steps: it arms, then you confirm.",
    run = function(words)
      local all = false
      local confirm = false
      for i = 2, #words do
        local word = words[i]:lower()
        if word == "all" then all = true elseif word == "confirm" then confirm = true end
      end
      local armed = mdwui.state.resetArmedAt
        and (os.time() - mdwui.state.resetArmedAt) <= 10
        and (mdwui.state.resetArmedAll == all)
      if not (confirm and armed) then
        mdwui.state.resetArmedAt = os.time()
        mdwui.state.resetArmedAll = all
        mdwui.say(all and "Reset ALL: default layout, and this package's settings wiped "
          .. "(prompt/combat toggles, numpad)."
          or "Reset: default layout, docks, fonts and theme. Settings stay.")
        line("  Type ui reset " .. (all and "all confirm" or "confirm") .. " within 10 seconds.")
        return
      end
      mdwui.state.resetArmedAt = nil
      local fn = capability("resetLayout")
      if not fn then return end
      fn({ keepGameSettings = not all })
      mdwui.say(all and "Layout and settings reset." or "Layout reset.")
    end },

  { name = "update",
    usage = "ui update [install]",
    help = "Check GitHub for a newer Willowdale UI and offer to install it. The UI checks once "
      .. "on its own when it builds; nothing is downloaded until you ask. `ui update install` "
      .. "takes the offer from the keyboard, for anyone who cannot click its link.",
    run = function(words)
      local arg = words[2]
      if not arg then
        mdwui.checkForUpdate(true)
        return
      end
      -- Prefix-matched like every other word in this surface, so `ui update i`
      -- works the way `ui sh que` does.
      if ("install"):find(arg:lower(), 1, true) == 1 then
        mdwui.installUpdate()
      else
        mdwui.say("Say install, or nothing at all - not '" .. plain(arg) .. "'.")
      end
    end },

  { name = "rebuild",
    usage = "ui rebuild",
    help = "Tear the UI down and build it again, keeping your layout. The recovery hatch.",
    run = function()
      local fn = capability("rebuild")
      if not fn then return end
      mdwui.say("Rebuilding the UI...")
      fn()
    end },
}

--- Set one sidebar from an optional on/off word (nil toggles).
setSidebar = function(side, word)
  local key = (side == "left") and "leftSidebar" or "rightSidebar"
  local on = parseOnOff(word, mdw.visibility[key])
  if on == nil then
    mdwui.say("Say on or off, not '" .. plain(word) .. "'.")
    return
  end
  local fn = capability("setSidebarVisible")
  if not fn then return end
  fn(side, on)
  mdwui.say(string.format("%s sidebar %s.", mdwui.titleCase(side), on and "on" or "off"))
end

--- Exact command name or alias first, then unique prefix over both.
-- @return command, nil on a hit; nil, candidate names otherwise
resolveCommand = function(word)
  local q = tostring(word or ""):lower()
  if q == "" then return nil, {} end
  for _, cmd in ipairs(COMMANDS) do
    if cmd.name == q then return cmd end
    for _, alias in ipairs(cmd.aliases or {}) do
      if alias == q then return cmd end
    end
  end
  local matches, names = {}, {}
  for _, cmd in ipairs(COMMANDS) do
    -- Report the spelling that MATCHED, not the canonical name: `ui l`
    -- hitting the alias `log` has to say "log", or the hint reads like a
    -- non sequitur.
    local spelling = (cmd.name:sub(1, #q) == q) and cmd.name or nil
    for _, alias in ipairs(cmd.aliases or {}) do
      if not spelling and alias:sub(1, #q) == q then spelling = alias end
    end
    if spelling then
      matches[#matches + 1] = cmd
      names[#names + 1] = spelling
    end
  end
  if #matches == 1 then return matches[1] end
  return nil, names
end

---------------------------------------------------------------------------
-- THE DISPATCHER
---------------------------------------------------------------------------

--- Run one `ui` line. The single entry point for the alias and the smoke
-- suite - so both exercise identical behaviour.
function mdwui.command(line_)
  local text = tostring(line_ or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if not (mdw and mdw.isSetUp) then
    mdwui.say("The UI is not built yet.")
    return
  end
  if text == "" then
    mdwui.renderOverview()
    return
  end
  local words = tokenize(text)
  local cmd, candidates = resolveCommand(words[1])
  if not cmd then
    mdwui.say(string.format("Unknown command '%s'.%s", plain(words[1]),
      (candidates and #candidates > 0) and (" Did you mean: " .. candidateText(candidates))
      or " Type ui for the list."))
    return
  end
  -- pcall so a renderer error (or a payload shape nobody expected) prints one
  -- line instead of breaking the alias for the rest of the session. It never
  -- send()s: unknown input stays with the client.
  local ok, err = pcall(cmd.run, words, text)
  if not ok then
    mdwui.say("error: " .. tostring(err))
  end
end

---------------------------------------------------------------------------
-- THE OVERVIEW (bare `ui`)
---------------------------------------------------------------------------

local OVERVIEW_COMMAND_COLUMN = 29
local OVERVIEW_VALUE_COLUMN = 10
local OVERVIEW_OPTIONS_WIDTH = 41 -- 80 columns less the two before it

--- The Comm widget's active tab WITHOUT commWidget()'s complaint: a value
-- getter runs inside the table, where "the Communications widget is not
-- built" would be read as one of its rows.
local function commTab()
  local w = mdw.widgets and mdw.widgets["Comm"]
  if w and w.getActiveTab then return tostring(w:getActiveTab()) end
  return "-"
end

--- Guarded lookup rather than capability(): that helper says what is missing,
-- and a complaint printed into the middle of a table would be read as a row.
-- An older MDW just shows "-" in the font rows.
local function fontSize(key)
  local sizes = mdw.getFontSizes and mdw.getFontSizes()
  return (sizes and sizes[key] ~= nil) and tostring(sizes[key]) or "-"
end

-- The prompt-bar and Combat toggles are generated from the same key lists
-- `ui prompt` and `ui combat` walk, so a key added there appears here by
-- itself. Each explanation says what that toggle actually paints (see
-- MDWUI_Combat.lua's prompt bar, prompt-gauge row and Combat rows): "on|off"
-- alone does not tell a player which of five gauges they are turning off.
local PROMPT_HELP = { vitals = "the vitals prompt line", worth = "the worth line (prompt2)",
  hp = "HP gauge", ae = "AE gauge", balance = "balance gauge", enemy = "target's HP gauge" }
local COMBAT_HELP = { hp = "your HP gauge", ae = "your AE gauge", balance = "your balance gauge",
  enemy = "enemy HP gauges", info = "the enemy-names section" }

local ONOFF_ROWS = {
  { cmd = "sidebar left", link = "sidebar left", opts = "on|off   (also: ui left)",
    value = function() return mdwui.tbl(mdw.visibility).leftSidebar and true or false end },
  { cmd = "sidebar right", link = "sidebar right", opts = "on|off   (also: ui right)",
    value = function() return mdwui.tbl(mdw.visibility).rightSidebar and true or false end },
  { cmd = "prompt bar", link = "prompt bar", opts = "on|off   the prompt bar itself",
    value = function() return mdwui.tbl(mdw.visibility).promptBar and true or false end },
}
for _, key in ipairs(PROMPT_KEYS) do
  ONOFF_ROWS[#ONOFF_ROWS + 1] = { cmd = "prompt " .. key, link = "prompt " .. key,
    opts = "on|off   " .. PROMPT_HELP[key],
    value = function()
      return mdwui.settings("promptBar", mdwui.config.promptBarDefaults)[key] and true or false
    end }
end
for _, key in ipairs(COMBAT_KEYS) do
  ONOFF_ROWS[#ONOFF_ROWS + 1] = { cmd = "combat " .. key, link = "combat " .. key,
    opts = "on|off   " .. COMBAT_HELP[key],
    value = function()
      return mdwui.settings("combat", mdwui.config.combatDefaults)[key] and true or false
    end }
end
ONOFF_ROWS[#ONOFF_ROWS + 1] = { cmd = "numpad", link = "numpad", opts = "on|off   numpad walking",
  value = function() return mdwui.numpadWalking() and true or false end }

local LOOK_ROWS = {
  { cmd = "theme", link = "theme",
    value = function() return tostring(mdwui.tbl(mdw.config).theme) end,
    -- the installed themes are live MDW data, so the options are a getter too
    opts = function()
      return (mdw.getThemeNames and table.concat(mdw.getThemeNames(), "|") or "<name>") .. "|next|prev"
    end },
}
for _, key in ipairs({ "main", "menu", "header", "prompt" }) do
  LOOK_ROWS[#LOOK_ROWS + 1] = { cmd = "font " .. key, link = "font " .. key, opts = "<size>|+n|-n",
    value = function() return fontSize(key) end }
end
LOOK_ROWS[#LOOK_ROWS + 1] = { cmd = "font <widget>", link = "font",
  opts = "<size>|+n|-n   its effective size, like the Font Size menu" }

-- The screen, shaped like the game's own `config` command: Command / Value /
-- Options in three columns, grouped under headings, the on/off rows first.
-- That is the layout a Willowdale player already reads without being taught
-- it, and "what is on right now" belongs on the screen they open first - it
-- was otherwise scattered over `ui list`, `ui prompt`, `ui combat` and
-- `ui font`.
--
-- A row is { cmd, link, opts, value }. `cmd` is not a label: it is exactly
-- what follows `ui` to run that row (the word `ui` is said once, in the
-- footer), so a new row must keep that property or the screen starts lying.
-- `link` is the bare form the line's click runs - a listing for the listing
-- verbs, a flip for the toggles, a "which one?" prompt for the rest, never
-- something destructive without a confirm. `value` is a getter read at render
-- time, and `opts` may be one too; a boolean value prints in the game's
-- config colours, green on / red off.
-- ONE table, because a second list of commands would drift from this one
-- inside a release: `ui help <verb>` reads the command table's own usage and
-- help, and this drives the screen that points at them.
local OVERVIEW = {
  { title = "On/off:", colour = P.verbPanels, rows = ONOFF_ROWS },
  { title = "Layout:", colour = P.verbLayout, rows = {
    { cmd = "width left", link = "width left", opts = "<px>|+n|-n",
      value = function() return tostring(mdwui.tbl(mdw.config).leftDockWidth) end },
    { cmd = "width right", link = "width right", opts = "<px>|+n|-n",
      value = function() return tostring(mdwui.tbl(mdw.config).rightDockWidth) end },
    { cmd = "height <widget>", link = "height", opts = "<px>|+n|-n   the row it sits in" },
    { cmd = "float <widget>", link = "float", opts = "its own floating group, centred" },
    { cmd = "dock <widget>", link = "dock",
      opts = "left|right [top|bottom]   its own group on that side" },
    { cmd = "group <widget> <other>", link = "group", opts = "add it to the other's group as a tab" },
    { cmd = "ungroup <widget>", link = "ungroup", opts = "pull it out into its own group" },
    { cmd = "list", link = "list",
      opts = "docks, groups, tabs, heights, fonts, theme (also: ui containers)" },
  } },
  { title = "Look:", colour = P.verbLook, rows = LOOK_ROWS },
  { title = "Widgets:", colour = P.verbWidgets, rows = {
    { cmd = "show <widget>", link = "show", opts = "reveal it and front its tab" },
    { cmd = "hide <widget>", link = "hide",
      opts = "close its tab (siblings stay) or hide a lone group" },
    { cmd = "toggle <widget>", link = "toggle", opts = "hide if shown, show if hidden" },
    { cmd = "focus <widget>", link = "focus",
      opts = "front its tab; the widget ui scroll uses by default",
      value = function()
        return mdwui.state.focusWidget and widgetTitle(mdw.widgets[mdwui.state.focusWidget]) or "-"
      end },
    { cmd = "read <widget>", link = "read", opts = "print its text to the main window" },
    { cmd = "scroll [<widget>]", link = "scroll",
      opts = "up|down|top|bottom [<n>]   default 10 lines" },
    { cmd = "comm", link = "comm", value = commTab,
      opts = "<tab>|clear   channel tabs of the Communications widget" },
  } },
  { title = "Quests and Journal widget:", colour = P.verbPanels, rows = {
    { cmd = "quest", link = "quest",
      opts = "<id>|back|expand <id>|collapse <id>   detail view and chevrons" },
    { cmd = "journal", link = "journal",
      opts = "<category>|back|page <n>|open <n>|close <n>|book <n> <page>" },
    { cmd = "journal zone|status|category", link = "journal", opts = "<value>   quest-list filters" },
  } },
  { title = "Maintenance:", colour = P.verbMaint, rows = {
    { cmd = "refresh", link = "refresh", opts = "[<what>]   re-request all GMCP data, or one part" },
    { cmd = "debug", link = "debug", opts = "[gmcp [<path>]]   diagnostics, or a GMCP dump" },
    { cmd = "reset", link = "reset", opts = "[all] confirm   the default layout (all: settings too)" },
    { cmd = "rebuild", link = "rebuild", opts = "rebuild the UI in place" },
    -- The value is the version the row would replace, which is the one thing
    -- a player wants to see before asking GitHub anything.
    { cmd = "update", link = "update", opts = "[install]   check GitHub for a newer UI, or take the offer",
      value = function() return tostring(mdwui.version) end },
    { cmd = "help", link = "help", opts = "<command>   what one command does" },
  } },
}

--- The widget vocabulary line: every widget by title, with its shortest
-- synonym in parentheses. Built from the live registry, so a widget added
-- later appears here without anyone remembering to update a list.
local function widgetVocabulary()
  local shortest = {}
  for synonym, name in pairs(mdwui.widgetSynonyms) do
    if not shortest[name] or #synonym < #shortest[name] then shortest[name] = synonym end
  end
  local names = {}
  for name, w in pairs(mdw.widgets or {}) do
    if not w.isStack then names[#names + 1] = name end
  end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    local label = widgetTitle(mdw.widgets[name]):lower()
    local synonym = shortest[name]
    parts[#parts + 1] = label .. ((synonym and synonym ~= label) and ("(" .. synonym .. ")") or "")
  end
  return parts
end

--- The bare `ui` screen: the welcome banner, who is running, where the
-- widgets sit, and then every command as a config-style row - what it is
-- called, what it is set to now, and what it accepts.
function mdwui.renderOverview()
  line("")
  line(string.format("<%s>          ****    Welcome to the Willowdale MUD UI    ****", P.banner))
  line("")
  -- Name and version share one colour run per package: the pair has to read
  -- as one word to anything scanning the plain text.
  line(string.format("<%s>WillowdaleUI %s   MDW %s   Mapper %s",
    P.name, tostring(mdwui.version), tostring((mdw and mdw.version) or "-"),
    -- Guarded, runtime-only lookup: neither package requires the other.
    tostring((mapper and mapper.version) or "-")))

  -- Only where things SIT: every sidebar, width, toggle and font that used to
  -- head this block is a row of the table below now.
  local info = mdw.describeLayout and mdw.describeLayout() or nil
  if info then
    for _, side in ipairs({ "left", "right" }) do
      local parts = {}
      for _, row in ipairs(info.docks[side].rows) do
        for _, occ in ipairs(row.occupants) do parts[#parts + 1] = occupantText(occ) end
      end
      line(string.format("<%s>%s %s", P.text, cell(mdwui.titleCase(side) .. ":", 7),
        #parts > 0 and table.concat(parts, " ") or "empty"))
    end
    if #info.floating > 0 then
      local parts = {}
      for _, occ in ipairs(info.floating) do parts[#parts + 1] = occupantText(occ) end
      line(string.format("<%s>%s %s", P.text, cell("Float:", 7), table.concat(parts, " ")))
    end
    local hidden = {}
    for _, entry in ipairs(info.hidden) do hidden[#hidden + 1] = entry.title end
    line(string.format("<%s>(* = front tab)   hidden: %s", P.text,
      #hidden > 0 and table.concat(hidden, ", ") or "none"))
  end

  line("")
  line(string.format("<%s>%s%s%s", P.cfgHead, cell("Command:", OVERVIEW_COMMAND_COLUMN),
    cell("Value:", OVERVIEW_VALUE_COLUMN), "Options:"))
  for _, section in ipairs(OVERVIEW) do
    line("")
    line(string.format("<%s>%s", P.name, section.title))
    for _, row in ipairs(section.rows) do
      -- The command cell is the link and carries the section's colour, so a
      -- click can only ever run the command the eye is on. A command wider
      -- than its column just pushes its own row right (cell() always leaves
      -- one space), as the old Willowdale UI did.
      mdwui.sayLink(string.format("<%s>%s", section.colour, cell(row.cmd, OVERVIEW_COMMAND_COLUMN)),
        row.link, "ui " .. row.link)
      -- A boolean is a toggle and wears the game's config colours; anything
      -- else is a number or a name, which is body text. A row with no getter
      -- still pads its cell, or the Options column would walk left.
      local value, colour = "", P.text
      if row.value then
        local current = row.value()
        if type(current) == "boolean" then
          value, colour = current and "on" or "off", current and P.good or P.bad
        else
          value = tostring(current)
        end
      end
      emit(string.format("<%s>%s", colour, cell(value, OVERVIEW_VALUE_COLUMN)))
      local opts = row.opts
      if type(opts) == "function" then opts = opts() end
      local wrapped = wrapText(opts or "", OVERVIEW_OPTIONS_WIDTH)
      line(string.format("<%s>%s", P.opts, wrapped[1] or ""))
      for i = 2, #wrapped do
        line(string.format("<%s>%s%s", P.opts,
          string.rep(" ", OVERVIEW_COMMAND_COLUMN + OVERVIEW_VALUE_COLUMN), wrapped[i]))
      end
    end
  end
  line("")
  line(string.format("<%s>Widgets: %s", P.text, table.concat(widgetVocabulary(), " ")))
  line(string.format("<%s>Change one with ui <command> <value>, e.g. ui prompt vitals on"
    .. " - a click on a line runs it", P.dim))
  line(string.format("<%s>Names and widgets match on a unique prefix: ui sh que", P.dim))
end

--- One line, once per session, pointing at the keyboard surface. buildUI runs
-- on every MDW setup (installs, profile loads, MDW updates), so the hint has
-- to remember it already spoke.
function mdwui.announceCommands()
  if mdwui.state.hintShown then return end
  mdwui.state.hintShown = true
  mdwui.say("Type ui for keyboard controls.")
end
