--[[
  MDWUI_Quests.lua
  The Quests widget (the web client's two zone-keyed sections, per-quest
  action menu) and the Journal widget (the full, filterable list over the
  same Char.Quests payload, with lazily fetched per-row detail).

  Quest detail is lazy and per-quest (guide 8.13): it only exists after an
  explicit Char.Quest.Detail request, and any Char.Quests push invalidates it
  (guide 8.12) - so both widgets re-request rather than trust a stale cache.

  Dependencies: MDWUI_Config.lua, MDWUI_Core.lua.
]]

---------------------------------------------------------------------------
-- SHARED QUEST STATE AND HELPERS
---------------------------------------------------------------------------

--- Seed the tables these two widgets keep in mdwui.state. State is PRESERVED
-- across script re-runs (see MDWUI_Config), so a live session can hold a
-- state table that predates any of these fields - every entry point seeds
-- before touching them.
local function seedState()
  local s = mdwui.state
  s.questExpanded = s.questExpanded or {}
  s.questDetailCache = s.questDetailCache or {}
  s.questDetailPending = s.questDetailPending or {}
  s.journalExpanded = s.journalExpanded or {}
  s.journalFilters = s.journalFilters or { zone = "all", status = "all", category = "all" }
end

--- Ask for one quest's detail unless a request for it is already in flight.
-- The guard is what makes the render path safe to re-enter: every repaint
-- (resize reflows included) walks the expanded rows, and without it a live
-- sidebar drag would fire a request per mouse move.
local function requestDetail(id)
  local key = tostring(id)
  if mdwui.state.questDetailPending[key] then return end
  mdwui.state.questDetailPending[key] = true
  mdwui.request("Char.Quest.Detail", string.format('{"id":%d}', tonumber(id) or 0))
end

--- The zone the "Here" section and the journal's "Current zone" filter key
-- on - Room.Info.Basic.area (guide 5.14), the same room.Zone value the quest
-- payload's own `zone` field carries.
local function currentZone()
  return mdwui.tbl(mdwui.tbl(mdwui.tbl(gmcp and gmcp.Room).Info).Basic).area
end

--- The completed list, honoring the server's omit-on-refresh contract
-- (guide 5.9): progress-only Char.Quests pushes DROP the field entirely - it
-- cannot have changed - so the last full copy is cached and reused. Cached
-- here rather than in the event handler on purpose: whichever render sees a
-- full payload first seeds it (build-time renderAll included), so no handler
-- ordering can leave the journal showing an empty history.
local function completedList(quests)
  if type(quests.completed) == "table" then
    mdwui.state.questCompletedCache = quests.completed
    return quests.completed
  end
  return mdwui.state.questCompletedCache or {}
end

--- One objective line's text. The (x/y) counter only shows above 1: a single
-- talk/visit/collect is binary and reads cleaner without a "(0/1)".
local function objectiveText(objective)
  local text = objective.text or ""
  if (tonumber(objective.count) or 0) > 1 then
    text = string.format("%s (%s/%s)", text,
      tostring(objective.current or 0), tostring(objective.count))
  end
  return text
end

--- A chevron toggling `stateTable[key]`, or two spaces of reserved width
-- when there is nothing to expand (web parity: names still line up).
local function chevron(co, C, stateTable, key, expandable, hint, rerender)
  if not expandable then
    co:decho("  ")
    return
  end
  local open = stateTable[key] and true or false
  co:dechoLink(string.format("<%s>%s", C.charLabel, open and "▼" or "▶"),
    function()
      stateTable[key] = (not open) or nil
      rerender()
    end, (open and "Collapse " or "Expand ") .. hint, true)
  co:decho(" ")
end

---------------------------------------------------------------------------
-- QUEST DETAIL BODY (shared by both widgets)
-- Transcribed from the web client's renderQuestDetailInto: the same order
-- and wording as the telnet `quest <id>` output, since both are built from
-- the server's shared questdetail package.
---------------------------------------------------------------------------

