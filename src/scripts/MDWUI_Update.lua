--[[
  MDWUI_Update.lua
  The package's self-update: read our own CHANGELOG.md from GitHub, say when
  a newer release exists, and swap the package on the player's word. And, at
  the bottom, the same machinery pointed at MDW: the bootstrap that installs
  the framework this package cannot run without.

  The feed IS the changelog. There is no releases.json and no manifest: the
  file the repo already keeps (Keep a Changelog, newest release first) is the
  only thing fetched, and no URL ever travels in it. The download URL is
  CONVENTION - tag vX.Y.Z, asset named after the package - built from the
  constants in MDWUI_Config.lua, which tools/release.sh is bound by too.
  A feed that cannot name a URL cannot point an installer anywhere else.

  Nothing is periodic. The check runs once per session from mdwui.buildUI()
  and on demand from `ui update`; a timer polling GitHub all evening would
  buy nothing a login and a command do not.

  The install ORDER is the point of the whole module: download, verify, and
  only then uninstall. A player whose download was a GitHub error page must
  still have a working UI, so nothing is removed until the replacement is on
  disk and starts with a zip's "PK". The watchdog is the second half of that
  promise - if the reinstall never reports back, the saved file is handed
  over with a one-click install rather than left as a dead end.

  Output goes to the MAIN console with Mudlet's NAMED colours, the same
  reasoning as MDWUI_Commands.lua: an update offer has to survive whatever
  the player has hidden or closed, and this text is literal English rather
  than a transcription of the web client's CSS. Changelog text is REMOTE text, so every line of it goes
  through plain() before it is echoed - "<b>" in a bullet must print, not
  paint.

  Dependencies: MDWUI_Config.lua (the release constants and the MDW pin),
  MDWUI_Core.lua (versionAtLeast, mdwSatisfied, addTimer). Its event handlers
  are registered with the rest of the package's in MDWUI_Init.lua.
]]

-- A stalled download must not wedge the checker for the rest of the session,
-- so the in-flight guard is a TIMESTAMP: Mudlet raises neither sysDownloadDone
-- nor sysDownloadError in every failure mode, and a boolean would never clear.
local STALE_SECONDS = 60
-- Enough of a session's screen for two or three releases' notes; the rest is
-- one summary line pointing at the changelog.
local MAX_NOTE_LINES = 40
-- Smaller than any build this package has ever produced, so a 404 page or a
-- truncated transfer fails the check without a checksum to maintain.
local MIN_PACKAGE_BYTES = 20000
-- How the swap waits for Mudlet to let go of a package name. Fine-grained, so
-- a client that is ready pays nothing and a slow teardown costs only what it
-- actually needs - but the WINDOW has to be generous, because the teardown is
-- not ours to hurry: it destroys thirteen widgets, runs MDW's teardown hook
-- and can take a profile save with it.
-- The wait between uninstalling the old package and installing the new one.
-- One second, because that is what the mapper package and the old UI both do
-- and both have always worked:
--   uninstallPackage(name); tempTimer(1, function() installPackage(path) end)
--
-- It is not a tick and it is not a poll on getPackages(). A live client
-- reported "offered after no wait and Mudlet returned true, but it never
-- reported the package as installed" - the registry drops the name the moment
-- uninstallPackage returns, so waiting on it installs immediately into an
-- uninstall that has not finished, and Mudlet accepts the call and does
-- nothing. There is no signal to wait for here; there is a working sequence,
-- and this is it.
local INSTALL_WAIT_SECONDS = 1
-- Long enough for Mudlet to unpack a package and run its scripts, short enough
-- that a player is still watching the screen they clicked from - and always
-- comfortably past INSTALL_WAIT_SECONDS, so it can never announce a failure
-- over the top of an install that has not been attempted yet. A LAST resort:
-- it says what Mudlet reported rather than only that nothing arrived.
local WATCHDOG_SECONDS = 20

--- Named Mudlet colours only (verified against color_table in GUIUtils.lua -
-- a name missing there prints literally).
local P = {
  head = "cyan",        -- version headings
  label = "gold",       -- the Added/Changed/Fixed sub-headings
  text = "grey",        -- bullets and body text
  name = "white",       -- the installed version
  good = "green",       -- the version on offer
  dim = "dim_gray",     -- dates, URLs, asides
  link = "ForestGreen", -- the clickable install lines
}

