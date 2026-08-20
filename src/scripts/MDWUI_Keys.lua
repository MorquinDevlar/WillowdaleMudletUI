--[[
  MDWUI_Keys.lua
  Numpad walking: the package's native key folder and the toggle that arms it.

  Numpad walking is the package's own NATIVE key folder (src/keys, named by
  mdwui.config.numpadKeyFolder) rather than something bound from Lua: native
  so the bindings are visible and editable in Mudlet's Keys editor, and so
  Mudlet owns their lifecycle - installed and removed with the package, no
  per-session rebinding. It transcribes the web client's keypad shortcuts
  (input.js codeShortcuts): the keypad walks the eight compass directions, 5
  looks, and -/+ climb. ONLY the NumLock-on codes are bound (keypad+digit,
  keypad+minus/plus), because on macOS Qt stamps the Keypad modifier on the
  MAIN keyboard's arrow keys too - the NumLock-off twins (keypad+Up and
  friends) walked the character on every arrow press. PC keypads therefore
  need NumLock on; Mac keypads always send the digit.

  As in the web client, a keypad press moves even while the command line
  holds text - Mudlet hands every Keypad-modified press to the key bindings
  before the command line sees it (TCommandLine's "Shortcut for keypad
  keys"), so a matched key eats the press and cannot be typed past. Which is
  why OFF has to DISABLE the folder rather than no-op (a disabled key lets
  the digit through), and why it toggles at all; the choice persists in MDW's
  layout file like every other player toggle.

  The `ui numpad` command's binding points are the public functions here:
  mdwui.numpadWalking() / setNumpadWalking(on) / toggleNumpadWalking().

  Dependencies: MDWUI_Config.lua, MDWUI_Core.lua.
]]

---------------------------------------------------------------------------
-- THE NATIVE KEY FOLDER
---------------------------------------------------------------------------

--- (Re)apply the folder's enabled state: buildUI calls this on every MDW
-- setup, and the toggle below calls it live.
--
-- Disabling numpad walking has to DISABLE the folder rather than no-op: a
-- matched key eats the press whatever its script does, so a key left enabled
-- would swallow the digit instead of typing it.
function mdwui.applyNumpadKeys()
  -- Mudlet installs the folder active with the package (and again on every
  -- package update), so the saved choice is re-applied on every build.
  local folder = mdwui.config.numpadKeyFolder
  if mdwui.numpadWalking() then
    if enableKey then pcall(enableKey, folder) end
  elseif disableKey then
    pcall(disableKey, folder)
  end
end

---------------------------------------------------------------------------
-- THE PLAYER TOGGLE (ui numpad [on|off])
---------------------------------------------------------------------------

function mdwui.numpadWalking()
  return mdwui.settings("keys", mdwui.config.keyDefaults).numpad and true or false
end

--- Set numpad walking on/off, apply it live, and persist. Returns the new
-- state so a caller can report it.
function mdwui.setNumpadWalking(on)
  local s = mdwui.settings("keys", mdwui.config.keyDefaults)
  s.numpad = on and true or false
  mdwui.applyNumpadKeys()
  mdwui.saveSettings()
  return s.numpad
end

function mdwui.toggleNumpadWalking()
  return mdwui.setNumpadWalking(not mdwui.numpadWalking())
end
