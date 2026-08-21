-- Generate releases/releases.json from CHANGELOG.md. Usage, from the repo
-- root: lua5.1 tools/changelog_to_releases.lua > releases/releases.json
--
-- WHY this exists: the game server's deploy webhook copies
-- releases/releases.json out of this repo and serves it at
-- static/resources/ui/releases.json, which is the update feed every installed
-- client reads. CHANGELOG.md stays the ONE place a release note is written,
-- and this turns it into the feed - so the notes a player is shown and the
-- notes in the repo cannot drift apart. tools/release.sh runs it on every
-- release, which means a hand-edited releases.json is overwritten by the next
-- one. That is the point: edit the changelog, never the feed.
--
-- The heading pattern's digit class is what excludes "## Unreleased", and it
-- is load-bearing here exactly as it was in the package's own parser: work
-- that is in no release yet must never be offered as one.
--
-- The output shape is the game server's, shared with the mapper package:
--   [ { "version": "3.0.0", "released": "2026-08-21", "changes": [ "..." ] } ]

local function readAll(path)
  local fh = io.open(path, "r")
  if not fh then
    io.stderr:write("changelog_to_releases: cannot read " .. path .. "\n")
    os.exit(1)
  end
  local text = fh:read("*a")
  fh:close()
  return text
end

-- Markdown emphasis goes, for the same reason the package strips it at
-- display time: these lines are printed on a Mudlet console, never rendered.
-- Wrapped bullets are joined, so one changelog bullet is one feed line.
local function clean(s)
  s = s:gsub("%*%*", ""):gsub("`", "")
  s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

local function jsonString(s)
  s = tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"')
  s = s:gsub("[%c]", function(c) return string.format("\\u%04x", c:byte()) end)
  return '"' .. s .. '"'
end

local releases = {}
local current, pending = nil, nil

local function flush()
  if current and pending then
    local text = clean(pending)
    if text ~= "" then current.changes[#current.changes + 1] = text end
  end
  pending = nil
end

for raw in (readAll("CHANGELOG.md") .. "\n"):gmatch("([^\n]*)\n") do
  local ln = raw:gsub("\r$", "")
  -- Both spellings of the Keep a Changelog heading exist in the wild
  -- ("## 0.2.0 - date" and "## [0.2.0] - date"); neither can match a word.
  local version, date = ln:match("^##%s+%[?([%d%.]+)%]?%s*%-?%s*(%S*)")
  if version then
    flush()
    current = { version = version, released = (date ~= "" and date) or nil, changes = {} }
    releases[#releases + 1] = current
  elseif ln:match("^##%s") then
    -- Any other level-2 heading (## Unreleased) ends the release above it and
    -- starts none, so its notes are not swept into the release below.
    flush()
    current = nil
  elseif current then
    local bullet = ln:match("^%s*[%-%*]%s+(.+)$")
    if bullet then
      flush()
      pending = bullet
    elseif ln:match("^###%s") then
      -- "### Added" is structure the feed has no room for: the bullets under
      -- it carry their own verbs, the way the mapper's feed lines do.
      flush()
    elseif not ln:match("%S") then
      flush()
    elseif pending then
      pending = pending .. " " .. ln
    end
  end
end
flush()

local blocks = {}
for _, release in ipairs(releases) do
  local lines = {
    "    {",
    '        "version": ' .. jsonString(release.version) .. ",",
    '        "released": ' .. jsonString(release.released or "") .. ",",
  }
  if #release.changes == 0 then
    lines[#lines + 1] = '        "changes": []'
  else
    lines[#lines + 1] = '        "changes": ['
    for i, change in ipairs(release.changes) do
      lines[#lines + 1] = "            " .. jsonString(change)
        .. (i < #release.changes and "," or "")
    end
    lines[#lines + 1] = "        ]"
  end
  lines[#lines + 1] = "    }"
  blocks[#blocks + 1] = table.concat(lines, "\n")
end

if #blocks == 0 then
  io.stderr:write("changelog_to_releases: CHANGELOG.md has no released versions\n")
  os.exit(1)
end

io.write("[\n" .. table.concat(blocks, ",\n") .. "\n]\n")