local function renderDetailBody(co, C, W, d, pad)
  -- `deep` is the second indent level: the web client's .qst-obj and
  -- .qj-detail-reward carry their own padding-left inside the block.
  local function line(color, text, deep, attr)
    mdwui.wrapEcho(co, W, color, text, pad .. (deep and "  " or ""), attr)
  end
  local function kv(key, value, valueColor)
    local avail = W - #pad
    local color = valueColor or C.qjKv
    local chunks = mdwui.wrapText(value, avail, avail - #key - 1)
    co:decho(string.format("%s<%s>%s <%s>%s\n", pad, C.qjKey, key, color, chunks[1]))
    for i = 2, #chunks do
      co:decho(string.format("%s<%s>%s\n", pad, color, chunks[i]))
    end
  end
  local function named(item)
    return string.format("%s%s", item.name or "?",
      (tonumber(item.count) or 0) > 1 and (" x" .. tostring(item.count)) or "")
  end

  if d.giver_name and d.giver_name ~= "" then kv("Given by:", d.giver_name, C.questActive) end
  if d.giver_zone and d.giver_zone ~= "" then kv("Area:", d.giver_zone) end
  if d.category and d.category ~= "" then kv("Category:", d.category) end
  if d.description and d.description ~= "" then
    line(C.qjKv, string.format('"%s"', d.description), false, "i") -- .qj-detail-quote
  end

  -- Hint: the giver's counsel recalled from steps already passed.
  local hints = mdwui.tbl(d.hints)
  if #hints > 0 then
    line(C.charGold, "Hint")
    for _, beat in ipairs(hints) do
      if beat.emote and beat.emote ~= "" then
        line(C.qjBeat, string.format("%s %s", d.giver_name or "", beat.emote))
      end
      if beat.say and beat.say ~= "" then
        line(C.qjBeat, string.format('%s says, "%s"', d.giver_name or "", beat.say))
      end
    end
  end

  if d.active then
    line(C.charGold, string.format("Current step (%s of %s)",
      tostring(d.step_num or "?"), tostring(d.step_count or "?")))
    if d.step_description and d.step_description ~= "" then line(C.qjDesc, d.step_description) end
    -- .qj-detail-meta is italic; .qst-obj-done is line-through, which decho
    -- renders with <s> (these lines are not links, where Qt's strikeout is
    -- suppressed in favour of the link decoration).
    if d.step_hint and d.step_hint ~= "" then line(C.faint, "Tip: " .. d.step_hint, false, "i") end
    for _, objective in ipairs(mdwui.tbl(d.objectives)) do
      line(objective.done and C.questObjDone or C.questObj, objectiveText(objective), true,
        objective.done and "s" or nil)
    end
    local items = mdwui.tbl(d.quest_items)
    if #items > 0 then
      line(C.charGold, "Set aside for this task")
      for _, item in ipairs(items) do line(C.qjKv, named(item), true) end
    end
  end

  -- The closing narrative, once the quest is done. `completion` is a STRING
  -- in the detail payload - the list payload's same-named field is the
  -- percentage int, so never share a formatter between the two.
  if type(d.completion) == "string" and d.completion ~= "" then
    line(C.charGold, "Completion")
    line(C.qjDesc, d.completion)
  end

  if d.has_reward then
    line(C.charGold, "Reward")
    local headline = {}
    if (tonumber(d.reward_xp) or 0) > 0 then
      headline[#headline + 1] = tostring(d.reward_xp) .. " experience"
    end
    if (tonumber(d.reward_gold) or 0) > 0 then
      headline[#headline + 1] = tostring(d.reward_gold) .. " gold"
    end
    if #headline > 0 then line(C.qjKv, table.concat(headline, ", "), true) end
    -- reward_items are {name, count} OBJECTS, not strings.
    for _, item in ipairs(mdwui.tbl(d.reward_items)) do
      line(C.qjKv, "Item: " .. named(item), true)
    end
    if d.reward_title and d.reward_title ~= "" then line(C.qjKv, "Title: " .. d.reward_title, true) end
    if d.reward_skill and d.reward_skill ~= "" then line(C.qjKv, "Skill: " .. d.reward_skill, true) end
    if d.reward_buff and d.reward_buff ~= "" then line(C.qjKv, "Blessing: " .. d.reward_buff, true) end
  end
end

---------------------------------------------------------------------------
-- QUESTS (two zone-keyed sections <-> one-quest detail view)
---------------------------------------------------------------------------

local function renderQuestDetail(co, C, W)
  local id = mdwui.state.questDetailId
  -- A pure view switch, NOT mdwui.link: that helper sends a real game
  -- command, and "back" must only leave the in-widget detail view.
  co:dechoLink(string.format("<%s>[back to quests]", C.link),
    function() mdwui.hideQuestDetail() end, "back to the quest list", true)
  co:decho("\n\n")
  local d = mdwui.state.questDetailCache[tostring(id)]
  if not d then
    requestDetail(id)
    co:decho(string.format("<%s><i>Fetching quest details...</i>\n", C.dim))
    return
  end
  mdwui.wrapEcho(co, W, C.charHeader, d.name or "?", "")
  renderDetailBody(co, C, W, d, "")
end

--- One quest row plus its expandable detail lines - the web client's
-- buildQuestEntry: chevron toggle, [id] status-colored, name opens the quest
-- menu, completion right-aligned at the panel edge. `here` renders the Here
-- section's variant, whose detail is the turn-in pointer instead of the
-- objective list.
local function renderQuestEntry(co, C, W, quest, here)
  -- Detail lines before the header (web parity: the chevron needs to know
  -- whether there is anything to expand).
  local details = {}
  if here and quest.receiver and quest.receiver ~= "" then
    details[1] = { "See " .. quest.receiver, C.questObj }
  else
    for _, objective in ipairs(mdwui.tbl(quest.objectives)) do
      -- .qst-obj-done is line-through; decho's <s> is the exact equivalent.
      details[#details + 1] = { objectiveText(objective),
        objective.done and C.questObjDone or C.questObj,
        objective.done and "s" or nil }
    end
    -- A pure turn-in step carries no objectives; show its step description
    -- so the player still sees where to report back.
    if #details == 0 and quest.step_description and quest.step_description ~= "" then
      details[1] = { quest.step_description, C.questObj }
    end
  end

  local id = quest.id
  local key = tostring(id)
  local expanded = #details > 0 and mdwui.state.questExpanded[key] or false
  chevron(co, C, mdwui.state.questExpanded, key, #details > 0,
    quest.name or "?", mdwui.renderQuests)

  local idText = string.format("[%s]", tostring(id))
  co:decho(string.format("<%s>%s ", quest.ready and C.questReady or C.questActive, idText))

  -- The name opens the quest menu, matching the web client's quest row
  -- (questContextOptions): Information / Track-or-Untrack. Information
  -- there sends the `quest <id>` command; here it opens the in-widget
  -- detail view instead - the same data via the lazy Char.Quest.Detail
  -- pull, without spilling the telnet quest text into the main console.
  local pct = tostring(tonumber(quest.completion) or 0) .. "%"
  local name, nameW = mdwui.clipText(quest.name or "?",
    math.max(4, W - 2 - (#idText + 1) - (#pct + 1)))
  local verb = quest.tracked and "untrack" or "track"
  mdwui.menuLink(co, string.format("<%s>%s", C.charHeader, name),
    string.format("[%s] %s", tostring(id), quest.name or "?"), {
      { label = "Information", fn = function() mdwui.showQuestDetail(id) end },
      { separator = true },
      { label = verb == "track" and "Track" or "Untrack",
        command = string.format("quest %s %s", verb, tostring(id)) },
    },
    -- The row tooltip mirrors the web header's title attribute.
    (quest.step_description and quest.step_description ~= "") and quest.step_description or nil)
  co:decho(string.format("%s<%s>%s\n",
    string.rep(" ", math.max(1, W - 2 - (#idText + 1) - nameW - #pct)), C.charHeader, pct))

  if expanded then
    for _, line in ipairs(details) do
      mdwui.wrapEcho(co, W, line[2], line[1], "  ", line[3])
    end
  end
end

--- A rumor under Here: masked on purpose - display-only, no id to act on
-- (guide 8.25), so neither line is a link.
local function renderRumorEntry(co, C, W, rumor)
  mdwui.wrapEcho(co, W, C.questRumor, rumor.text or "", "")
  mdwui.wrapEcho(co, W, C.faint, "Heard from " .. (rumor.source_text or "?"), "  ", "i")
end

function mdwui.renderQuests()
  local widget = mdwui.w("Quests")
  if not widget then return end
  seedState()
  local C = mdwui.config.colors
  local co = widget.content
  local W = mdwui.wrapWidth(widget, 24)
  co:clear()

  if mdwui.state.questDetailId then
    renderQuestDetail(co, C, W)
    return
  end

  local quests = mdwui.tbl(gmcp and gmcp.Char and gmcp.Char.Quests)
  local active = mdwui.tbl(quests.active)

  -- The web client's two sections (updateQuestsPanel). Untracked quests that
  -- are not ready in this zone belong to the Journal, not here.
  co:decho(string.format("<%s>Tracked:\n", C.charHeader))
  mdwui.divider(co, W)
  local trackedCount = 0
  for _, quest in ipairs(active) do
    if quest.tracked then
      renderQuestEntry(co, C, W, quest, false)
      trackedCount = trackedCount + 1
    end
  end
  if trackedCount == 0 then
    co:decho(string.format("<%s><i>No tracked quests</i>\n", C.faint))
  end

  -- Here: quests whose current step resolves at a giver/receiver in this
  -- zone, plus rumors pointing at a giver here - mirrors `quests here`.
  -- Tracked quests already sit in the section above, so they are skipped.
  local zone = currentZone()
  co:decho(string.format("\n<%s>Here:\n", C.charHeader))
  mdwui.divider(co, W)
  local hereCount = 0
  if zone then
    for _, quest in ipairs(active) do
      if quest.ready and quest.zone == zone and not quest.tracked then
        renderQuestEntry(co, C, W, quest, true)
        hereCount = hereCount + 1
      end
    end
    for _, rumor in ipairs(mdwui.tbl(quests.rumors)) do
      if rumor.zone == zone then
        renderRumorEntry(co, C, W, rumor)
        hereCount = hereCount + 1
      end
    end
  end
  if hereCount == 0 then
    co:decho(string.format("<%s><i>Nothing nearby</i>\n", C.faint))
  end
end

function mdwui.showQuestDetail(id)
  seedState()
  mdwui.state.questDetailId = id
  -- No request here: the render's cache-miss path issues it (and paints the
  -- fetching state), so a detail already pulled by a Journal row shows at once.
  mdwui.renderQuests()
end

function mdwui.hideQuestDetail()
  mdwui.state.questDetailId = nil
  mdwui.renderQuests()
end

---------------------------------------------------------------------------
-- QUEST JOURNAL (active + rumors + completed over Char.Quests, each row
-- expanding to the full lazily-fetched quest detail - renderQuestJournal in
-- gmcp-ui.js). Not a widget of its own: it is one category inside the
-- Journal widget (MDWUI_Journal.lua).
---------------------------------------------------------------------------

-- Status filter values and labels, matching the web client's select options.
local STATUS_OPTIONS = {
  { "all", "All statuses" },
  { "active", "In progress" },
  { "ready", "Ready to turn in" },
  { "rumor", "Rumors" },
  { "done", "Completed" },
}

--- questJournalRowMatches: every filter must pass for a row to show. The
-- web's free-text search has no counterpart here - a Mudlet miniconsole has
-- no text input - so the three dropdown filters are the whole bar.
local function rowMatches(status, zone, category)
  local f = mdwui.state.journalFilters
  if f.status ~= "all" and f.status ~= status then return false end
  if f.zone == "current" then
    local here = currentZone()
    if not zone or zone == "" or zone ~= here then return false end
  elseif f.zone ~= "all" and zone ~= f.zone then
    return false
  end
  if f.category ~= "all" and category ~= f.category then return false end
  return true
end

--- Sorted distinct values, for the zone and category dropdowns.
local function sortedKeys(set)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end

--- One filter as a clickable current-value label opening its option menu -
-- the Mudlet stand-in for the web client's <select>.
local function filterLink(co, C, key, options)
  local current = mdwui.state.journalFilters[key]
  local label = options[1][2]
  for _, option in ipairs(options) do
    if option[1] == current then label = option[2] end
  end
  local actions = {}
  for _, option in ipairs(options) do
    local value = option[1]
    actions[#actions + 1] = { label = option[2], fn = function()
      mdwui.state.journalFilters[key] = value
      mdwui.renderJournal()
    end }
  end
  mdwui.menuLink(co, string.format("<%s>[%s]", C.link, label),
    "Filter by " .. key, actions)
end

local function renderFilterBar(co, C, W, active, completed, rumors)
  local zones, categories = {}, {}
  for _, quest in ipairs(active) do
    if quest.zone and quest.zone ~= "" then zones[quest.zone] = true end
    if quest.category and quest.category ~= "" then categories[quest.category] = true end
  end
  for _, rumor in ipairs(rumors) do
    if rumor.zone and rumor.zone ~= "" then zones[rumor.zone] = true end
  end
  for _, quest in ipairs(completed) do
    if quest.category and quest.category ~= "" then categories[quest.category] = true end
  end

  local zoneOptions = { { "all", "All zones" }, { "current", "Current zone" } }
  for _, zone in ipairs(sortedKeys(zones)) do zoneOptions[#zoneOptions + 1] = { zone, zone } end
  local categoryOptions = { { "all", "All categories" } }
  for _, category in ipairs(sortedKeys(categories)) do
    categoryOptions[#categoryOptions + 1] = { category, category }
  end

  filterLink(co, C, "zone", zoneOptions)
  co:decho(" ")
  filterLink(co, C, "status", STATUS_OPTIONS)
  co:decho(" ")
  filterLink(co, C, "category", categoryOptions)
  co:decho("\n")
  mdwui.divider(co, W)
end

--- A journal row header: chevron, [id], name, an optional right-aligned
-- tail, and (for active quests) the web's track/untrack button.
local function journalHeader(co, C, W, opts)
  chevron(co, C, mdwui.state.journalExpanded, opts.key, true, opts.hint, mdwui.renderJournal)
  co:decho(string.format("<%s>%s ", opts.color, opts.idText))

  local tail = opts.tail or ""
  local verb = opts.verb
  -- Fixed cells around the elastic name: the chevron, "[id] ", the optional
  -- track button with its trailing space, and the right-aligned tail. The
  -- name keeps at least one space of gap from whatever follows it.
  local fixed = 2 + #opts.idText + 1 + (verb and #verb + 1 or 0) + #tail
  local name, nameW = mdwui.clipText(opts.name, math.max(4, W - fixed - 1))
  co:decho(string.format("<%s>%s", opts.color, name))
  co:decho(string.rep(" ", math.max(1, W - fixed - nameW)))
  if verb then
    -- The web's .qst-track-btn: a real game command, like every other
    -- widget affordance.
    mdwui.link(co, string.format("<%s>%s", C.charGold, verb),
      string.format("quest %s %s", verb, tostring(opts.questId)),
      verb .. " this quest")
    co:decho(" ")
  end
  if #tail > 0 then
    co:decho(string.format("<%s>%s", C.charHeader, tail))
  end
  co:decho("\n")
end

--- The expanded block under a quest row: the full detail, fetched lazily on
-- first expand and re-fetched after a Char.Quests push invalidated it.
local function renderRowDetail(co, C, W, id)
  local d = mdwui.state.questDetailCache[tostring(id)]
  if not d then
    requestDetail(id)
    co:decho(string.format("  <%s><i>Loading...</i>\n", C.charLabel))
    return
  end
  renderDetailBody(co, C, W, d, "  ")
end

--- The quest journal - the filterable list over the whole Char.Quests
-- payload. It renders INTO a console the caller owns rather than owning a
-- widget: the merged Journal widget shows this as its Quests category, the
-- way telnet's `journal quests` delegates to the quest views and the way the
-- web client now does it. The caller supplies the clear and the crumb row.
function mdwui.renderQuestJournalInto(co, C, W)
  seedState()
  local quests = mdwui.tbl(gmcp and gmcp.Char and gmcp.Char.Quests)
  local active = mdwui.tbl(quests.active)
  local completed = mdwui.tbl(completedList(quests))
  local rumors = mdwui.tbl(quests.rumors)
  local expanded = mdwui.state.journalExpanded

  renderFilterBar(co, C, W, active, completed, rumors)

  -- Web render order: active, then rumors, then completed.
  local shown = 0
  for _, quest in ipairs(active) do
    local status = quest.ready and "ready" or "active"
    if rowMatches(status, quest.zone, quest.category) then
      local key = "a:" .. tostring(quest.id)
      journalHeader(co, C, W, {
        key = key, hint = quest.name or "?",
        idText = string.format("[%s]", tostring(quest.id)),
        color = quest.ready and C.questReady or C.questActive,
        name = quest.name or "?",
        tail = tostring(tonumber(quest.completion) or 0) .. "%",
        verb = quest.tracked and "untrack" or "track",
        questId = quest.id,
      })
      if expanded[key] then renderRowDetail(co, C, W, quest.id) end
      shown = shown + 1
    end
  end

  for _, rumor in ipairs(rumors) do
    if rowMatches("rumor", rumor.zone, "") then
      -- Masked rows (guide 8.25): no id, so the web shows "[  ?]" and the
      -- detail is the attribution line rather than a GMCP pull.
      local key = "r:" .. tostring(rumor.text or "")
      journalHeader(co, C, W, {
        key = key, hint = "this rumor", idText = "[?]",
        color = C.questRumor, name = rumor.text or "",
      })
      if expanded[key] then
        mdwui.wrapEcho(co, W, C.faint, string.format("Heard from %s%s", rumor.source_text or "?",
          (rumor.zone and rumor.zone ~= "") and (" | " .. rumor.zone) or ""), "  ", "i")
      end
      shown = shown + 1
    end
  end

  for _, quest in ipairs(completed) do
    if rowMatches("done", "", quest.category) then
      local key = "d:" .. tostring(quest.id)
      local count = tonumber(quest.count) or 1
      journalHeader(co, C, W, {
        key = key, hint = quest.name or "?",
        idText = string.format("[%s]", tostring(quest.id)),
        color = C.questDone, name = quest.name or "?",
        tail = count > 1 and ("completed x" .. tostring(count)) or "completed",
      })
      if expanded[key] then renderRowDetail(co, C, W, quest.id) end
      shown = shown + 1
    end
  end

  if shown == 0 then
    co:decho(string.format("<%s><i>Nothing matches these filters.</i>\n", C.faint))
  end
end

---------------------------------------------------------------------------
-- GMCP HANDLERS
---------------------------------------------------------------------------

function mdwui.onQuests()
  seedState()
  -- A Char.Quests push invalidates every fetched detail (guide 8.12):
  -- progress may have changed, so drop the cache and let the renders
  -- re-request what is still on screen. The web client collapses its rows
  -- instead; keeping them open costs one request per expanded row, which
  -- the in-flight guard keeps to exactly one per quest.
  mdwui.state.questDetailCache = {}
  mdwui.state.questDetailPending = {}
  mdwui.renderQuests()
  mdwui.renderJournal()
end

function mdwui.onQuestDetail()
  seedState()
  local d = mdwui.tbl(gmcp and gmcp.Char and gmcp.Char.Quest and gmcp.Char.Quest.Detail)
  if d.id then
    mdwui.state.questDetailCache[tostring(d.id)] = d
    mdwui.state.questDetailPending[tostring(d.id)] = nil
  end
  if mdwui.state.questDetailId then mdwui.renderQuests() end
  mdwui.renderJournal()
end

--- A character switch mid-session invalidates every quest cache: the
-- completed history in particular would otherwise be spliced into the new
-- character's journal by the first progress-only push, which omits the field
-- (the web client clears questCompletedCache on the same signal).
function mdwui.onCharName(name)
  seedState()
  if name == nil or name == "" or name == mdwui.state.charName then return end
  local switched = mdwui.state.charName ~= nil
  mdwui.state.charName = name
  if not switched then return end
  mdwui.state.questCompletedCache = nil
  mdwui.state.questDetailCache = {}
  mdwui.state.questDetailPending = {}
  mdwui.state.questExpanded = {}
  mdwui.state.journalExpanded = {}
  mdwui.state.questDetailId = nil
  -- The journal's entry ids, indexes and counts belong to the previous
  -- character too. Guarded: MDWUI_Journal loads after this script, so the
  -- function exists by the time any event can reach here, but not at load.
  if mdwui.resetJournal then mdwui.resetJournal() end
  -- Repaint immediately: the widgets are still showing the previous
  -- character's quests, and the next Char.Quests push may be a progress-only
  -- one that never carries a completed list to correct them with.
  mdwui.renderQuests()
  if mdwui.renderJournal then mdwui.renderJournal() end
end

---------------------------------------------------------------------------
-- KEYBOARD ENTRY POINTS (`ui quest` / `ui journal`, MDWUI_Commands.lua)
-- The chevrons and filter menus above are mouse affordances; these are the
-- same state changes by name, so both paths land on one implementation.
---------------------------------------------------------------------------

--- Open or fold one Quests-widget row. Keyed by tostring(id), the key the
-- chevron itself uses (renderQuestEntry).
function mdwui.setQuestExpanded(id, open)
  seedState()
  mdwui.state.questExpanded[tostring(id)] = open and true or nil
  mdwui.renderQuests()
  return open and true or false
end

--- Open or fold one quest-journal row. Keys are the ones
-- renderQuestJournalInto builds: "a:<id>", "d:<id>", "r:<text>".
function mdwui.setJournalRowExpanded(key, open)
  seedState()
  mdwui.state.journalExpanded[tostring(key)] = open and true or nil
  mdwui.renderJournal()
  return open and true or false
end

--- Set one quest-journal filter. Status is a closed set (the dropdown's
-- options); zone and category are free text out of the payloads, plus the
-- "all"/"current" specials the filter bar offers.
-- @return ok, reason - the reason is ready to print
function mdwui.setJournalFilter(key, value)
  seedState()
  if key ~= "zone" and key ~= "status" and key ~= "category" then
    return false, "Filter by zone, status or category."
  end
  if key == "status" then
    local slugs = {}
    for _, option in ipairs(STATUS_OPTIONS) do slugs[#slugs + 1] = option[1] end
    local found = false
    for _, slug in ipairs(slugs) do
      if slug == value then found = true end
    end
    if not found then
      return false, string.format("Status is one of: %s", table.concat(slugs, " "))
    end
  end
  mdwui.state.journalFilters[key] = value
  mdwui.renderJournal()
  return true
end