--- Remote text quoted onto the console: drop "<" so a bullet reading "<b>"
-- prints instead of turning the rest of the line bold. Same rule (and same
-- reason) as MDWUI_Commands.lua's plain().
local function plain(text)
  return (tostring(text):gsub("<", ""))
end

local function line(text)
  if cecho then cecho(tostring(text) .. "\n") end
end

---------------------------------------------------------------------------
-- THE FEED (Keep a Changelog, newest release first)
---------------------------------------------------------------------------

--- Inline markdown a bullet can carry. Stripped rather than rendered: Mudlet
-- has no bold in a cecho stream worth the tag noise, and a raw "**" or a
-- backtick in the middle of a sentence reads as damage.
local function inline(text)
  return (tostring(text):gsub("%*%*", ""):gsub("`", ""))
end

--- Parse the server's releases.json into an ordered list of releases, newest
-- first: { version = "3.0.0", date = "2026-08-21", notes = { {kind, text} } }.
-- The shape is the game server's, copied verbatim out of releases/releases.json
-- on every push to main, and it is the one the mapper package already ships
-- against: [ { version, released, changes = { "line", ... } } ].
--
-- Every entry is defensive because this is REMOTE text: a feed that is not an
-- array, an entry with no version, a changes list that is not a list - each is
-- skipped rather than thrown, since the alternative is an error inside a
-- download handler and a player with no update path at all. The `notes` shape
-- is kept identical to what the old changelog parser produced so the
-- presentation layer below did not have to change: `kind` is always "bullet"
-- here, because a JSON feed has no sub-headings to label.
--
-- inline() strips markdown from every line for the same reason it always did -
-- these strings are prose we do not control.
function mdwui.parseReleases(text)
  if type(text) ~= "string" or text == "" then return {} end
  -- json_to_value is the decoder this package already reads book documents
  -- with (MDWUI_Journal), so the feed does not introduce a second one. Guarded
  -- the same way: no decoder means no update path, not an error.
  if not json_to_value then return {} end
  local ok, feed = pcall(json_to_value, text)
  if not ok or type(feed) ~= "table" then return {} end
  local releases = {}
  for _, entry in ipairs(feed) do
    if type(entry) == "table" and type(entry.version) == "string" and entry.version ~= "" then
      local release = {
        version = entry.version,
        date = type(entry.released) == "string" and entry.released or nil,
        notes = {},
      }
      if type(entry.changes) == "table" then
        for _, change in ipairs(entry.changes) do
          if type(change) == "string" or type(change) == "number" then
            release.notes[#release.notes + 1] = { kind = "bullet", text = inline(tostring(change)) }
          end
        end
      end
      releases[#releases + 1] = release
    end
  end
  return releases
end

--- The releases strictly newer than `installed`, in feed order. One
-- comparator asked twice (mdwui.versionAtLeast is the package's only version
-- compare): at least as new, and not also the other way round - which is
-- equality.
function mdwui.newerReleases(releases, installed)
  local out = {}
  for _, release in ipairs(releases or {}) do
    if mdwui.versionAtLeast(release.version, installed)
      and not mdwui.versionAtLeast(installed, release.version) then
      out[#out + 1] = release
    end
  end
  return out
end

---------------------------------------------------------------------------
-- PRESENTATION
---------------------------------------------------------------------------

--- Every newer release's notes as ready-to-echo lines, so the cap below can
-- count them before any of them is printed.
local function noteLines(newer)
  local out = {}
  for _, release in ipairs(newer) do
    out[#out + 1] = string.format("  <%s>%s%s", P.head, plain(release.version),
      release.date and string.format(" <%s>- %s", P.dim, plain(release.date)) or "")
    for _, note in ipairs(release.notes) do
      if note.kind == "head" then
        out[#out + 1] = string.format("    <%s>%s", P.label, plain(note.text))
      elseif note.kind == "bullet" then
        out[#out + 1] = string.format("      <%s>- %s", P.text, plain(note.text))
      else
        -- A changelog wraps its own bullets, so an unlabelled line is nearly
        -- always the rest of the one above it: same colour, indented under
        -- the bullet's text rather than under its dash.
        out[#out + 1] = string.format("        <%s>%s", P.text, plain(note.text))
      end
    end
  end
  return out
end

--- The whole offer: what is installed, what is on offer, why, and one click
-- that takes it. Every version newer than the installed one is shown, not
-- just the newest - a player two releases behind wants to know what both
-- of them changed.
local function announce(newer)
  local latest = newer[1]
  mdwui.say(string.format("%s <%s>%s <%s>-> <%s>%s%s", mdwui.packageName,
    P.name, mdwui.version, P.text, P.good, plain(latest.version),
    latest.date and string.format(" <%s>(%s)", P.dim, plain(latest.date)) or ""))
  local lines = noteLines(newer)
  for i = 1, math.min(#lines, MAX_NOTE_LINES) do
    line(lines[i])
  end
  if #lines > MAX_NOTE_LINES then
    -- No "see the changelog": the feed IS the notes now, and releases.json
    -- is not something a player can usefully be sent to read.
    line(string.format("  <%s>(%d more lines not shown)", P.dim, #lines - MAX_NOTE_LINES))
  end
  if cechoLink then
    -- A client action, not a game command: the outbound rule (widget
    -- affordances send real commands) has nothing to send here.
    cechoLink(string.format("<%s>[Install update now]", P.link),
      function() mdwui.installUpdate() end,
      string.format("Download and install %s %s", mdwui.packageName, latest.version), true)
    -- The link is a mouse affordance and this surface is a keyboard one, so
    -- the typed form goes out beside it: plenty of players would rather not
    -- reach for the mouse mid-session.
    line(string.format("   <%s>or type: ui update install", P.dim))
  else
    line(string.format("  <%s>Type ui update install to take it.", P.dim))
  end
end

---------------------------------------------------------------------------
-- CHECKING
---------------------------------------------------------------------------

local function homeDir()
  return (getMudletHomeDir and getMudletHomeDir()) or "."
end

local function busy()
  local since = mdwui.state.updateBusyAt
  return since ~= nil and (os.time() - since) < STALE_SECONDS
end

local function readFile(path, mode)
  local fh = io.open(path, mode or "r")
  if not fh then return nil end
  local text = fh:read("*a")
  fh:close()
  return text
end

--- Ask the game server for the release feed. `manual` is the `ui update` path:
-- it speaks
-- even when there is nothing to say. The session's own check stays silent
-- unless there is an update - a login is not a question the player asked.
function mdwui.checkForUpdate(manual)
  if busy() then
    if manual then mdwui.say("An update check is already running.") end
    return false
  end
  if not downloadFile then
    if manual then mdwui.say("This Mudlet cannot download files.") end
    return false
  end
  mdwui.state.updateBusyAt = os.time()
  mdwui.state.updateManual = manual and true or false
  mdwui.state.updateFeedPath = string.format("%s/%s-releases.json", homeDir(), mdwui.packageName)
  if manual then
    mdwui.say(string.format("Checking for a newer %s...", mdwui.packageName))
  end
  downloadFile(mdwui.state.updateFeedPath, mdwui.releasesUrl)
  return true
end

--- The session's one automatic check, called from buildUI. MDW rebuilds the
-- UI on every setup (profile load, MDW update, `ui rebuild`), and the flag
-- lives on mdwui.state, which survives a script re-run - so this is one check
-- per session rather than one per build.
function mdwui.checkForUpdateOnce()
  if mdwui.state.updateCheckedThisSession then return end
  mdwui.state.updateCheckedThisSession = true
  mdwui.checkForUpdate(false)
end

--- The release feed landed: compare, and either offer the update or say nothing.
local function readFeed(path)
  local manual = mdwui.state.updateManual
  mdwui.state.updateManual = false
  local text = readFile(path)
  os.remove(path) -- a cache of it would only ever be read as fresh
  if not text or text == "" then
    if manual then mdwui.say("Could not read the release list. Try again later.") end
    return
  end
  local newer = mdwui.newerReleases(mdwui.parseReleases(text), mdwui.version)
  if #newer == 0 then
    if manual then
      mdwui.say(string.format("You are on the latest version (%s).", mdwui.version))
    end
    return
  end
  mdwui.state.updateVersion = newer[1].version
  announce(newer)
end

---------------------------------------------------------------------------
-- INSTALLING
---------------------------------------------------------------------------

--- Fetch the package the server is hosting. The URL is FIXED, not built from
-- the version: the server keeps exactly one copy at one path, replaced by the
-- webhook on every push to main. The version the feed offered is still carried
-- through - it names the download and the message - but it does not select
-- what arrives, so a feed and a package can never disagree about the path.
function mdwui.installUpdate()
  local version = mdwui.state.updateVersion
  if not version then
    mdwui.say("No update is pending - run ui update first.")
    return
  end
  if busy() then
    mdwui.say("A download is already running.")
    return
  end
  if not downloadFile then
    mdwui.say("This Mudlet cannot download files.")
    return
  end
  mdwui.state.updateUrl = mdwui.packageUrl
  mdwui.state.updateFile = string.format("%s/%s-%s.mpackage", homeDir(), mdwui.packageName, version)
  mdwui.state.updateBusyAt = os.time()
  mdwui.say(string.format("Downloading %s %s...", mdwui.packageName, version))
  downloadFile(mdwui.state.updateFile, mdwui.state.updateUrl)
end

--- Is the downloaded file actually this package? It must open, be too big to
-- be an error page, and start with "PK" - an mpackage is a zip. GitHub
-- answers a tag that does not exist with a short HTML page, which is neither.
-- @return true, or false plus what was wrong with it
local function verified(path)
  local fh = io.open(path, "rb")
  if not fh then return false, "the download never landed on disk" end
  local head = fh:read(2)
  local size = fh:seek("end")
  fh:close()
  if (size or 0) <= MIN_PACKAGE_BYTES then
    return false, string.format("the download is only %d bytes", size or 0)
  end
  if head ~= "PK" then return false, "the download is not a Mudlet package" end
  return true
end

--- The last line of defence: if Mudlet never reported our package installed,
-- the swap failed somewhere we cannot see. The verified file is still on
-- disk, so hand it over with a click rather than leave a player with no UI.
function mdwui.updateWatchdog(path)
  if mdwui.state.updateInstalled then return end
  mdwui.sayBad("The update did not finish installing. The package is saved at:")
  line(string.format("  <%s>%s", P.text, plain(path)))
  -- WHY it did not, in the terms the swap actually works in. Two theories about
  -- this failure have already been wrong, so the next one reports rather than
  -- leaves it to be guessed at from a timestamp.
  local why
  if mdwui.state.installAttempted then
    why = string.format("Mudlet returned %s from the install and then never reported the package installed.",
      tostring(mdwui.state.installReturned))
  else
    why = "The install never ran - the timer that carries it did not fire."
  end
  line(string.format("  <%s>%s", P.dim, why))
  if cechoLink then
    -- Spelled out, not "[Install it now]": this line only ever appears when
    -- something went wrong, and the player reading it has just watched an
    -- update not happen. It should say what clicking will do.
    cechoLink(string.format("<%s>[Click here to manually install the update]", P.link),
      function() installPackage(path) end, "Install " .. plain(path), true)
    line("")
  end
end

--- The package file landed. Verify FIRST: nothing is uninstalled until the
-- replacement is proven, because the running UI is the only copy the player
-- has.
local function installDownloaded(path)
  local ok, why = verified(path)
  if not ok then
    mdwui.sayBad(string.format("Update failed - %s. Nothing was changed.", why))
    line(string.format("  <%s>%s", P.dim, plain(mdwui.state.updateUrl or "")))
    os.remove(path)
    mdwui.state.updateFile = nil
    return
  end
  local version = mdwui.state.updateVersion or "latest"

  -- Installed as a MODULE: Mudlet reloads a module from its own file, so the
  -- verified download has to BECOME that file. Copied only now - downloading
  -- straight onto the module path would have destroyed the working copy the
  -- moment the fetch turned out to be garbage.
  local modulePath = getModulePath and getModulePath(mdwui.packageName)
  if modulePath then
    local blob = readFile(path, "rb")
    local fh = blob and io.open(modulePath, "wb")
    if not fh then
      mdwui.sayBad(string.format("Update failed - could not write %s. Nothing was changed.",
        plain(modulePath)))
      line(string.format("  <%s>the download is saved at %s", P.dim, plain(path)))
      return
    end
    fh:write(blob)
    fh:close()
    os.remove(path)
    mdwui.state.updateFile = nil
    mdwui.say(string.format("Installing %s %s (module)...", mdwui.packageName, version))
    reloadModule(mdwui.packageName)
    return
  end

  mdwui.say(string.format("Installing %s %s - the UI rebuilds itself when it lands.",
    mdwui.packageName, version))
  mdwui.state.updateInstalled = false
  -- Our own sysUninstallPackage cleanup runs INSIDE this call: it kills our
  -- timers and deletes our handlers. Both timers below are therefore created
  -- after it, or killAllTimers would take the install with it.
  uninstallPackage(mdwui.packageName)
  -- tempTimer(1) is the ordinary Mudlet idiom for letting the client settle
  -- before the next command, and it is what both the mapper package and the
  -- old UI use for exactly this swap. The swap is closed by sysInstallPackage
  -- setting updateInstalled, which is what silences the watchdog below.
  local installId = tempTimer(INSTALL_WAIT_SECONDS, function()
    mdwui.state.installAttempted = true
    mdwui.state.installReturned = installPackage(path)
  end)
  if installId then mdwui.addTimer(installId) end
  local watchId = tempTimer(WATCHDOG_SECONDS, function() mdwui.updateWatchdog(path) end)
  if watchId then mdwui.addTimer(watchId) end
end

---------------------------------------------------------------------------
-- SERVER-DRIVEN LIFECYCLE (Client.GUI)
---------------------------------------------------------------------------

--- The game drives the package's lifecycle over Client.GUI. Two shapes share
-- that message and they must not be confused:
--
--   { version, url }      Mudlet's OWN native install path - it downloads and
--                         installs the package itself. We must not touch it.
--   { gomudui = "..." }   a command aimed at THIS package: "remove" or
--                         "update".
--
-- Hence the guard on the gomudui key first: this handler runs on every
-- Client.GUI, including the install one that arrives on login, and doing
-- anything there would fight Mudlet for its own installer.
--
-- The key is `gomudui`, not a Willowdale name - it is the wire name from the
-- server's Go struct, so it stays exactly as sent (the guide's rule: never
-- rename a GMCP field).
function mdwui.onClientGui()
  local gui = gmcp and gmcp.Client and gmcp.Client.GUI
  local command = type(gui) == "table" and gui.gomudui or nil
  if type(command) ~= "string" then return end

  if command == "remove" then
    mdwui.say("The game asked to remove the UI - uninstalling now.")
    -- Deferred a tick for the same reason the update swap defers its install:
    -- this handler belongs to the package being torn down, and uninstallPackage
    -- deletes the very handler we are standing in. Let the event finish first.
    local id = tempTimer(0, function()
      -- MDW's own full uninstall, not just ours. It removes every registered
      -- game package (we are in mdw.gamePackages), restores the main console
      -- font and background, deletes the saved layout, and then removes MDW.
      -- Removing only our own package would leave behind the framework THIS
      -- PACKAGE INSTALLED (ensureMdw), its layout file and the font it applied
      -- - "remove the UI" means the interface, not the half of it that happens
      -- to carry our name. The ordinary sysUninstallPackage path still leaves
      -- MDW running, because that one is not a request to remove the UI.
      if mdw and mdw.uninstall then
        mdw.uninstall()
      else
        uninstallPackage(mdwui.packageName)
      end
    end)
    if id then mdwui.addTimer(id) end
  elseif command == "update" then
    -- Manual, not the silent session check: the game asked on the player's
    -- behalf, so an answer is owed even when there is nothing to install.
    mdwui.checkForUpdate(true)
  end
end

---------------------------------------------------------------------------
-- BOOTSTRAPPING MDW
--
-- Mudlet resolves no dependencies: the mfile's "dependencies" field is read
-- by the package exporter and by nothing else. A player who installs this
-- package alone would therefore meet buildUI's version gate and one line of
-- explanation instead of a UI, so the package installs its own framework.
--
-- MDW never updates itself, by design - a framework swap is only safe when
-- the thing built on it says so - which makes the pin ours to hold and ours
-- to move: mdwui.minMdwVersion and mdwui.mdwUrl travel together.
---------------------------------------------------------------------------

--- Printed on every failure path: a player behind a proxy that eats GitHub
-- can still finish the job by hand.
local function sayManualMdw()
  line(string.format("  <%s>Install MDW by hand from: %s", P.dim, plain(mdwui.mdwUrl)))
end

--- Install MDW when it is missing or older than this package needs. NEVER
-- downgrades - a player on a newer MDW than our minimum is left alone - which
-- is what makes this safe to call from any trigger, as often as one fires.
function mdwui.ensureMdw()
  if mdwui.mdwSatisfied() then return false end
  -- One attempt per session: the triggers (profile load, our own install)
  -- fire more than once, and a repeat would only reprint a failure the player
  -- has already read.
  if mdwui.state.mdwFetchedThisSession then return false end
  -- The updater and the bootstrap share one downloader guard so neither can
  -- land on the other's file. The overlap is nearly impossible in practice -
  -- the update check starts from buildUI, which the version gate turns back
  -- long before that - but the two do write to the same profile directory.
  if busy() then return false end
  -- Set before the downloader check, not after it: a Mudlet with no
  -- downloadFile will not grow one mid-session, so that line is worth saying
  -- exactly as often as the fetch itself - once.
  mdwui.state.mdwFetchedThisSession = true
  -- MDW installed as a MODULE is not ours to swap. getPackages() does not
  -- list modules, so the check below would read "absent" and installPackage
  -- would leave a package named MDW beside the module - two copies of the
  -- mdw singleton fighting over one UI, which is the whole reason MDW and
  -- this package stay separate in the first place. A module is a deliberate
  -- choice, so it stays the player's to update.
  if getModulePath and getModulePath("MDW") then
    mdwui.say(string.format("%s needs MDW %s or newer, and MDW is installed here as a module.",
      mdwui.packageName, mdwui.minMdwVersion))
    sayManualMdw()
    return false
  end
  if not downloadFile then
    mdwui.say(string.format("%s needs MDW %s, and this Mudlet cannot download it.",
      mdwui.packageName, mdwui.minMdwVersion))
    sayManualMdw()
    return false
  end
  mdwui.state.mdwFile = homeDir() .. "/MDW.mpackage"
  mdwui.state.updateBusyAt = os.time()
  mdwui.say(string.format("%s needs the MDW framework (%s or newer) - fetching it now...",
    mdwui.packageName, mdwui.minMdwVersion))
  downloadFile(mdwui.state.mdwFile, mdwui.mdwUrl)
  return true
end

--- The MDW package landed. Verified FIRST, like the self-update above and for
-- a sharper reason: uninstalling MDW takes the whole UI down with it, so a
-- GitHub error page must never cost a player the MDW they are already
-- running.
local function installMdw(path)
  local ok, why = verified(path)
  if not ok then
    mdwui.sayBad(string.format("MDW download failed - %s. Nothing was changed.", why))
    sayManualMdw()
    os.remove(path)
    mdwui.state.mdwFile = nil
    return
  end
  mdwui.say("Installing MDW - the UI builds itself when it lands.")
  -- Absent is the ordinary case (this package installed on its own); present
  -- means it is merely too old, and Mudlet refuses to install over a package
  -- name it already holds. getPackages is Mudlet 4.12+.
  if getPackages and table.contains(getPackages(), "MDW") then
    -- MDW's uninstall saves the layout and tears its UI down, which runs our
    -- own mdw.onTeardown hook - and that calls killAllTimers. Every timer
    -- below is created AFTER this call, or the install would be killed on its
    -- way out; same rule, same reason, as the package swap above.
    uninstallPackage("MDW")
  end
  -- Same race as the package swap, one step more lethal: uninstalling MDW took
  -- the whole UI down, so an install refused for a name Mudlet has not released
  -- yet leaves the player with nothing. onInstallPackage clears mdwFile when
  -- MDW reports in, which is this retry's stop signal.
  local installId = tempTimer(INSTALL_WAIT_SECONDS, function() installPackage(path) end)
  if installId then mdwui.addTimer(installId) end
  -- Nothing to activate afterwards: MDW's install runs setup -> onReady ->
  -- buildUI, and this package only ever seeded mdw.onReady, so the UI builds
  -- itself. The downloaded file is dropped when MDW reports in on
  -- sysInstallPackage.
end

---------------------------------------------------------------------------
-- EVENTS (registered with the rest of the package's in MDWUI_Init.lua)
---------------------------------------------------------------------------

--- sysDownloadDone(event, savedPath). Every download in the profile raises
-- it - the mapper's, MDW's - so all three branches are keyed on the exact
-- path we asked for.
function mdwui.onDownloadDone(_, savedPath)
  local path = tostring(savedPath or "")
  if path == mdwui.state.updateFeedPath then
    mdwui.state.updateBusyAt = nil
    readFeed(path)
  elseif path == mdwui.state.updateFile then
    mdwui.state.updateBusyAt = nil
    installDownloaded(path)
  elseif path == mdwui.state.mdwFile then
    mdwui.state.updateBusyAt = nil
    installMdw(path)
  end
end

--- sysDownloadError(event, errorMessage, savedPath). The URL goes out with
-- the failure: a player behind a proxy can still fetch the file by hand.
function mdwui.onDownloadError(_, errorMessage, savedPath)
  local path = tostring(savedPath or "")
  if path == mdwui.state.mdwFile then
    -- The in-flight state goes, the once-per-session flag stays: this player
    -- has no network for GitHub, and saying so again at the next profile load
    -- would not change that.
    mdwui.state.updateBusyAt = nil
    mdwui.state.mdwFile = nil
    mdwui.sayBad(string.format("MDW download failed: %s",
      plain(errorMessage or "unknown error")))
    sayManualMdw()
    return
  end
  local isFeed = (path == mdwui.state.updateFeedPath)
  if not (isFeed or path == mdwui.state.updateFile) then return end
  mdwui.state.updateBusyAt = nil
  mdwui.state.updateManual = false
  mdwui.say(string.format("%s download failed: %s",
    isFeed and "Changelog" or "Update", plain(errorMessage or "unknown error")))
  line(string.format("  <%s>%s", P.dim,
    plain(isFeed and mdwui.releasesUrl or (mdwui.state.updateUrl or ""))))
end

--- sysInstallPackage(event, packageName) - the far side of the swap. Mudlet
-- runs a package's scripts as it installs it, so this handler belongs to the
-- NEW copy of the package; mdwui.state survives in the Lua state, which is
-- how the watchdog created by the old one learns it can stay quiet.
function mdwui.onInstallPackage(_, package)
  -- The bootstrap's far side. MDW has already run setup -> onReady ->
  -- buildUI by the time this arrives, so there is nothing to do but release
  -- the guard and drop the file.
  if package == "MDW" then
    mdwui.state.updateBusyAt = nil
    if mdwui.state.mdwFile then
      os.remove(mdwui.state.mdwFile)
      mdwui.state.mdwFile = nil
    end
    return
  end
  if package ~= mdwui.packageName then return end
  mdwui.state.updateInstalled = true
  mdwui.state.updateBusyAt = nil
  -- The offer is spent: an install line still on the screen from before the
  -- swap would otherwise re-download the version now running.
  mdwui.state.updateVersion = nil
  if mdwui.state.updateFile then
    os.remove(mdwui.state.updateFile)
    mdwui.state.updateFile = nil
  end
  -- This package can be installed into a profile that has no MDW at all, and
  -- this event is the first moment it can find out. Deferred by a tick, since
  -- Mudlet's installer must not be re-entered from inside its own event.
  local bootstrapId = tempTimer(0, function() mdwui.ensureMdw() end)
  if bootstrapId then mdwui.addTimer(bootstrapId) end
end
