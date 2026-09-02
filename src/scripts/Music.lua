--[[
  Music.lua
  The Music widget: what is playing, the five volume levels, and the catalog
  the player plays from and builds a playlist with (guide section 5.16).

  Two packages feed it and it asks for neither: Game.Music is the shared
  catalog (fixed for the life of the server process) and Char.Audio this
  character's own settings, pushed after every change. Both ride the login
  batch and SendFullPayload, which buildUI already requests, so the widget
  renders an empty state until they land and repaints on the push.

  This is the ONE surface in the package whose affordances are not real game
  commands. The `music` command answers with feedback, and a slider drag or a
  menu tick must not fill the main window with it, so audio has a silent
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
  "music_volume", "track", "next" }

-- The MSP sound categories Char.Audio.volumes is keyed by, in the order the
-- widget and `ui music` both list them. `environment` is reserved - nothing
-- plays through it yet - but it is a real level the server stores.
mdwui.audioCategories = { "combat", "movement", "environment", "other" }

-- The five volume rows: the music level plus one per category. `music` is
-- the odd one out on the wire (music_volume, not volumes.music), which is
-- why the row id is not simply the wire key.
local VOLUME_ROWS = {
  { key = "music", label = "Music" },
  { key = "combat", label = "Combat" },
  { key = "movement", label = "Movement" },
  { key = "environment", label = "Environment" },
  { key = "other", label = "Other" },
}

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

--- This track's 1-based place in the playlist, or nil when it is not in it.
local function playlistPosition(id)
  for i, entry in ipairs(playlistIds()) do
    if entry == id then return i end
  end
  return nil
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

--- The level one row shows, from whichever field of Char.Audio holds it.
local function volumeLevel(key)
  local a = audio()
  if key == "music" then return tonumber(a.music_volume) or 0 end
  return tonumber(mdwui.tbl(a.volumes)[key]) or 0
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

---------------------------------------------------------------------------
-- THE WIDGET
---------------------------------------------------------------------------

--- Remember what a drag is pointing at, so the row's LABEL can follow the
-- pointer. MDW keeps the slider's value under the hand and never invents a
-- label, so the number beside the word is ours to write on every move; the
-- Char.Audio push that follows the release clears this and the truth paints.
local function setPreview(key, value)
  local preview = mdwui.state.musicPreview
  if not preview then
    preview = {}
    mdwui.state.musicPreview = preview
  end
  preview[key] = value
end

--- Repaint from Game.Music and Char.Audio. `rowsOnly` re-declares the row
-- block and leaves the console alone - that is the drag path, where the only
-- thing that changed is one slider's label and rebuilding the track list
-- would tear down and recreate its links on every mouse move.
function mdwui.renderMusic(rowsOnly)
  local widget = mdwui.w("Music")
  if not widget then return end
  -- Under an MDW predating the rows API the widget simply stays empty.
  if not (mdw and mdw.setWidgetRows) then return end
  local cfg = mdwui.config
  local C = cfg.colors
  local g = cfg.gauges
  local a = audio()
  local playing = mdwui.musicTrack(a.track)
  local preview = mdwui.state.musicPreview or {}
  -- A build without slider rows still shows the levels, as plain gauges
  -- (MDW's own advice for the capability, and the reason rowTypes exists).
  local slider = mdw.rowTypes and mdw.rowTypes.slider

  local rows = {}
  -- What is playing, with the mode on the right. Clicking it stops the music
  -- ({"track":""}), which is why the row is only clickable while something
  -- is playing - there is nothing to stop otherwise.
  rows[#rows + 1] = {
    id = "now", type = "text",
    text = string.format("<%s>%s", playing and C.charHeader or C.dim,
      playing and (playing.title or playing.id) or "Nothing playing"),
    rightText = (a.mode and a.mode ~= "")
      and string.format("<%s>%s", C.charLabel, mdwui.titleCase(a.mode)) or nil,
    onClick = playing and function() mdwui.audioSet({ track = "" }) end or nil,
  }

  for _, def in ipairs(VOLUME_ROWS) do
    local key = def.key
    local level = preview[key] or volumeLevel(key)
    -- The music level takes the AE pair and the categories the balance pair,
    -- so the one bar that carries the music reads apart from the four that
    -- carry the sound effects.
    local fill = (key == "music") and g.aeFill or g.balFill
    local track = (key == "music") and g.aeTrack or g.balTrack
    local row = {
      id = "vol_" .. key, type = slider and "slider" or "gauge",
      value = level, max = 100, step = 5,
      text = string.format("%s %d", def.label, level),
      front = mdwui.fillCss(fill), back = mdwui.trackCss(track),
      fgColor = g.textColor, fontSize = g.fontSize,
    }
    if slider then
      -- A preview NEVER writes: the server would answer every mouse move
      -- with a Char.Audio push and a re-sent track. The label follows the
      -- hand, the write waits for the release.
      row.onPreview = function(value)
        setPreview(key, value)
        mdwui.renderMusic(true)
      end
      row.onChange = function(value)
        setPreview(key, value)
        mdwui.setMusicVolume(key, value)
      end
    end
    rows[#rows + 1] = row
  end

  mdw.setWidgetRows("Music", rows)
  if rowsOnly then return end

  local co = widget.content
  co:clear()
  -- The server sends no MSP at all while this is off, whatever the rest of
  -- the payload says (guide 5.16), so say so before the list of things that
  -- will not play. `config sound on` is a real typed command, unlike every
  -- other affordance here.
  if a.sound == false then
    co:decho(string.format("<%s>Sound is off. Turn it on with ", C.dim))
    mdwui.link(co, string.format("<%s>config sound on", C.link), "config sound on",
      "Turn game sound back on")
    co:decho(string.format("<%s>.\n", C.dim))
  end

  local tracks = mdwui.tbl(catalog().tracks)
  if #tracks == 0 then
    co:decho(string.format("<%s>No music has arrived from the server yet.\n", C.faint))
    return
  end

  local known = audioKnown()
  -- Catalog order, which is the order `music list` shows and the order a
  -- playlist plays in (guide 5.16).
  for _, track in ipairs(tracks) do
    local id = track.id
    if type(id) == "string" and id ~= "" then
      local title = tostring(track.title or id)
      local position = playlistPosition(id)
      local isPlaying = playing ~= nil and playing.id == id
      co:decho(string.format("<%s>%s ", C.charLabel,
        position and string.format("%2d", position) or "  "))
      co:dechoLink(string.format("<%s>%s", isPlaying and C.charHeader or C.link, title),
        function() mdwui.audioSet({ track = id }) end, "Play " .. title, true)
      if isPlaying then
        co:decho(string.format(" <%s>(playing)", C.good))
      end
      -- No playlist edits until Char.Audio has been seen: the write replaces
      -- the list, so building one from what we have not been told wipes it.
      if known then
        co:decho(" ")
        co:dechoLink(string.format("<%s>%s", C.link, position and "[-]" or "[+]"),
          position and function() removeFromPlaylist(id) end
            or function() addToPlaylist(id) end,
          position and ("Remove " .. title .. " from the playlist")
            or ("Add " .. title .. " to the playlist"), true)
      end
      co:decho("\n")
    end
  end
end

--- Char.Audio is the answer to every write, so it is also where a drag's
-- label hands back to the server's own numbers.
function mdwui.onCharAudio()
  mdwui.state.musicPreview = nil
  mdwui.renderMusic()
end

---------------------------------------------------------------------------
-- WIDGET MENU (registered from mdwui.setupWidgetMenus, beside Combat's)
---------------------------------------------------------------------------

--- Re-evaluated on every render of the menu, so the checkboxes read the
-- latest Char.Audio rather than the state at the moment it opened.
function mdwui.musicMenuItems()
  local a = audio()
  local function flag(key, label)
    local on = a[key] and true or false
    return { label = label, checked = on, keepOpen = true,
      onClick = function() mdwui.audioSet({ [key] = not on }) end }
  end
  local function mode(value, label)
    return { label = label, checked = a.mode == value, keepOpen = true,
      onClick = function() mdwui.audioSet({ mode = value }) end }
  end
  return {
    flag("repeat", "Repeat"),
    flag("shuffle", "Shuffle"),
    { separator = true },
    mode("server", "Server picks the music"),
    mode("playlist", "Playlist"),
    { separator = true },
    { label = "Next", onClick = function() mdwui.audioSet({ next = true }) end },
    { label = "Stop", onClick = function() mdwui.audioSet({ track = "" }) end },
  }
end

---------------------------------------------------------------------------
-- TRACK-END RELAY (guide 5.16)
-- A playlist track is sent with L=1 so it plays once and the client says
-- when it ended; the server picks the next one on {"next":true}. Nothing
-- else advances a playlist, and no timer stands in for this - a track that
-- has run out is the only honest signal.
---------------------------------------------------------------------------

local function baseName(path)
  return tostring(path or ""):match("([^/\\]+)$") or ""
end

--- Mudlet raises sysMediaFinished for every media file it finishes, ours or
-- not: sound effects come through here too, and so does a looping track from
-- server mode (L=-1, which needs no relay). Hence the four conditions -
-- music, playlist mode, something playing, and the file that ended being
-- that track's.
function mdwui.onMediaFinished(_, fileName, _, mediaType)
  if mediaType ~= "music" then return end
  local a = audio()
  if a.mode ~= "playlist" then return end
  local track = mdwui.musicTrack(a.track)
  if not track then return end
  local wanted = baseName(track.file)
  if wanted == "" or baseName(fileName) ~= wanted then return end
  mdwui.audioSet({ next = true })
end
