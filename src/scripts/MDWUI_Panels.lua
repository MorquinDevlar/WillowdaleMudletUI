--[[
  MDWUI_Panels.lua
  Renderers for the list-style panels: Character, Affects, Group, Equipment,
  Inventory, Keyring, and Forage.

  Every renderer is a pure function of the gmcp table: clear the console,
  repaint from the latest payloads. That makes them safe to call from GMCP
  events, from widget resize (via mdwui.bindRenderer), and at build time with
  whatever data is already cached. They write straight to widget.content -
  see mdwui.bindRenderer for why they bypass MDW's echo buffer.

  Field names come from the GMCP guide (sections 5.3-5.8).

  Dependencies: MDWUI_Config.lua, MDWUI_Core.lua.
]]

---------------------------------------------------------------------------
-- CHARACTER (Char.Info + Char.Attributes + Char.Worth + Char.Vitals,
-- plus the Game.Clock/Game.Calendar time line the web client keeps in its
-- toolbar - here it heads the panel instead).
---------------------------------------------------------------------------

function mdwui.renderCharacter()
  local widget = mdwui.w("Character")
  if not widget then return end
  local C = mdwui.config.colors
  local char = (gmcp and gmcp.Char) or {}
  local info = char.Info or {}
  local attr = char.Attributes or {}
  local worth = char.Worth or {}
  local vitals = char.Vitals or {}
  local game = (gmcp and gmcp.Game) or {}
  local co = widget.content
  co:clear()

  -- Time line: clock ticks ~1/sec, calendar changes on day/night phase.
  local clock = (game.Clock or {}).time
  local cal = game.Calendar or {}
  if clock or cal.day_name then
    co:decho(string.format("<%s>%s  <%s>%s%s\n", C.dim, clock or "",
      C.dim, cal.day_name or "", cal.phase and (" (" .. cal.phase .. ")") or ""))
  end

  co:decho(string.format("<%s>%s<r>  <%s>Lv %s %s %s%s\n",
    C.label, info.name or "?", C.text,
    tostring(info.level or "?"), info.race or "", info.class or "",
    (info.role and info.role ~= "" and info.role ~= "user") and (" [" .. info.role .. "]") or ""))

  co:decho(string.format("<%s>HP <%s>%s/%s  <%s>AE <%s>%s/%s\n",
    C.label, mdwui.healthColor(vitals.health, vitals.health_max),
    mdwui.fmtNum(vitals.health), mdwui.fmtNum(vitals.health_max),
    C.label, C.aether, mdwui.fmtNum(vitals.aether), mdwui.fmtNum(vitals.aether_max)))

  co:decho(string.format("<%s>Body <%s>%s  <%s>Mind <%s>%s  <%s>Spirit <%s>%s\n",
    C.label, C.text, tostring(attr.body or 0),
    C.label, C.text, tostring(attr.mind or 0),
    C.label, C.text, tostring(attr.spirit or 0)))

  -- Derived combat stats, two per line to fit a sidebar width.
  local derived = {
    { "Armor", attr.armor_rating }, { "Evasion", attr.evasion_chance },
    { "Warding", attr.warding_rating }, { "Resilience", attr.spirit_resilience },
    { "Martial", attr.martial_power }, { "Aether Pwr", attr.aether_power },
    { "Potency", attr.state_potency },
  }
  for i = 1, #derived, 2 do
    local a, b = derived[i], derived[i + 1]
    local line = string.format("<%s>%s <%s>%s", C.label, a[1], C.text, tostring(a[2] or 0))
    if b then
      line = line .. string.format("  <%s>%s <%s>%s", C.label, b[1], C.text, tostring(b[2] or 0))
    end
    co:decho(line .. "\n")
  end

  co:decho(string.format("<%s>Gold <%s>%s <%s>(bank %s)\n",
    C.label, C.warn, mdwui.fmtNum(worth.gold_carried),
    C.dim, mdwui.fmtNum(worth.gold_bank)))
  co:decho(string.format("<%s>XP <%s>%s<%s>/%s  <%s>TNL %s\n",
    C.label, C.text, mdwui.fmtNum(worth.xp_current), C.dim, mdwui.fmtNum(worth.xp_total),
    C.label, mdwui.fmtNum(worth.xp_tnl)))
  if (tonumber(worth.stat_points) or 0) > 0 or (tonumber(worth.training_points) or 0) > 0 then
    co:decho(string.format("<%s>Stat pts <%s>%s  <%s>Training pts <%s>%s\n",
      C.label, C.good, tostring(worth.stat_points or 0),
      C.label, C.good, tostring(worth.training_points or 0)))
  end
