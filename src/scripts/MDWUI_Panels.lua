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
-- CHARACTER (Char.Info + Char.Attributes + Char.Worth)
-- Mirrors the web client's #character-panel (webclient-pure.html): the
-- name / "Lv. N" / class header, the core attributes beside the spendable
-- points, a rule, then the derived-stat columns. Nothing else: HP/AE, gold
-- and XP belong to the prompt layer there and here alike; the clock lives
-- in the web toolbar and has no panel slot.
---------------------------------------------------------------------------

-- The web client right-aligns values via pad-to-3 (updateCharacterPanel);
-- width 4 here so Evasion's trailing % shares the column's right edge.
local function charVal(v, suffix)
  local s = (v == nil) and "-" or (tostring(v) .. (suffix or ""))
  return string.format("%4s", s)
end

function mdwui.renderCharacter()
  local widget = mdwui.w("Character")
  if not widget then return end
  local C = mdwui.config.colors
  local char = (gmcp and gmcp.Char) or {}
  local info = char.Info or {}
  local attr = char.Attributes or {}
  local worth = char.Worth or {}
  local co = widget.content
  co:clear()

  -- Floor of 31 = one full row.
  local W = mdwui.wrapWidth(widget, 31)

  -- One grid row. The web grid's middle column stretches, pushing the
  -- right label/value pair flush against the panel's right edge.
  local function row(lLabel, lVal, lColor, rLabel, rVal, rColor)
    if not rLabel then
      co:decho(string.format("<%s>%-8s<%s>%s\n", C.charLabel, lLabel, lColor, lVal))
      return
    end
    local gap = math.max(2, W - 8 - #lVal - 13 - #rVal)
    co:decho(string.format("<%s>%-8s<%s>%s%s<%s>%-13s<%s>%s\n",
      C.charLabel, lLabel, lColor, lVal, string.rep(" ", gap),
      C.charLabel, rLabel, rColor, rVal))
  end

  -- Header: name left, level centered, class right (.char-header's
  -- space-between), class title-cased like the web client.
  local name = info.name or "-"
  local lvl = "Lv. " .. ((info.level == nil) and "-" or tostring(info.level))
  local cls = mdwui.titleCase(info.class or "")
  local lead = math.max(2, math.floor((W - #lvl) / 2) - #name)
  local trail = math.max(2, W - #name - lead - #lvl - #cls)
  co:decho(string.format("<%s>%s%s%s%s<%s>%s\n", C.charHeader, name,
    string.rep(" ", lead), lvl, string.rep(" ", trail), C.charGold, cls))
  mdwui.divider(co, W)

  row("Body", charVal(attr.body), C.charAttr,
    "Training Pts", charVal(worth.training_points), C.charGold)
  row("Mind", charVal(attr.mind), C.charAttr,
    "Stat Pts", charVal(worth.stat_points), C.charGold)
  row("Spirit", charVal(attr.spirit), C.charAttr)
  mdwui.divider(co, W)

  row("Armor", charVal(attr.armor_rating), C.charCyan,
    "Martial Pwr", charVal(attr.martial_power), C.charBlue)
  row("Evasion", charVal(attr.evasion_chance, "%"), C.charCyan,
    "Aether Pwr", charVal(attr.aether_power), C.charBlue)
  row("Warding", charVal(attr.warding_rating), C.charCyan,
    "Resilience", charVal(attr.spirit_resilience), C.charBlue)
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
  local affects = mdwui.tbl(gmcp and gmcp.Char and gmcp.Char.Affects)
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
-- The web client's roster card (updateGroupPanel + the .grp-* markup),
-- two lines per member: name and class against the rank, then the health
-- gauge against the autoattack mode. Rows rather than console text so the
-- gauge is a real Geyser gauge like the Combat widget's, with MDW's
-- rightText carrying the web's space-between right column.
---------------------------------------------------------------------------

function mdwui.renderGroup()
  local widget = mdwui.w("Group")
  if not widget then return end
  -- Under an MDW predating the rows API the widget simply stays empty.
  if not (mdw and mdw.setWidgetRows) then return end
  local C = mdwui.config.colors
  local g = mdwui.config.gauges
  local group = (gmcp and gmcp.Group) or {}
  local info = group.Info or {}
  local vitals = mdwui.tbl(group.Vitals)
  -- The server names the leader outright, so a member missing from Info
  -- never turns someone else into the leader by elimination.
  local leaderId = info.leaderid or ""

  local members = {}
  for _, m in ipairs(mdwui.tbl(info.members)) do members[#members + 1] = m end
  for _, m in ipairs(mdwui.tbl(info.invited)) do members[#members + 1] = m end

  -- Vitals-only updates land on movement and combat state changes (web
  -- client does the same fallback): if one arrives before the roster ever
  -- did, show the group from vitals rather than claiming there is none.
  if #members == 0 and #vitals > 0 then
    for _, v in ipairs(vitals) do
      members[#members + 1] = { id = v.id, name = v.name, position = "",
        companion = v.companion,
        status = v.companion and "companion"
          or ((v.id == leaderId) and "leader" or "group") }
    end
  end

  local rows = {}
  if #members == 0 then
    rows[1] = { id = "none", type = "text",
      text = string.format("<%s>Not in a group", C.dim) }
  else
    -- Info and Vitals join on the server-assigned id, NEVER the name: two
    -- members can each have a companion of the same name, which is the
    -- reason the ids exist (gmcp.Group.go groupMemberId).
    local statsById = {}
    for _, v in ipairs(vitals) do
      if v.id then statsById[v.id] = v end
    end

    -- Row ids by position: a vitals change updates the same elements in
    -- place, and a roster change resizes the whole set (MDW diffs the ids).
    for i, m in ipairs(members) do
      local stats = statsById[m.id] or {}
      local invited = m.status == "invited"
      local isLeader = (leaderId ~= "" and m.id == leaderId) or m.status == "leader"
      -- The web client fences each member in a bordered card; a stack of
      -- rows has no box to draw, so members are divided by the Character
      -- panel's rule instead (same .char-divider color). Between cards
      -- only - a trailing rule would just fence off empty space.
      if i > 1 then
        rows[#rows + 1] = { id = "sep_" .. i, type = "text", text = "",
          height = g.grpGap, css = string.format(
            "background-color: rgba(0,0,0,0%%); border-top: 1px solid rgb(%s);",
            C.charDivider) }
      end

      local tag
      if invited then
        tag = "invited"
      elseif m.companion then
        tag = "companion"
      else
        -- Level comes from Vitals, position from Info: "L2 middle".
        tag = "L" .. tostring(stats.level or 0)
        if m.position and m.position ~= "" then tag = tag .. " " .. m.position end
      end
      -- The name itself only ever carries the aggro red (the web client's
      -- card border, which a row of labels cannot draw): the leader is
      -- spelled out beside it instead, so the two never contest one color -
      -- a leader in combat shows both. Only the WORD is colored; the
      -- brackets stay the panel's muted label gray.
      local nameColor = stats.aggro and C.bad or C.charHeader
      local header = string.format("<%s>%s%s", nameColor, m.name or "?",
        isLeader and string.format(" <%s>(<%s>leader<%s>)",
          C.charLabel, C.grpLeader, C.charLabel) or "")
      -- Class rides the name line rather than its own (.grp-meta in the web
      -- client): two lines per member is the whole point of this layout.
      if m.class and m.class ~= "" then
        header = header .. string.format(" <%s>%s", C.grpClass, m.class)
      end
      -- The autoattack mode rides the name line and the level/position tag
      -- the gauge line below it. A charmed creature has no mode of its own -
      -- it fights when its owner does - and an invited player has no gauge
      -- line at all, so for both the tag stays up here and their name line's
      -- right column is never left empty.
      local mode
      if not (invited or m.companion) then
        mode = string.format("<%s>%s", m.autoattack and C.grpAuto or C.grpManual,
          m.autoattack and "auto" or "manual")
      end
      local tagText = string.format("<%s>%s", C.grpTag, tag)
      rows[#rows + 1] = { id = "name_" .. i, type = "text", text = header,
        rightText = mode or tagText }

      -- Invited players have not accepted yet - no vitals to show (web rule).
      if not invited then
        -- Exact values when the server sent them, else the percentage the
        -- bar is drawn from anyway (updateGroupPanel's fallback).
        local hp = tonumber(stats.healthcurrent) or 0
        local hpMax = tonumber(stats.healthmax) or 0
        local value, max, label
        if hpMax > 0 then
          value, max = hp, hpMax
          label = string.format("%s/%s", mdwui.fmtNum(hp), mdwui.fmtNum(hpMax))
        else
          value, max = tonumber(stats.health) or 0, 100
          label = value .. "%"
        end
        -- The tag shares the gauge's line, in the slice MDW carves off the
        -- bar for it - except for a companion, whose tag stayed on the name
        -- line above, so its bar runs full width.
        rows[#rows + 1] = { id = "hp_" .. i, type = "gauge",
          value = value, max = max, height = g.grpHeight, text = label,
          front = mdwui.fillCss(mdwui.grpFillColor(value, max)),
          back = mdwui.trackCss(g.grpTrack),
          fgColor = g.textColor, fontSize = g.fontSize,
          rightText = mode and tagText or nil }
      end
    end
  end

  mdw.setWidgetRows("Group", rows)
  -- Rows carry everything; clear console text a pre-rows version left behind.
  widget.content:clear()
end

---------------------------------------------------------------------------
-- EQUIPMENT (Char.Inventory.Worn) - guide 5.4
-- The web client's equipment panel (updateEquipSlot + the .eq-section
-- markup): Weapons/Armor/Jewelry sections, right-aligned gold slot labels,
-- teal item names led by [C][E][Q] flags, "-nothing-"/"-disabled-" empties.
-- Each occupied row is ONE link carrying the item tooltip: Mudlet consoles
-- have no hover events, so the hand cursor plus the tooltip anywhere on the
-- line stand in for the web's .eq-slot:hover row highlight.
---------------------------------------------------------------------------

-- [C][E][Q] before the name, "matching in-game display" (updateEquipSlot
-- builds the same letters from `details`; unknown details have no flag).
local function eqFlags(details)
  local C = mdwui.config.colors
  local flags = {}
  for _, d in ipairs(mdwui.tbl(details)) do
    local color = (d == "cursed" and C.flagCursed)
      or (d == "enchanted" and C.flagEnchanted)
      or (d == "quest" and C.flagQuest)
    if color then
      flags[#flags + 1] = string.format("<%s>[<%s>%s<%s>]",
        C.flagBracket, color, d:sub(1, 1):upper(), C.flagBracket)
    end
  end
  if #flags == 0 then return "" end
  return table.concat(flags) .. " "
end

function mdwui.renderEquipment()
  local widget = mdwui.w("Equipment")
  if not widget then return end
  local C = mdwui.config.colors
  local worn = mdwui.tbl(gmcp and gmcp.Char and gmcp.Char.Inventory and gmcp.Char.Inventory.Worn)
  local co = widget.content
  co:clear()

  for si, section in ipairs(mdwui.config.wornSections) do
    if si > 1 then co:decho("\n") end -- .eq-section spacing
    co:decho(string.format("<%s>%s:\n", C.charHeader, section.header))
    for _, slot in ipairs(section.slots) do
      local key, slotLabel = slot[1], slot[2]
      local item = worn[key]
      -- 9 fits the longest label ("Mainhand:"), right-aligned (.eq-label)
      local label = string.format("<%s>%9s ", C.charGold, slotLabel .. ":")
      if item and item.name and item.name ~= "" and item.name ~= "disabled" then
        -- Tooltip: details title-cased as their own lines, then the fixed
        -- remove verb - updateEquipSlot's exact box.
        local extra = {}
        for _, d in ipairs(mdwui.tbl(item.details)) do
          extra[#extra + 1] = mdwui.titleCase(d)
        end
        extra[#extra + 1] = "Use: Remove"
        -- The row opens the action menu: Remove then Look, the web client's
        -- equipment menu (gmcp-ui.js) - and Remove takes the SLOT name.
        mdwui.menuLink(co,
          label .. eqFlags(item.details) .. string.format("<%s>%s", C.itemTeal, item.name),
          item.name, {
            { label = "Remove", command = "remove " .. key },
            { label = "Look", command = "look " .. (item.id or "") },
          }, mdwui.itemTooltip(item, extra))
      else
        -- name == "disabled" is a real server state (updateEquipSlot)
        local empty = (item and item.name == "disabled") and "-disabled-" or "-nothing-"
        co:decho(label .. string.format("<%s>%s", C.faint, empty))
      end
      co:decho("\n")
    end
  end
end

---------------------------------------------------------------------------
-- INVENTORY (Char.Inventory.Backpack.Items + .Summary) - guide 5.5
---------------------------------------------------------------------------

--- Shared numbered list for Inventory and Forage (updateInventoryList and
-- updateIngredientsList render identically): " N - name (qty|uses)" rows,
-- each row ONE link carrying the item tooltip - same hover reasoning as the
-- equipment panel. Menus mirror the web client (gmcp-ui.js): inventory is
-- [own verb?, Look, Drop] - items know their primary verb (guide 8.9) - and
-- the ingredient bag leads with Eat (the eat command consumes straight from
-- the bag), then the verb unless it IS eat.
local function renderItemList(co, items, isForage)
  local C = mdwui.config.colors
  for i, item in ipairs(mdwui.tbl(items)) do
    local id = item.id or ""
    local verb = (item.command and item.command ~= "")
      and (item.command:gsub("^%l", string.upper)) or nil
    -- A function, so the list is built when the menu OPENS: the Sell row
    -- depends on the room the player is in by then, and rooms change
    -- without any inventory push repainting this list.
    local actions = function()
      local list = {}
      if isForage then
        list[#list + 1] = { label = "Eat", command = "eat " .. id }
      end
      if verb and not (isForage and item.command == "eat") then
        list[#list + 1] = { label = verb, command = item.command .. " " .. id }
      end
      list[#list + 1] = { label = "Look", command = "look " .. id }
      list[#list + 1] = { label = "Drop", command = "drop " .. id }
      -- The sell command reaches the backpack and the ingredient bag only
      -- (sell.go), so both lists offer it - worn gear can't sell, which is
      -- why the Equipment menu has no such row.
      if mdwui.inShop() then
        list[#list + 1] = { label = "Sell", command = "sell " .. id }
      end
      return list
    end

    -- (quantity), else (uses) when consumable, after the name (.inv-qty)
    local qty = tonumber(item.quantity) or 0
    local uses = tonumber(item.uses) or 0
    local count = (qty > 1 and qty) or (uses > 0 and uses) or nil
    local extra = {}
    if verb then extra[#extra + 1] = "Use: " .. verb end
    if uses > 0 then extra[#extra + 1] = "Uses: " .. uses end
    mdwui.menuLink(co, string.format("<%s>%2d - <%s>%s%s", C.charGold, i,
      C.itemTeal, item.name or "?",
      count and string.format(" <%s>(%d)", C.charHeader, count) or ""),
      item.name or "item", actions, mdwui.itemTooltip(item, extra))
    co:decho("\n")
  end
end

--- The .inv-footer under both lists: "N out of max items." over a rule.
-- N counts rendered stacks (#items), not Summary.count - both bag caps
-- limit distinct stacks, and the web footer counts the same way.
local function itemFooter(widget, co, items, max)
  local C = mdwui.config.colors
  co:decho("\n")
  mdwui.divider(co, mdwui.wrapWidth(widget, 24))
  co:decho(string.format("<%s>%d out of %s items.\n", C.charLabel, #items, tostring(max)))
end

function mdwui.renderInventory()
  local widget = mdwui.w("Inventory")
  if not widget then return end
  local C = mdwui.config.colors
  local inv = (gmcp and gmcp.Char and gmcp.Char.Inventory) or {}
  local backpack = inv.Backpack or {}
  local co = widget.content
  co:clear()

  local items = mdwui.tbl(backpack.Items)
  if #items == 0 then
    -- Empty skips the footer too (updateInventoryList returns early)
    co:decho(string.format("<%s>Your backpack is empty.\n", C.faint))
    return
  end
  renderItemList(co, items, false)
  local summary = backpack.Summary
  if summary and summary.max then
    itemFooter(widget, co, items, summary.max)
  end
end

---------------------------------------------------------------------------
-- KEYRING (Char.Inventory.Keyring) - guide 5.6
-- The web client's keychain table (updateKeychainList in gmcp-ui.js):
-- Type | Location | Exit columns under a header row, location rendered as
-- "#roomid name", `where` (exit or container) capitalized; lockpicks carry
-- their pick sequence on a second, indented line (.key-sequence-row).
---------------------------------------------------------------------------

function mdwui.renderKeyring()
  local widget = mdwui.w("Keyring")
  if not widget then return end
  local C = mdwui.config.colors
  local keyring = mdwui.tbl(gmcp and gmcp.Char and gmcp.Char.Inventory and gmcp.Char.Inventory.Keyring)
  local co = widget.content
  co:clear()

  if #keyring == 0 then
    co:decho(string.format("<%s>Your keyring is empty.\n", C.faint))
    return
  end

  -- .key-col-where is a fixed 50px in CSS; character cells size to the
  -- widest exit instead (capped so a long container name cannot starve the
  -- location column) to keep the right alignment exact.
  local exitW = 4 -- "Exit"
  for _, key in ipairs(keyring) do
    exitW = math.min(9, math.max(exitW, #tostring(key.where or "-")))
  end

  local W = mdwui.wrapWidth(widget, 24)
  local cols = { { width = 9 }, { stretch = true }, { width = exitW, right = true } }
  mdwui.tableHeader(co, W, cols, { "Type", "Location", "Exit" })
  for _, key in ipairs(keyring) do
    local exit = tostring(key.where or "-"):gsub("^%l", string.upper)
    mdwui.tableRow(co, W, cols, {
      { key.type or "Key", C.charGold },
      { string.format("#%s %s", tostring(key.roomid or "?"), key.location or "?"), C.charHeader },
      { exit, C.charLabel },
    })
    -- sequence is only meaningful for lockpicks (guide 5.6)
    if key.type == "Lockpick" and key.sequence and key.sequence ~= "" then
      co:decho(string.format("%s<%s>Sequence: <%s>%s\n",
        string.rep(" ", cols[1].width), C.dim, C.itemTeal, key.sequence))
    end
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

  local items = mdwui.tbl(bag.items)
  if #items == 0 then
    co:decho(string.format("<%s>Your ingredient bag is empty.\n", C.faint))
    return
  end
  renderItemList(co, items, true)
  if bag.max then
    itemFooter(widget, co, items, bag.max)
  end
end
