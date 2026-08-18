--[[
  MDWUI_Combat.lua
  The Combat widget (gauges, status, clickable enemy list) and the GMCP-driven
  prompt bar.

  Combat data cadence is per-beat while engaged (guide section 4), so the
  renderer must be cheap: one clear + a handful of decho lines.

  Dependencies: MDWUI_Config.lua, MDWUI_Core.lua.
]]

---------------------------------------------------------------------------
-- COMBAT WIDGET
---------------------------------------------------------------------------

--- Combat can end two ways (guide 8.17): Char.Combat.Ended, or Status with
-- in_combat:false. Both funnel here; the stale per-beat payloads in the gmcp
-- table must not keep painting a fight that is over, hence the local flag.
function mdwui.setInCombat(flag)
  mdwui.state.inCombat = flag and true or false
  mdwui.renderCombat()
end

function mdwui.renderCombat()
  local widget = mdwui.w("Combat")
  if not widget then return end
  local cfg = mdwui.config
  local C = cfg.colors
  local char = (gmcp and gmcp.Char) or {}
  local vitals = char.Vitals or {}
  local combat = char.Combat or {}
  local co = widget.content
  co:clear()

  -- The four gauges (HP / AE / Balance / Enemy), always visible - they are
  -- the web client's prompt-bar gauges, which a text prompt cannot carry.
  co:decho(mdwui.gauge(vitals.health, vitals.health_max,
    mdwui.healthColor(vitals.health, vitals.health_max),
    string.format("<%s>HP %s/%s", C.text, mdwui.fmtNum(vitals.health), mdwui.fmtNum(vitals.health_max))) .. "\n")
  co:decho(mdwui.gauge(vitals.aether, vitals.aether_max, C.aether,
    string.format("<%s>AE %s/%s", C.text, mdwui.fmtNum(vitals.aether), mdwui.fmtNum(vitals.aether_max))) .. "\n")

  -- Balance: when is_balanced, the numbers are noise - full bar + "Balanced"
  -- (guide 8.4; `seconds` is a preformatted STRING, shown verbatim).
  local bal = char.Balance or {}
  if bal.is_balanced or bal.balance == nil then
    co:decho(mdwui.gauge(1, 1, C.balance, string.format("<%s>Balanced", C.text)) .. "\n")
  else
    co:decho(mdwui.gauge(bal.balance, bal.max_balance, C.balance,
      string.format("<%s>%ss", C.text, tostring(bal.seconds or ""))) .. "\n")
  end

  -- Enemy gauge: empty name is the "no target" sentinel (guide 8.6).
  local target = combat.Target or {}
  local hasTarget = target.name and target.name ~= ""
  if hasTarget then
    co:decho(mdwui.gauge(target.hp_current, target.hp_max,
      mdwui.healthColor(target.hp_current, target.hp_max),
      string.format("<%s>%s", C.bad, target.name)) .. "\n")
  else
    co:decho(mdwui.gauge(0, 1, C.dim, string.format("<%s>No Enemy", C.dim)) .. "\n")
  end

  if not mdwui.state.inCombat then
    co:decho(string.format("<%s>Not in combat\n", C.dim))
    return
  end

  -- Status text rule from the web client (guide 5.2): explicit action wins,
  -- then engaged-in-melee, else advancing.
  local status = combat.Status or {}
  local statusText
  if status.combat_action and status.combat_action ~= "" then
    statusText = status.combat_action
  elseif status.in_melee then
    statusText = "engaged"
  else
    statusText = "advancing"
  end
  co:decho(string.format("<%s>(%s)\n", C.warn, statusText))

  -- Enemy list: name is a click-to-target link; (T) marks the live target by
  -- Target.id, which wins over is_primary when they disagree (guide 8.18).
  -- Combat ids are bare ints - the command needs the # prefix (guide 8.8).
  local targetId = hasTarget and target.id or nil
  for _, enemy in ipairs(combat.Enemies or {}) do
    local marker = (enemy.id == targetId) and string.format("<%s>(T) ", C.warn) or "    "
    co:decho(marker)
    mdwui.link(co, string.format("<%s>%s", C.text, enemy.name or "?"),
      "target #" .. tostring(enemy.id), "target " .. (enemy.name or "enemy"))
    co:decho(" " .. mdwui.gauge(enemy.health, enemy.health_max,
      mdwui.healthColor(enemy.health, enemy.health_max), "") .. "\n")
  end
end

--- Auto-target is a CLIENT behaviour the server will not do for us (guide
-- 8.19): when the live target drops out of the enemy list but enemies
-- remain, retarget the first one - replicated from the web client.
function mdwui.onCombatEnemies()
  local combat = (gmcp and gmcp.Char and gmcp.Char.Combat) or {}
  local enemies = combat.Enemies or {}
  if #enemies > 0 then
    mdwui.state.inCombat = true
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
  mdwui.renderCombat()
end

function mdwui.onCombatStatus()
  local status = (gmcp and gmcp.Char and gmcp.Char.Combat and gmcp.Char.Combat.Status) or {}
  mdwui.setInCombat(status.in_combat)
end

---------------------------------------------------------------------------
-- PROMPT BAR (Char.Vitals.prompt / prompt2)
-- The server renders the player's real prompt to ANSI for Mudlet (guide 8.2),
-- so the bar mirrors in-game prompt config exactly. The numeric fields are
-- the fallback for payloads without a prompt string.
---------------------------------------------------------------------------

function mdwui.updatePromptBar()
  if not (mdw and mdw.setPrompt) then return end
  local vitals = (gmcp and gmcp.Char and gmcp.Char.Vitals) or {}
  local C = mdwui.config.colors

  local line
  if vitals.prompt and vitals.prompt ~= "" then
    line = mdwui.ansiToDecho(vitals.prompt)
    if vitals.prompt2 and vitals.prompt2 ~= "" then
      line = line .. "\n" .. mdwui.ansiToDecho(vitals.prompt2)
    end
  else
    line = string.format("<%s>[<%s>HP:%s/%s <%s>AE:%s/%s<%s>]:",
      C.text, mdwui.healthColor(vitals.health, vitals.health_max),
      mdwui.fmtNum(vitals.health), mdwui.fmtNum(vitals.health_max),
      C.aether, mdwui.fmtNum(vitals.aether), mdwui.fmtNum(vitals.aether_max), C.text)
  end
  mdw.setPrompt(line)
end

--- Char.Vitals feeds three surfaces at once (rate-limited server-side to
-- one push per 100ms, so this stays cheap enough).
function mdwui.onVitals()
  mdwui.updatePromptBar()
  mdwui.renderCombat()
  mdwui.renderCharacter()
end
