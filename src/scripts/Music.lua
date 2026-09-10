--[[
  Music.lua
  The Sound header menu: the master volume, mute, and the catalog the player
  plays from and builds a playlist with (guide section 5.16).

  It is the web client's own sound menu, the one in the site nav
  (webclient.html's `.sound-menu`): the volume slider, the Mute box, a
  divider, the catalog, and Repeat/Shuffle under it. This package had a Music
  WIDGET rendering the same panel and it is gone - one surface for this, not
  two, and the menu is where the web client puts it.

  One row is ours rather than the web's: Stop, under the slider. The web menu
  has none, and mute is not one - it silences the sound effects too and leaves
  the track playing underneath it.

  A web track row carries two controls - a checkbox for the playlist, a title
  that plays - and so does this one: MDW menu rows take `onCheck` for the box
  and `onClick` for the rest of the row. That capability was added for this
  menu (MDW 0.9.3); the row is one row, as the web's is.

  Two packages feed it and it asks for neither: Game.Music is the shared
  catalog (fixed for the life of the server process) and Char.Audio this
  character's own settings, pushed after every change. Both ride the login
  batch and SendFullPayload, which buildUI already requests, so the menu is
  short until they land. Its `items` is a FUNCTION, so every open re-reads
  them and nothing has to repaint on a push.

  This is the ONE surface in the package whose affordances are not real game
  commands. The `music` command answers with feedback, and a slider drag or a
  box tick must not fill the main window with it, so audio has a silent
  write node of its own - Char.Audio.Set (guide 5.16). Every field of it
  still maps to a command a player could type, which is the outbound rule
  kept in spirit.

  Dependencies: Config.lua, Core.lua.
]]

---------------------------------------------------------------------------
-- THE WRITE NODE (Char.Audio.Set)
-- Encoded here rather than through a library: the package has a JSON
-- DECODER (Mudlet's json_to_value, which the Journal reads book documents
-- with) and no encoder, and every body this node takes is one of four
-- shapes - a string, an int, a bool, an array of ids, or one flat object of
-- ints.
---------------------------------------------------------------------------

-- The server applies fields in this fixed order whatever order they arrive
-- in (guide 5.16), so a body reads the way it is executed - and the same
-- table always encodes to the same bytes, which is what makes a written
-- request something a test can compare against.
local AUDIO_FIELDS = { "mode", "playlist", "repeat", "shuffle", "volumes",
  "music_volume", "track", "next", "ended" }

-- The MSP sound categories Char.Audio.volumes is keyed by, in the order the
-- widget and `ui music` both list them. `environment` is reserved - nothing
-- plays through it yet - but it is a real level the server stores.
mdwui.audioCategories = { "combat", "movement", "environment", "other" }

local function jsonString(s)
  return '"' .. tostring(s):gsub('[\\"]', "\\%0") .. '"'
end

local function jsonValue(v)
  local t = type(v)
  if t == "boolean" then return tostring(v) end
  -- Every number this node takes is an int 0-100; floor rather than %g, so a
  -- slider value that arrived as a float never goes out as "40.0".
  if t == "number" then return string.format("%d", math.floor(v)) end
  if t == "table" then -- an array of track ids (the playlist)
    local parts = {}
    for i, item in ipairs(v) do parts[i] = jsonString(item) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  return jsonString(v)
end

--- The one nested object: category name -> level, in the catalog order above
-- so the bytes are stable.
local function jsonVolumes(volumes)
  local parts = {}
  for _, key in ipairs(mdwui.audioCategories) do
    if volumes[key] ~= nil then
      parts[#parts + 1] = jsonString(key) .. ":" .. jsonValue(volumes[key])
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- Encode one Char.Audio.Set body. Only the fields present go out: an absent
-- field is left alone server-side, which is why an absent `track` and an
-- empty one have to mean different things (guide 5.16).
function mdwui.audioJson(fields)
  local parts = {}
  for _, key in ipairs(AUDIO_FIELDS) do
    local value = fields[key]
    if value ~= nil then
      parts[#parts + 1] = jsonString(key) .. ":"
        .. ((key == "volumes") and jsonVolumes(value) or jsonValue(value))
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- Write to the audio settings. SILENT by contract: the node prints nothing,
-- not even for a value it refused, and every accepted field comes back as a
-- Char.Audio push - so nothing here assumes the write landed. The push is
-- what repaints, which is also how a widget that guessed wrong corrects
-- itself.
function mdwui.audioSet(fields)
  mdwui.request("Char.Audio.Set", mdwui.audioJson(fields))
end

---------------------------------------------------------------------------
-- THE TWO PAYLOADS
---------------------------------------------------------------------------

local function catalog()
  return mdwui.tbl(mdwui.tbl(gmcp and gmcp.Game).Music)
end

local function audio()
  return mdwui.tbl(mdwui.tbl(gmcp and gmcp.Char).Audio)
end

--- Has Char.Audio arrived? Gates every write built FROM the current state -
-- `playlist` replaces the list whole, so a widget that composed one from an
-- empty local table would wipe the character's (guide 5.16, and the web
-- client ignores a click that lands before the first push for the same
-- reason).
local function audioKnown()
  return next(audio()) ~= nil
end

--- One catalog entry by id. Char.Audio speaks ids and the catalog holds the
-- titles, so every join between the two packages goes through here.
function mdwui.musicTrack(id)
  if type(id) ~= "string" or id == "" then return nil end
  for _, track in ipairs(mdwui.tbl(catalog().tracks)) do
    if track.id == id then return track end
  end
  return nil
end

--- The stored playlist as a plain array of ids - the only list a write may
-- be built from (see audioKnown).
local function playlistIds()
  local out = {}
  for _, id in ipairs(mdwui.tbl(audio().playlist)) do
    if type(id) == "string" then out[#out + 1] = id end
  end
  return out
end

--- Is this track in the playlist? That membership is all a checkbox shows -
-- the web panel numbers nothing.
local function inPlaylist(id)
  for _, entry in ipairs(playlistIds()) do
    if entry == id then return true end
  end
  return false
end

local function addToPlaylist(id)
  local ids = playlistIds()
  ids[#ids + 1] = id
  mdwui.audioSet({ playlist = ids })
end

local function removeFromPlaylist(id)
  local out = {}
  for _, entry in ipairs(playlistIds()) do
    if entry ~= id then out[#out + 1] = entry end
  end
  mdwui.audioSet({ playlist = out })
end

--- Set one level. Shared by the sliders and `ui music volume`, so the mouse
-- and the keyboard cannot drift apart.
function mdwui.setMusicVolume(key, value)
  value = math.floor(tonumber(value) or 0)
  if key == "music" then
    mdwui.audioSet({ music_volume = value })
  else
    mdwui.audioSet({ volumes = { [key] = value } })
  end
end

--- Char.Audio is the answer to every write, so every control waits for it
-- rather than painting itself: a box ticks because the server said so - which
-- means the click that writes redraws STALE, because the answer has not
-- arrived yet. Re-declaring is what fixes that: MDW repaints an open menu on
-- a re-declaration (0.9.3), so the box catches up the moment the push lands
-- rather than at the player's next open. It carries the header button's
-- muted/unmuted text too.
function mdwui.onCharAudio()
  mdwui.setupSoundMenu()
end

---------------------------------------------------------------------------
-- TRACK-END RELAY (guide 5.16)
-- A track the server wants an end from is sent with L=1 so it plays one pass
-- and the client says when it ended. The server decides what that end means
-- and answers on {"next":true,"ended":...}. Nothing else advances a playlist,
-- and no timer stands in for this - a track that has run out is the only
-- honest signal.
---------------------------------------------------------------------------

local function baseName(path)
  return tostring(path or ""):match("([^/\\]+)$") or ""
end

--- Ask the server to play `id`.
function mdwui.playTrack(id)
  mdwui.audioSet({ track = id })
end

--- Relay EVERY finished music file, with the name of the file that ended.
-- The SERVER decides what an end means - the next playlist track, the login
-- intro being over and the player's own music taking the music back, or
-- nothing at all - and it already drops the reports it cannot use: a track
-- that loops, a file that is not the one playing now, a player who is not in
-- playlist mode. So the relay needs no conditions beyond the media type.
--
-- It used to test the mode and the current track, and both had to go. The
-- login intro plays before the world does, and it is not in Char.Audio at
-- all, so a check against the current track would never relay its end - and
-- its end is what starts the player's music after login.
--
-- The name is what keeps a switch honest: Mudlet raises sysMediaFinished for
-- a track it STOPPED as well as one that ran out, and every track switch
-- stops the old track first. The server sees a name that is no longer the
-- track playing and drops it, instead of advancing the playlist past the
-- song just picked.
function mdwui.onMediaFinished(_, fileName, _, mediaType)
  if mediaType ~= "music" then return end
  mdwui.audioSet({ next = true, ended = baseName(fileName) })
end

---------------------------------------------------------------------------
-- THE SOUND HEADER MENU (mdw.addHeaderMenu + slider rows, MDW 0.9.3)
-- The whole sound surface, in the place the web client puts it. See the file
-- header for the row-for-row mapping and the one shape that cannot match.
--
-- GUARDED on the function's existence rather than gated by
-- mdwui.minMdwVersion, unlike the other MDW calls in buildUI: this API is
-- newer than the pinned minimum, so a player on the pin gets the UI without
-- the menu instead of a refused build. Raise the pin and this guard becomes
-- decoration, but it costs one `if`.
---------------------------------------------------------------------------

-- The muted state is spelled out in the button rather than drawn: the header
-- renders at headerMenuFontSize, and a speaker icon at that size is too small
-- to read as anything. A word survives the size; a 12px glyph does not.
local MUTED_SUFFIX = " (Muted)"

--- Is game audio muted? Mudlet's own client-side mute, NOT a volume of zero:
-- the web client mutes the same way (a global gain over the sliders,
-- audio.js applyMuteState), leaving the server's stored levels alone so
-- unmuting comes back to what the player chose. Writing 0 through GMCP would
-- overwrite those levels and lose them.
--
-- pcall because getConfig and this key are newer than the oldest Mudlet this
-- package runs on; an unknown key must read as "not muted", not as an error
-- inside a menu getter.
function mdwui.soundMuted()
  local ok, muted = pcall(function() return getConfig("muteMediaGame") end)
  return (ok and muted) and true or false
end

--- Flip it, then re-declare the menu so the button follows. The title is a
-- plain string by contract (mdw.addHeaderMenu rejects a function), but a
-- re-declaration with a new one repaints the button and re-runs
-- layoutHeaderButtons - so the state is live without the API having to grow a
-- getter, and the button re-measures for the longer title.
function mdwui.toggleSoundMute()
  local muted = not mdwui.soundMuted()
  local ok = pcall(function() setConfig("muteMediaGame", muted) end)
  if not ok then
    mdwui.say("This Mudlet cannot mute game audio; set the volumes to 0 instead.")
    return
  end
  mdwui.setupSoundMenu()
end

--- The rows, rebuilt on every open (MDW re-reads an `items` function then), so
-- they show what the server last sent rather than what it sent at build time.
--
-- The order is the web sound menu's: slider, Mute, divider, Music header and
-- hint, the catalog, Repeat/Shuffle. The catalog appears twice for the reason
-- in the file header - one click per row, two controls per web row.
local function soundMenuItems()
  local g = mdwui.config.gauges
  local a = audio()
  local rows = {}
  local function add(row) rows[#rows + 1] = row end

  -- "Volume [====] [ ] Mute" as ONE row. The web menu stacks its slider over
  -- its Mute box; a dropdown row is wide and shallow, so the two sit together
  -- and the card is two rows shorter. The four sound-effect levels stay on
  -- `ui music volume` - the web menu hides its own category sliders because
  -- nothing plays through them yet.
  add({ parts = {
    { label = "Volume" },
    (mdw.bindSlider and {
      type = "slider", flex = true,
      value = tonumber(a.music_volume) or 0, max = 100, step = 5, text = "",
      front = mdwui.fillCss(g.volFill), back = mdwui.trackCss(g.volTrack),
      fgColor = g.textColor,
      -- Raising the volume off zero is a request to hear something, so unmute
      -- - changeWebclientVolume does exactly this.
      onChange = function(value)
        mdwui.setMusicVolume("music", value)
        if value > 0 and mdwui.soundMuted() then mdwui.toggleSoundMute() end
      end,
    }) or { label = "(no slider on this MDW)" },
    { label = "Mute", checked = mdwui.soundMuted,
      onCheck = function() mdwui.toggleSoundMute() end },
  } })
  -- Mute was the only way to shut the music up, and it silences the sound
  -- effects with it. This is the other one: an empty `track` stops the music
  -- and hands the choosing back to the world (guide 5.16), which is what
  -- `music stop` and `ui music stop` both write.
  --
  -- ABOVE the divider, in the master-audio group rather than with the playlist
  -- ends at the foot of the card: it acts on whatever is playing, including
  -- the login intro that plays before the catalog has arrived, so it must not
  -- sit behind a scroll of songs - the same argument that puts Repeat and
  -- Shuffle over the list. Not gated on Char.Audio either: the write is built
  -- from nothing the server has to have told us first.
  add({ label = "Stop the music", keepOpen = true,
    onClick = function() mdwui.audioSet({ track = "" }) end })
  add({ separator = true })

  local tracks = mdwui.tbl(catalog().tracks)
  if #tracks == 0 then
    -- A menu that currently lists nothing still says why: the catalog rides
    -- the login batch, so this is what an early open sees.
    add({ label = "No music has arrived yet" })
    return rows
  end

  -- No playlist edits until Char.Audio has been seen: the write replaces the
  -- list whole, so building one from what we have not been told wipes it. The
  -- web swallows the same click for the same reason - and the boxes still
  -- DRAW either way.
  local known = audioKnown()

  -- Repeat and Shuffle lead, on one row: they describe how the list below is
  -- played, so they belong above it rather than after a scroll of songs.
  add({ parts = {
    { label = "Repeat", checked = function() return a["repeat"] and true or false end,
      onCheck = known and function()
        mdwui.audioSet({ ["repeat"] = not a["repeat"] })
      end or nil },
    { label = "Shuffle", checked = function() return a.shuffle and true or false end,
      onCheck = known and function()
        mdwui.audioSet({ shuffle = not a.shuffle })
      end or nil },
  } })
  -- Inert by construction: no onClick, no onCheck, so MDW gives it no cursor
  -- and no hover. It is a caption, and one that lit up under the pointer
  -- would read as a button that does nothing.
  add({ label = "Click a title to play. Tick a box for the playlist." })

  for _, track in ipairs(tracks) do
    local id = track.id
    if type(id) == "string" and id ~= "" then
      local title = tostring(track.title or id)
      add({
        -- The playing one says so in the label rather than in a colour: a
        -- menu row has one colour, and it is the highlight the pointer owns.
        label = function()
          local now = mdwui.musicTrack(audio().track)
          return title .. ((now and now.id == id) and "  (playing)" or "")
        end,
        checked = function() return inPlaylist(id) end,
        onCheck = known and function()
          if inPlaylist(id) then removeFromPlaylist(id) else addToPlaylist(id) end
        end or nil,
        -- keepOpen like the boxes: picking a song is not navigation, and the
        -- player is usually picking a few things in a row.
        keepOpen = true,
        onClick = function() mdwui.playTrack(id) end,
      })
    end
  end

  -- The two ends of the playlist, spelled out rather than left implied by the
  -- mode field: nothing on this card otherwise says who is choosing.
  add({ separator = true })
  add({ label = "Play playlist", keepOpen = true,
    onClick = function() mdwui.audioSet({ mode = "playlist" }) end })
  add({ label = "Clear playlist and let game control music", keepOpen = true,
    onClick = function() mdwui.audioSet({ playlist = {}, mode = "server" }) end })

  -- The server sends no MSP at all while this is off, whatever the rest of
  -- the payload says (guide 5.16), so say so under the controls that will not
  -- be heard. `config sound on` is a real typed command, unlike everything
  -- else here.
  if a.sound == false then
    add({ separator = true })
    add({ label = "Sound is off - click to turn it on",
      onClick = function() send("config sound on", false) end })
  end
  return rows
end

--- Declared from buildUI, like the gear row: MDW stamps it with this package
-- and reaps it with us, and a re-declaration replaces the menu in place
-- rather than adding a second button.
--
-- The title follows the package's own Mute row. A mute made from Mudlet's
-- toolbar instead is only picked up on the next re-declaration: Mudlet raises
-- no event for it (its media events are started, paused and finished), and
-- polling the setting is not worth a timer. The right fix is an event in
-- Mudlet itself.
function mdwui.setupSoundMenu()
  if not (mdw and mdw.addHeaderMenu) then return end
  mdw.addHeaderMenu({
    id = "sound",
    title = "Sound" .. (mdwui.soundMuted() and MUTED_SUFFIX or ""),
    items = soundMenuItems,
  })
end