end

---------------------------------------------------------------------------
-- AFFECTS (Char.Affects)
-- Durations arrive once as seconds; there is no per-second push, so the
-- countdown runs locally (guide 8.5): remaining = duration_current minus the
-- time since the payload arrived. A 1s timer repaints while anything ticks.
---------------------------------------------------------------------------

function mdwui.renderAffects()
  local widget = mdwui.w("Affects")
  if not widget then return end
  local C = mdwui.config.colors
  local affects = (gmcp and gmcp.Char and gmcp.Char.Affects) or {}
  local co = widget.content
  co:clear()

  local names = {}
  for name in pairs(affects) do names[#names + 1] = name end
  table.sort(names)

  if #names == 0 then
    co:decho(string.format("<%s>No active affects\n", C.dim))
    return
  end

  local elapsed = os.time() - (mdwui.state.affectsReceivedAt or os.time())
  for _, name in ipairs(names) do
    local a = affects[name]
    local remaining = tonumber(a.duration_current) or 0
    if remaining >= 0 then
      remaining = math.max(0, remaining - elapsed)
    end
    local color = (a.type == "state") and C.warn or C.good
    co:decho(string.format("<%s>%s <%s>%s\n",
      color, a.name or name, C.dim, mdwui.fmtDuration(remaining)))
  end
end

---------------------------------------------------------------------------
-- GROUP (Group.Info + Group.Vitals)
---------------------------------------------------------------------------

function mdwui.renderGroup()
  local widget = mdwui.w("Group")
  if not widget then return end
  local C = mdwui.config.colors
  local group = (gmcp and gmcp.Group) or {}
  local info = group.Info or {}
  local vitals = group.Vitals or {}
  local co = widget.content
  co:clear()

  local members = {}
  for _, m in ipairs(info.members or {}) do members[#members + 1] = { m = m } end
  for _, m in ipairs(info.invited or {}) do members[#members + 1] = { m = m, invited = true } end

  -- Vitals-only updates can land before the roster (web client does the same
  -- fallback): show the group from vitals rather than claiming there is none.
  if #members == 0 and #vitals > 0 then
    for _, v in ipairs(vitals) do members[#members + 1] = { m = v } end
  end
  if #members == 0 then
    co:decho(string.format("<%s>Not in a group\n", C.dim))
    return
  end

  -- Index vitals by name for the per-member HP line.
  local vitalsByName = {}
  for _, v in ipairs(vitals) do
    if v.name then vitalsByName[v.name] = v end
  end

  for _, entry in ipairs(members) do
    local m = entry.m
    local name = m.name or m.username or tostring(m)
    -- The server names the leader outright (leaderid) - never inferred.
    local isLeader = (info.leaderid and (m.id == info.leaderid or m.userid == info.leaderid))
    local tag = entry.invited and (" <" .. C.dim .. ">(invited)")
      or (isLeader and (" <" .. C.warn .. ">(leader)")) or ""
    local v = vitalsByName[name] or m
    local hp = ""
    if v.health ~= nil and v.health_max ~= nil then
      hp = string.format("  <%s>%s/%s", mdwui.healthColor(v.health, v.health_max),
        mdwui.fmtNum(v.health), mdwui.fmtNum(v.health_max))
    end
    co:decho(string.format("<%s>%s%s%s\n", C.text, name, tag, hp))
  end
end

---------------------------------------------------------------------------
-- EQUIPMENT (Char.Inventory.Worn) - guide 5.4
---------------------------------------------------------------------------

function mdwui.renderEquipment()
  local widget = mdwui.w("Equipment")
  if not widget then return end
  local C = mdwui.config.colors
  local worn = (gmcp and gmcp.Char and gmcp.Char.Inventory and gmcp.Char.Inventory.Worn) or {}
  local co = widget.content
  co:clear()

  for _, slot in ipairs(mdwui.config.wornSlots) do
    local item = worn[slot]
    co:decho(string.format("<%s>%-13s<r> ", C.label, slot))
    if item and item.name and item.name ~= "" then
      -- Name looks; a separate [x] removes - the web client's two actions.
      mdwui.link(co, string.format("<%s>%s", C.text, item.name),
        "look " .. (item.id or ""), "look at " .. item.name)
      for _, badge in ipairs(item.details or {}) do
        co:decho(string.format(" <%s>[%s]", C.badge, badge))
      end
      co:decho("  ")
      mdwui.link(co, string.format("<%s>[x]", C.link), "remove " .. slot, "remove " .. slot)
    else
      co:decho(string.format("<%s>-", C.dim))
    end
    co:decho("\n")
  end
end

---------------------------------------------------------------------------
-- INVENTORY (Char.Inventory.Backpack.Items + .Summary) - guide 5.5
---------------------------------------------------------------------------

--- Shared item-list body for Inventory and Forage: name (look link), badges,
-- the item's OWN primary verb (guide 8.9 - items know how they are used),
-- and drop. `withDrop` is off for Forage, which the web client keeps
-- display-plus-use only.
local function renderItemList(co, items, withDrop)
  local C = mdwui.config.colors
  for _, item in ipairs(items or {}) do
    local qty = (tonumber(item.quantity) or 1) > 1
      and string.format(" <%s>x%d", C.dim, item.quantity) or ""
    mdwui.link(co, string.format("<%s>%s", C.text, item.name or "?"),
      "look " .. (item.id or ""), "look at " .. (item.name or "item"))
    co:decho(qty)
    for _, badge in ipairs(item.details or {}) do
      co:decho(string.format(" <%s>[%s]", C.badge, badge))
    end
    if item.command and item.command ~= "" then
      co:decho("  ")
      mdwui.link(co, string.format("<%s>[%s]", C.link, item.command),
        item.command .. " " .. (item.id or ""), item.command .. " " .. (item.name or ""))
    end
    if withDrop then
      co:decho(" ")
      mdwui.link(co, string.format("<%s>[drop]", C.link),
        "drop " .. (item.id or ""), "drop " .. (item.name or "item"))
    end
    co:decho("\n")
  end
end

function mdwui.renderInventory()
  local widget = mdwui.w("Inventory")
  if not widget then return end
  local C = mdwui.config.colors
  local inv = (gmcp and gmcp.Char and gmcp.Char.Inventory) or {}
  local backpack = inv.Backpack or {}
  local co = widget.content
  co:clear()

  local items = backpack.Items or {}
  if #items == 0 then
    co:decho(string.format("<%s>Backpack is empty\n", C.dim))
  else
    renderItemList(co, items, true)
  end
  local summary = backpack.Summary
  if summary and summary.max then
    co:decho(string.format("<%s>Carrying %s/%s\n", C.dim,
      tostring(summary.count or #items), tostring(summary.max)))
  end
end

---------------------------------------------------------------------------
-- KEYRING (Char.Inventory.Keyring) - guide 5.6
---------------------------------------------------------------------------

function mdwui.renderKeyring()
  local widget = mdwui.w("Keyring")
  if not widget then return end
  local C = mdwui.config.colors
  local keyring = (gmcp and gmcp.Char and gmcp.Char.Inventory and gmcp.Char.Inventory.Keyring) or {}
  local co = widget.content
  co:clear()

  if #keyring == 0 then
    co:decho(string.format("<%s>No keys or lockpicks\n", C.dim))
    return
  end
  for _, key in ipairs(keyring) do
    local what = key.type or "Key"
    -- sequence is only meaningful for lockpicks (guide 5.6)
    local seq = (what == "Lockpick" and key.sequence and key.sequence ~= "")
      and string.format(" <%s>[%s]", C.badge, key.sequence) or ""
    co:decho(string.format("<%s>%s<r> <%s>%s%s\n",
      C.label, what, C.text, key.where or key.location or "?", seq))
  end
end

---------------------------------------------------------------------------
-- FORAGE (Char.Inventory.Ingredients) - guide 5.7
---------------------------------------------------------------------------

function mdwui.renderForage()
  local widget = mdwui.w("Forage")
  if not widget then return end
  local C = mdwui.config.colors
  local bag = (gmcp and gmcp.Char and gmcp.Char.Inventory and gmcp.Char.Inventory.Ingredients) or {}
  local co = widget.content
  co:clear()

  local items = bag.items or {}
  if #items == 0 then
    co:decho(string.format("<%s>No ingredients gathered\n", C.dim))
  else
    renderItemList(co, items, false)
  end
  if bag.max then
    co:decho(string.format("<%s>%s/%s gathered\n", C.dim,
      tostring(bag.count or #items), tostring(bag.max)))
  end
end
