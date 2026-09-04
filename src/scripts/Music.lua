--[[
  Music.lua
  The Music widget: the master volume, and the catalog the player plays from
  and builds a playlist with (guide section 5.16).

  The LAYOUT is the web client's "Sound & Music" panel: a bare volume slider,
  the "Music" header, the hint, the catalog with a playlist checkbox per row,
  and Repeat/Shuffle under it. Only the layout - the colours are this
  package's own, so MDW themes keep reaching this widget like every other.

  Two things the web panel has are deliberately absent. Its Mute checkbox
  silences the browser's own players without touching the stored level, and
  Mudlet has no primitive that does that, so a box that only pretended to
  would be worse than none. Its four sound-effect sliders are display:none
  there because nothing plays through those categories yet; here they are
  `ui music volume <name>` instead. Next, stop and the mode are `ui music`
  verbs for the same reason - the panel does not show them either.

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

---------------------------------------------------------------------------
-- THE WIDGET
---------------------------------------------------------------------------

--- A checkbox drawn in text, the whole thing one clickable cell. The web
-- panel's LAYOUT is what this widget copies; the colours stay the package's
-- own (C.link, like every other affordance here), so an MDW theme reaches
-- this widget the way it reaches the rest of the UI.
local function checkbox(on)
  return string.format("<%s>[%s]", mdwui.config.colors.link, on and "x" or " ")
end

--- Repaint from Game.Music and Char.Audio.
function mdwui.renderMusic()
  local widget = mdwui.w("Music")
  if not widget then return end
  -- Under an MDW predating the rows API the widget simply stays empty.
  if not (mdw and mdw.setWidgetRows) then return end
  local cfg = mdwui.config
  local C = cfg.colors
  local g = cfg.gauges
  local a = audio()
  local playing = mdwui.musicTrack(a.track)
  -- A build without slider rows still shows the level, as a plain gauge
  -- (MDW's own advice for the capability, and the reason rowTypes exists).
  local slider = mdw.rowTypes and mdw.rowTypes.slider

  -- The master volume, unlabelled and unnumbered like the web panel's: it is
  -- the only slider here, so there is nothing for a word to tell apart. No
  -- onPreview either - with no label to relabel, a drag has nothing to say
  -- until it commits. The four sound-effect levels are `ui music volume`
  -- only: nothing in this game plays through them yet, and the web panel
  -- hides its own category sliders for the same reason.
  local volume = {
    id = "vol_music", type = slider and "slider" or "gauge",
    value = tonumber(a.music_volume) or 0, max = 100, step = 5, text = "",
    front = mdwui.fillCss(g.aeFill), back = mdwui.trackCss(g.aeTrack),
    fgColor = g.textColor, fontSize = g.fontSize,
  }
  if slider then
    volume.onChange = function(value) mdwui.setMusicVolume("music", value) end
  end
  local rows = {
    volume,
    -- Same header style as the Combat widget's sections (Combat.lua's
    -- `header`), so the two panels read as one UI.
    { id = "hdr", type = "text", height = g.headerHeight, fontSize = g.headerFontSize,
      text = string.format("<%s>Music", C.charLabel) },
    { id = "hint", type = "text", fontSize = g.headerFontSize,
      text = string.format("<%s>Click title to play. Check box to add to playlist.",
        C.dim) },
  }
  mdw.setWidgetRows("Music", rows)

  local co = widget.content
  co:clear()
  -- The server sends no MSP at all while this is off, whatever the rest of
  -- the payload says (guide 5.16), so say so before the list of things that
  -- will not play. Kept although the web panel has no such line: there a
  -- silent click is at least a click on a player that exists. `config sound
  -- on` is a real typed command, unlike every other affordance here.
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
      local member = inPlaylist(id)
      -- The package's own playing marker: C.good is what every other
      -- renderer here says "this one is live" with.
      local titleColor = (playing ~= nil and playing.id == id) and C.good or C.link
      local box = checkbox(member)
      -- No playlist edits until Char.Audio has been seen: the write replaces
      -- the list, so building one from what we have not been told wipes it.
      -- The box still DRAWS - the web renders it unclickable too.
      if known then
        co:dechoLink(box,
          member and function() removeFromPlaylist(id) end
            or function() addToPlaylist(id) end,
          member and ("Remove " .. title .. " from the playlist")
            or ("Add " .. title .. " to the playlist"), true)
      else
        co:decho(box)
      end
      co:decho(" ")
      co:dechoLink(string.format("<%s>%s", titleColor, title),
        function() mdwui.audioSet({ track = id }) end, "Play " .. title, true)
      co:decho("\n")
    end
  end

  co:decho("\n")
  -- Repeat and Shuffle, the web's two boxes under the list. Same gate as the
  -- track boxes: before the first push there is no current value to flip.
  local first = true
  for _, def in ipairs({ { "repeat", "Repeat" }, { "shuffle", "Shuffle" } }) do
    local key, label = def[1], def[2]
    local on = a[key] and true or false
    if not first then co:decho("   ") end
    first = false
    local text = checkbox(on) .. " " .. label
    if known then
      co:dechoLink(text, function() mdwui.audioSet({ [key] = not on }) end,
        string.format("Turn %s %s", label:lower(), on and "off" or "on"), true)
    else
      co:decho(text)
    end
  end
  co:decho("\n")
end

--- Char.Audio is the answer to every write, so every control here waits for
-- it rather than painting itself: a box ticks because the server said so.
function mdwui.onCharAudio()
  mdwui.renderMusic()
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
