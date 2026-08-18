--[[
  MDWUI_Quests.lua
  The Quests widget (active quests, track toggles, lazy per-quest detail) and
  the Journal widget (completed quests and rumors) - both views over the same
  Char.Quests payload, split the way a sidebar reads best.

  Quest detail is lazy and per-quest (guide 8.13): it only exists after an
  explicit Char.Quest.Detail request, and any Char.Quests push invalidates it
  (guide 8.12) - so the detail view re-requests instead of trusting a cache.

  Dependencies: MDWUI_Config.lua, MDWUI_Core.lua.
]]

---------------------------------------------------------------------------
-- QUESTS (active list <-> one-quest detail view)
---------------------------------------------------------------------------

local function renderQuestDetail(co, C)
  local d = (gmcp and gmcp.Char and gmcp.Char.Quest and gmcp.Char.Quest.Detail) or {}
  mdwui.link(co, string.format("<%s>[back to quests]", C.link), "quests", "back to the quest list")
  co:decho("\n\n")
  if d.id ~= mdwui.state.questDetailId then
    co:decho(string.format("<%s>Fetching quest details...\n", C.dim))
    return
  end

  co:decho(string.format("<%s>%s <%s>(%s)\n", C.label, d.name or "?", C.dim, d.category or ""))
  if d.description and d.description ~= "" then
    co:decho(string.format("<%s>%s\n", C.text, d.description))
  end
  if d.giver_name and d.giver_name ~= "" then
    co:decho(string.format("<%s>From <%s>%s<r> <%s>(%s)\n",
      C.dim, C.text, d.giver_name, C.dim, d.giver_zone or "?"))
  end
  if d.step_description and d.step_description ~= "" then
    co:decho(string.format("<%s>Step %s/%s: <%s>%s\n",
      C.label, tostring(d.step_num or "?"), tostring(d.step_count or "?"),
      C.text, d.step_description))
  end
  for _, objective in ipairs(d.objectives or {}) do
    local mark = objective.done and string.format("<%s>[x]", C.good)
      or string.format("<%s>[ ]", C.dim)
    co:decho(string.format("  %s <%s>%s <%s>%s/%s\n", mark, C.text,
      objective.text or "", C.dim,
      tostring(objective.current or 0), tostring(objective.count or 0)))
  end
  if d.has_reward then
    local rewards = {}
    if (tonumber(d.reward_xp) or 0) > 0 then rewards[#rewards + 1] = d.reward_xp .. " xp" end
    if (tonumber(d.reward_gold) or 0) > 0 then rewards[#rewards + 1] = d.reward_gold .. " gold" end
    for _, item in ipairs(d.reward_items or {}) do rewards[#rewards + 1] = item end
    if d.reward_title and d.reward_title ~= "" then rewards[#rewards + 1] = "title: " .. d.reward_title end
    if #rewards > 0 then
      co:decho(string.format("<%s>Rewards: <%s>%s\n", C.label, C.warn, table.concat(rewards, ", ")))
    end
  end
end

function mdwui.renderQuests()
  local widget = mdwui.w("Quests")
  if not widget then return end
  local C = mdwui.config.colors
  local co = widget.content
  co:clear()

  if mdwui.state.questDetailId then
    renderQuestDetail(co, C)
    return
  end

  local quests = (gmcp and gmcp.Char and gmcp.Char.Quests) or {}
  local active = quests.active or {}
  if #active == 0 then
    co:decho(string.format("<%s>No active quests\n", C.dim))
    return
  end

  for _, quest in ipairs(active) do
    local mark = quest.tracked and string.format("<%s>* ", C.warn) or "  "
    co:decho(mark)
    -- Name opens the in-widget detail view (a lazy Char.Quest.Detail pull).
    local id = quest.id
    co:dechoLink(string.format("<%s>%s", quest.ready and C.good or C.text, quest.name or "?"),
      function() mdwui.showQuestDetail(id) end, "show quest details", true)
    if quest.completion then
      co:decho(string.format(" <%s>%s%%", C.dim, tostring(quest.completion)))
    end
    co:decho("  ")
    -- Track toggle sends the real game command, per the outbound rule.
    local verb = quest.tracked and "untrack" or "track"
    mdwui.link(co, string.format("<%s>[%s]", C.link, verb),
      string.format("quest %s %s", verb, tostring(id)), verb .. " this quest")
    co:decho("\n")
    if quest.step_description and quest.step_description ~= "" then
      co:decho(string.format("    <%s>%s\n", C.dim, quest.step_description))
    end
  end
end

function mdwui.showQuestDetail(id)
  mdwui.state.questDetailId = id
  mdwui.request("Char.Quest.Detail", string.format('{"id":%d}', tonumber(id) or 0))
  mdwui.renderQuests() -- paints the fetching state until the payload lands
end

function mdwui.hideQuestDetail()
  mdwui.state.questDetailId = nil
  mdwui.renderQuests()
end

function mdwui.onQuests()
  -- A Char.Quests push invalidates any fetched detail (guide 8.12): progress
  -- may have changed, so re-request it rather than render a stale view.
  if mdwui.state.questDetailId then
    mdwui.request("Char.Quest.Detail",
      string.format('{"id":%d}', tonumber(mdwui.state.questDetailId) or 0))
  end
  mdwui.renderQuests()
  mdwui.renderJournal()
end

function mdwui.onQuestDetail()
  if mdwui.state.questDetailId then
    mdwui.renderQuests()
  end
end

---------------------------------------------------------------------------
-- JOURNAL (completed quests + rumors)
---------------------------------------------------------------------------

function mdwui.renderJournal()
  local widget = mdwui.w("Journal")
  if not widget then return end
  local C = mdwui.config.colors
  local quests = (gmcp and gmcp.Char and gmcp.Char.Quests) or {}
  local co = widget.content
  co:clear()

  local completed = quests.completed or {}
  co:decho(string.format("<%s>Completed (%d)\n", C.label, #completed))
  for _, quest in ipairs(completed) do
    local times = (tonumber(quest.count) or 1) > 1
      and string.format(" <%s>x%d", C.dim, quest.count) or ""
    co:decho(string.format("  <%s>%s%s\n", C.text, quest.name or "?", times))
  end

  -- Rumors are intentionally masked - display-only, no id to act on (guide 8.25).
  local rumors = quests.rumors or {}
  if #rumors > 0 then
    co:decho(string.format("\n<%s>Rumors\n", C.label))
    for _, rumor in ipairs(rumors) do
      co:decho(string.format("  <%s>%s <%s>- %s (%s)\n",
        C.text, rumor.text or "", C.dim, rumor.source_text or "?", rumor.zone or "?"))
    end
  end
end
