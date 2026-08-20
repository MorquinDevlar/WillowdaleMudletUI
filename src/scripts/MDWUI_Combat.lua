--[[
  MDWUI_Combat.lua
  The Combat widget (real gauges, status, clickable enemy list), the
  GMCP-driven prompt bar with its gauge layer, and the two vertical-ellipsis
  settings menus (prompt bar + Combat widget), all mirroring the web client.

  Combat data cadence is per-beat while engaged (guide section 4), so the
  render path must stay cheap: MDW's setWidgetRows diffs rows in place, and
  gauge restyles only happen on band crossings.

  Dependencies: MDWUI_Config.lua, MDWUI_Core.lua.
]]

---------------------------------------------------------------------------
-- COMBAT WIDGET
-- The web combat panel (webclient-pure.html #combat-panel): enemy name
-- list, PLAYER gauges (HP/AE/Balance), enemy health bars - every section
-- behind a settings toggle from the widget's menu.
---------------------------------------------------------------------------

--- Bring a widget's stack tab to the front, but never resurrect one the
-- player closed or hid: the web client's setCombatActive only activates a
-- panel that exists. isVisible covers exactly that split - true for any
-- member of a shown group (inactive tabs included), false once closed - and
-- Widget:show on a visible member reduces to selecting its tab.
local function bringToFront(name)
  local widget = mdw and mdw.widgets and mdw.widgets[name]
  if widget and widget.isVisible and widget.show and widget:isVisible() then
    widget:show()
  end
end

--- Combat can end two ways (guide 8.17): Char.Combat.Ended, or Status with
-- in_combat:false. Both funnel here; the stale per-beat payloads in the gmcp
-- table must not keep painting a fight that is over, hence the local flag.
function mdwui.setInCombat(flag)
  flag = flag and true or false
  local was = mdwui.state.inCombat and true or false
  mdwui.state.inCombat = flag
  -- Auto-switch tabs like the web client (setCombatActive, gmcp-ui.js):
  -- Combat to the front when a fight starts, Character back when it ends.
  -- Only on the TRANSITION - the web re-asserts per combat beat, but here
  -- per-push switching would wrestle a player who tabbed away mid-fight and
  -- let the login batch's idle Status steal whatever tab the layout restored.
  if flag ~= was then
    bringToFront(flag and "Combat" or "Character")
  end
  mdwui.renderCombat()
  mdwui.updatePromptGauges() -- the prompt bar's enemy gauge clears with combat
end

--- Balance gauge state shared by the prompt layer and the Combat widget:
-- full bar + "Balanced" when is_balanced - the numbers are noise then
-- (guide 8.4) - else drain, showing the preformatted `seconds` STRING
-- verbatim in the dimmer draining fill.
local function balanceGauge()
  local g = mdwui.config.gauges
  local bal = (gmcp and gmcp.Char and gmcp.Char.Balance) or {}
  if bal.is_balanced or bal.balance == nil then
    return 1, 1, "Balanced", g.balFill
  end
  return tonumber(bal.balance) or 0, tonumber(bal.max_balance) or 1,
    tostring(bal.seconds or "") .. "s", g.balFillDrain
end

function mdwui.renderCombat()
  local widget = mdwui.w("Combat")
  if not widget then return end
  -- Under an MDW predating the rows API the widget simply stays empty.
  if not (mdw and mdw.setWidgetRows) then return end
  local cfg = mdwui.config
  local C = cfg.colors
  local g = cfg.gauges
  local s = mdwui.settings("combat", cfg.combatDefaults)
  local char = (gmcp and gmcp.Char) or {}
  local vitals = char.Vitals or {}
  local combat = char.Combat or {}
  local target = combat.Target or {}
  local targetId = (target.name and target.name ~= "") and target.id or nil
  local inCombat = mdwui.state.inCombat
  local enemies = mdwui.tbl(combat.Enemies)

  local rows = {}
  local function header(id, text)
    rows[#rows + 1] = { id = id, type = "text", height = g.headerHeight,
      fontSize = g.headerFontSize, text = string.format("<%s>%s", C.charLabel, text) }
  end
  local function gaugeRow(id, value, max, text, fill, track)
    rows[#rows + 1] = { id = id, type = "gauge", value = value, max = max,
      text = text, front = mdwui.fillCss(fill), back = mdwui.trackCss(track),
      fgColor = g.textColor, fontSize = g.fontSize }
  end

  -- The web client dims the whole panel instead (combat-inactive opacity);
  -- Qt labels cannot fade wholesale, so say it in a row.
  if not inCombat then
    rows[#rows + 1] = { id = "idle", type = "text",
      text = string.format("<%s>Not in combat", C.dim) }
  end

  -- Section order mirrors the web panel: names, player, enemy bars.
  if s.info then
    header("hdr_names", "ENEMIES:")
    if inCombat then
      -- Status text rule (guide 5.2): explicit action wins, then
      -- engaged-in-melee, else advancing. Shown after the target's name.
      local status = combat.Status or {}
      local statusText
      if status.combat_action and status.combat_action ~= "" then
        statusText = status.combat_action
      elseif status.in_melee then
        statusText = "engaged"
      else
        statusText = "advancing"
      end
      for _, enemy in ipairs(enemies) do
        -- (T) marks the live target by Target.id, which wins over
        -- is_primary when they disagree (guide 8.18).
        local isTarget = enemy.id == targetId
        local id = enemy.id
        rows[#rows + 1] = { id = "name_" .. tostring(id), type = "text",
          text = string.format("<%s>%s<%s>%s%s", C.charGold, isTarget and "(T) " or "",
            C.text, enemy.name or "?",
            isTarget and string.format(" <%s>(%s)", C.warn, statusText) or ""),
          -- Click-to-target; bare combat ids need the # prefix (guide 8.8).
          onClick = function() send("target #" .. tostring(id)) end }
      end
    end
  end

  header("hdr_player", "PLAYER:")
  if s.hp then
    local hp, hpMax = tonumber(vitals.health) or 0, tonumber(vitals.health_max) or 0
    gaugeRow("hp", hp, hpMax,
      string.format("HP %s/%s", mdwui.fmtNum(hp), mdwui.fmtNum(hpMax)),
      mdwui.hpFillColor(hp, hpMax), g.hpTrack)
  end
  if s.ae then
    local ae, aeMax = tonumber(vitals.aether) or 0, tonumber(vitals.aether_max) or 0
    gaugeRow("ae", ae, aeMax,
      string.format("AE %s/%s", mdwui.fmtNum(ae), mdwui.fmtNum(aeMax)),
      g.aeFill, g.aeTrack)
  end
  if s.balance then
    local value, max, text, fill = balanceGauge()
    gaugeRow("balance", value, max, text, fill, g.balTrack)
  end

  if s.enemy then
    header("hdr_bars", "ENEMIES:")
    if inCombat then
      for _, enemy in ipairs(enemies) do
        local hp, hpMax = tonumber(enemy.health) or 0, tonumber(enemy.health_max) or 0
        gaugeRow("bar_" .. tostring(enemy.id), hp, hpMax,
          string.format("%s %s/%s", enemy.name or "?", mdwui.fmtNum(hp), mdwui.fmtNum(hpMax)),
          g.enemyFill, g.enemyTrack)
      end
    end
  end

  mdw.setWidgetRows("Combat", rows)
  -- Everything lives in the rows; clear any console text a pre-rows version
  -- of this package left behind (mid-session package updates reuse widgets).
  widget.content:clear()
end

--- Auto-target is a CLIENT behaviour the server will not do for us (guide
-- 8.19): when the live target drops out of the enemy list but enemies
-- remain, retarget the first one - replicated from the web client.
function mdwui.onCombatEnemies()
  local combat = (gmcp and gmcp.Char and gmcp.Char.Combat) or {}
  local enemies = mdwui.tbl(combat.Enemies)
  if #enemies == 0 then
    mdwui.renderCombat()
    return
  end
  mdwui.setInCombat(true) -- renders too; a fresh fight fronts the Combat tab
  local target = combat.Target or {}
  if target.name and target.name ~= "" and target.id then
    local present = false
    for _, enemy in ipairs(enemies) do
      if enemy.id == target.id then present = true break end
    end
    if not present then
      send("target #" .. tostring(enemies[1].id))
    end
  end
end

function mdwui.onCombatStatus()
  local status = (gmcp and gmcp.Char and gmcp.Char.Combat and gmcp.Char.Combat.Status) or {}
  mdwui.setInCombat(status.in_combat)
end

---------------------------------------------------------------------------
-- COMBAT WIDGET SETTINGS MENU (web #cw-settings-menu)
---------------------------------------------------------------------------

--- Set one Combat-widget section on or off (nil toggles), repaint, persist.
-- Shared by the menu row below and `ui combat <key>`, so the mouse and the
-- keyboard cannot drift apart. Returns the new value.
function mdwui.setCombatOption(key, value)
  local s = mdwui.settings("combat", mdwui.config.combatDefaults)
  if value == nil then value = not s[key] end
  s[key] = value and true or false
  mdwui.renderCombat()
  mdwui.saveSettings()
  return s[key]
end

local function combatMenuItems()
  local s = mdwui.settings("combat", mdwui.config.combatDefaults)
  local function toggle(key, label)
    return { label = label, checked = s[key] and true or false, keepOpen = true,
      onClick = function() mdwui.setCombatOption(key) end }
  end
  return {
    toggle("hp", "HP Gauge"),
    toggle("ae", "AE Gauge"),
    toggle("balance", "Balance"),
    toggle("enemy", "Enemy Gauges"),
    toggle("info", "Enemy Names"),
  }
end

function mdwui.setupWidgetMenus()
  if not (mdw and mdw.setWidgetMenu) then return end
  mdw.setWidgetMenu("Combat", combatMenuItems, "Combat")
end

---------------------------------------------------------------------------
-- PROMPT BAR (Char.Vitals.prompt / prompt2)
-- The server renders the player's real prompt to ANSI for Mudlet (guide 8.2),
-- so the bar mirrors in-game prompt config exactly. The numeric fields are
-- the fallback for payloads without a prompt string. Which lines show is the
-- player's choice: Vitals is line 1, Worth is line 2 (prompt2) - the web
-- client's names for them, defaulting vitals OFF because the gauges already
-- carry those numbers.
---------------------------------------------------------------------------

function mdwui.updatePromptBar()
  if not (mdw and mdw.setPrompt) then return end
  local s = mdwui.settings("promptBar", mdwui.config.promptBarDefaults)
  local vitals = (gmcp and gmcp.Char and gmcp.Char.Vitals) or {}
  local C = mdwui.config.colors

  local parts = {}
  if s.vitals then
    if vitals.prompt and vitals.prompt ~= "" then
      parts[#parts + 1] = mdwui.ansiToDecho(vitals.prompt)
    else
      parts[#parts + 1] = string.format("<%s>[<%s>HP:%s/%s <%s>AE:%s/%s<%s>]:",
        C.text, mdwui.healthColor(vitals.health, vitals.health_max),
        mdwui.fmtNum(vitals.health), mdwui.fmtNum(vitals.health_max),
        C.aether, mdwui.fmtNum(vitals.aether), mdwui.fmtNum(vitals.aether_max), C.text)
    end
  end
  if s.worth and vitals.prompt2 and vitals.prompt2 ~= "" then
    parts[#parts + 1] = mdwui.ansiToDecho(vitals.prompt2)
  end
  if #parts == 0 then
    if mdw.clearPrompt then mdw.clearPrompt() end
  else
    mdw.setPrompt(table.concat(parts, "\n"))
  end
  return #parts
end

---------------------------------------------------------------------------
-- PROMPT-LAYER GAUGES (HP / AE / Balance / Enemy)
-- The web client's prompt-bar gauge set (gmcp-ui.js promptBarSettings;
-- enemy defaults off). Rendered by MDW's prompt-gauge row; this package
-- declares the web-client styles and feeds values.
---------------------------------------------------------------------------

--- Declare the row per the player's settings. Runs from buildUI on every
-- MDW setup and from the settings menu; guarded so an MDW predating the
-- prompt-gauge API just keeps the plain text bar.
function mdwui.setupPromptGauges()
  if not (mdw and mdw.setPromptGauges) then return end
  local g = mdwui.config.gauges
  local s = mdwui.settings("promptBar", mdwui.config.promptBarDefaults)
  local defs = {}
  local function add(id, fill, track)
    defs[#defs + 1] = { id = id, front = mdwui.fillCss(fill), back = mdwui.trackCss(track),
      fgColor = g.textColor, fontSize = g.fontSize }
  end
  if s.hp then add("hp", g.hpFill, g.hpTrack) end
  if s.ae then add("ae", g.aeFill, g.aeTrack) end
  if s.balance then add("balance", g.balFill, g.balTrack) end
  if s.enemy then add("enemy", g.enemyFill, g.enemyTrack) end
  mdw.setPromptGauges(defs)
  -- Fresh gauges carry their default fills - forget remembered bands.
  mdwui.state.hpFillCss = nil
  mdwui.state.balFillCss = nil
  mdwui.updatePromptGauges()
end

--- Repaint the declared gauges from the gmcp table (pure function of it,
-- like the panels; gauges the player toggled off simply do not exist and
-- their setters no-op).
function mdwui.updatePromptGauges()
  if not (mdw and mdw.setPromptGaugeValue) then return end
  local char = (gmcp and gmcp.Char) or {}
  local vitals = char.Vitals or {}

  local hp, hpMax = tonumber(vitals.health) or 0, tonumber(vitals.health_max) or 0
  mdw.setPromptGaugeValue("hp", hp, hpMax,
    string.format("HP %s/%s", mdwui.fmtNum(hp), mdwui.fmtNum(hpMax)))
  -- Band restyles only on crossings - Vitals can arrive 10/sec (guide 4).
  local fill = mdwui.hpFillColor(hp, hpMax)
  if fill ~= mdwui.state.hpFillCss then
    mdwui.state.hpFillCss = fill
    mdw.setPromptGaugeStyle("hp", mdwui.fillCss(fill))
  end

  mdw.setPromptGaugeValue("ae", vitals.aether, vitals.aether_max,
    string.format("AE %s/%s", mdwui.fmtNum(vitals.aether), mdwui.fmtNum(vitals.aether_max)))

  local value, max, text, balFill = balanceGauge()
  mdw.setPromptGaugeValue("balance", value, max, text)
  if balFill ~= mdwui.state.balFillCss then
    mdwui.state.balFillCss = balFill
    mdw.setPromptGaugeStyle("balance", mdwui.fillCss(balFill))
  end

  -- Enemy (web _setEnemyGauge): the live target's name + HP; the empty-name
  -- sentinel (guide 8.6) or combat's end shows the No Enemy idle state.
  local target = (char.Combat or {}).Target or {}
  if mdwui.state.inCombat and target.name and target.name ~= "" then
    mdw.setPromptGaugeValue("enemy", target.hp_current, target.hp_max,
      string.format("%s %s/%s", target.name,
        mdwui.fmtNum(target.hp_current), mdwui.fmtNum(target.hp_max)))
  else
    mdw.setPromptGaugeValue("enemy", 0, 1, "No Enemy")
  end
end

--- Char.Balance repaints its gauge in both the prompt layer and Combat.
function mdwui.onBalance()
  mdwui.updatePromptGauges()
  mdwui.renderCombat()
end

--- Char.Vitals feeds four surfaces at once (rate-limited server-side to
-- one push per 100ms, so this stays cheap enough).
function mdwui.onVitals()
  mdwui.updatePromptBar()
  mdwui.updatePromptGauges()
  mdwui.renderCombat()
  mdwui.renderCharacter()
end

---------------------------------------------------------------------------
-- PROMPT BAR SETTINGS MENU (web #pb-settings-menu)
---------------------------------------------------------------------------

--- Set one prompt-bar element on or off (nil toggles), re-declare the gauge
-- row, refit the bar, persist. Shared by the menu row below and
-- `ui prompt <key>`. Returns the new value.
function mdwui.setPromptBarOption(key, value)
  local s = mdwui.settings("promptBar", mdwui.config.promptBarDefaults)
  if value == nil then value = not s[key] end
  s[key] = value and true or false
  mdwui.setupPromptGauges() -- re-declares the gauge row per the new set
  local lines = mdwui.updatePromptBar()
  -- The bar is content-driven, like the web client's: fit it to the new
  -- element set right here - a re-enabled line shows without dragging, a
  -- hidden one gives its space back, and gauges-only collapses around the
  -- row. Manual splitter drags still work after.
  if mdw.fitPromptBarHeight then
    mdw.fitPromptBarHeight(lines)
  elseif mdw.ensurePromptBarHeight then -- older MDW: at least grow
    mdw.ensurePromptBarHeight(lines)
  end
  mdwui.saveSettings() -- last, so the fitted height persists too
  return s[key]
end

local function promptBarMenuItems()
  local s = mdwui.settings("promptBar", mdwui.config.promptBarDefaults)
  local function toggle(key, label)
    return { label = label, checked = s[key] and true or false, keepOpen = true,
      onClick = function() mdwui.setPromptBarOption(key) end }
  end
  return {
    toggle("vitals", "Vitals"),
    toggle("worth", "Worth"),
    toggle("hp", "HP Gauge"),
    toggle("ae", "AE Gauge"),
    toggle("balance", "Balance"),
    toggle("enemy", "Enemy"),
  }
end

function mdwui.setupPromptBarMenu()
  if not (mdw and mdw.setPromptBarMenu) then return end
  mdw.setPromptBarMenu(promptBarMenuItems, "Prompt Bar")
end
