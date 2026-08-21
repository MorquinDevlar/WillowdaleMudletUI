--[[
  MDWUI_Journal.lua
  The Journal widget: the in-game `journal` command in full - books,
  documents, quests, rumors, observations, and the player's own notes.

  It mirrors the telnet flow, front page -> category -> one entry, and follows
  the web client in holding BOTH journals: five categories are the player
  journal proper (guide 5.15, Char.Journal.*), and the sixth - Quests - shows
  the quest journal built from Char.Quests (guide 5.9/5.10), exactly as
  `journal quests` delegates to the quest views in telnet. The Quests WIDGET
  stays separate and lean: tracked quests and what is turn-in-able here.

  The player-journal half comes in three tiers, because a long-lived character
  holds thousands of entries and a book runs to kilobytes:
    Char.Journal        pushed, category counts only
    Char.Journal.List   pulled, one page of headers (page size 30)
    Char.Journal.Entry  pulled, one entry with its content
  Nothing but the counts is ever pushed, so the widget pulls what it shows.
  The Quests category is the exception - it never pulls a list, because
  Char.Journal.List does not serve that category at all (guide 5.15).

  Dependencies: MDWUI_Config.lua, MDWUI_Core.lua, MDWUI_Quests.lua (for the
  Quests category's body renderer).
]]

---------------------------------------------------------------------------
-- STATE AND REQUESTS
---------------------------------------------------------------------------

--- Seed the tables this widget keeps in mdwui.state. State is PRESERVED
-- across script re-runs (MDWUI_Config), so a live session can hold a state
-- table predating any of these fields.
local function seedState()
  local s = mdwui.state
  s.pjExpanded = s.pjExpanded or {}   -- entry id -> true while its content shows
  s.pjEntries = s.pjEntries or {}     -- entry id -> Char.Journal.Entry payload
  s.pjPending = s.pjPending or {}     -- entry id -> true while a request is in flight
  s.pjBookPage = s.pjBookPage or {}   -- entry id -> which book page is showing
  s.pjPage = s.pjPage or 1            -- current list page (1-based)
  -- pjCategory (runtime): the open category slug; nil is the front page.
end

--- Pull one page of headers. Category slugs come from the server's own
-- payload, so they need no JSON escaping. The quests category is skipped:
-- Char.Journal.List does not serve it and answers with silence (guide 5.15),
-- so a request would leave the view waiting for a reply that never comes.
local function requestList(category, page)
  if not category or category == "quests" then return end
  mdwui.request("Char.Journal.List",
    string.format('{"category":"%s","page":%d}', tostring(category), tonumber(page) or 1))
end

--- Pull one entry's content, unless a request for it is already in flight.
-- The guard makes the render path safe to re-enter: every repaint (resize
-- reflows included) walks the expanded rows.
local function requestEntry(id)
  local key = tostring(id)
  if mdwui.state.pjPending[key] then return end
  mdwui.state.pjPending[key] = true
  mdwui.request("Char.Journal.Entry", string.format('{"id":%d}', tonumber(id) or 0))
end

--- The Char.Journal.List payload, but ONLY when it answers what we are
-- showing. A stale page from the previous category sits in the gmcp table
-- until the new one lands, and the payload echoes back the category and page
-- precisely so a client can tell the two apart.
local function currentListPayload()
  local list = mdwui.tbl(gmcp and gmcp.Char and gmcp.Char.Journal and gmcp.Char.Journal.List)
  if list.category ~= mdwui.state.pjCategory then return nil end
  if (tonumber(list.page) or 0) ~= mdwui.state.pjPage then return nil end
  return list
end

--- Prose carries `\n` as two literal characters (guide 5.15) - the telnet
-- renderer swaps them for real breaks and so must we.
local function unescapeBreaks(text)
  return (tostring(text or ""):gsub("\\n", "\n"))
end

--- Decode a book's JSON document. Guarded on every axis: json_to_value is a
-- Mudlet global the test harness also provides, but an older Mudlet or a
-- malformed document must degrade to showing the raw text, never error.
local function decodeBook(content)
  if type(content) ~= "string" or content == "" then return nil end
  if not json_to_value then return nil end
  local ok, value = pcall(json_to_value, content)
  if ok and type(value) == "table" then return value end
  return nil
end

---------------------------------------------------------------------------
-- FRONT PAGE (Tier 1: the six category counts)
---------------------------------------------------------------------------

local function openCategory(slug)
  mdwui.state.pjCategory = slug
  mdwui.state.pjPage = 1
  if slug == "quests" then
    -- Quest threads come from Char.Quests. The build-time full payload
    -- normally has it already; pull it if this is somehow the first ask.
    if not (gmcp and gmcp.Char and gmcp.Char.Quests) then
      mdwui.request("Char.Quests")
    end
  else
    requestList(slug, 1)
  end
  mdwui.renderJournal()
end

local function renderFrontPage(co, C, W)
  local journal = mdwui.tbl(gmcp and gmcp.Char and gmcp.Char.Journal)
  local categories = mdwui.tbl(journal.categories)
  if #categories == 0 then
    co:decho(string.format("<%s><i>No journal entries yet</i>\n", C.faint))
    return
  end

  for _, category in ipairs(categories) do
    local title = category.title or category.slug or "?"
    local count = tostring(tonumber(category.count) or 0)
    local name, nameW = mdwui.clipText(title, math.max(4, W - #count - 1))
    local slug = category.slug
    -- Every row opens a view inside this widget. Quests is the one whose data
    -- comes from Char.Quests rather than Char.Journal.List, so it opens the
    -- quest journal - the same delegation `journal quests` does in telnet.
    co:dechoLink(string.format("<%s>%s", C.charHeader, name),
      function() openCategory(slug) end,
      (category.description and category.description ~= "")
        and category.description or title, true)
    co:decho(string.format("%s<%s>%s\n",
      string.rep(" ", math.max(1, W - nameW - #count)), C.charGold, count))
  end

  mdwui.divider(co, W)
  local total = tostring(tonumber(journal.total) or 0)
  co:decho(string.format("<%s>Total%s<%s>%s\n", C.charLabel,
    string.rep(" ", math.max(1, W - 5 - #total)), C.charGold, total))
end

---------------------------------------------------------------------------
-- ONE ENTRY'S EXPANDED CONTENT (Tier 3)
---------------------------------------------------------------------------

--- The book pager: books arrive whole (guide 5.15) and are paginated here,
-- so opening a twenty-page volume does not flood the widget.
local function renderBookPages(co, C, W, id, book, pad)
  local pages = mdwui.tbl(book.pages)
  if #pages == 0 then return false end
  local page = math.max(1, math.min(tonumber(mdwui.state.pjBookPage[tostring(id)]) or 1, #pages))
  if book.title and book.title ~= "" then
    mdwui.wrapEcho(co, W, C.charHeader, book.title, pad)
  end
  co:decho(string.format("%s<%s><i>page %d of %d</i>\n", pad, C.charLabel, page, #pages))
  for line in (unescapeBreaks(pages[page]) .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" then
      co:decho("\n")
    else
      mdwui.wrapEcho(co, W, C.qjDesc, line, pad)
    end
  end
  if #pages > 1 then
    local key = tostring(id)
    if page > 1 then
      co:decho(pad)
      co:dechoLink(string.format("<%s>[< prev page]", C.link), function()
        mdwui.state.pjBookPage[key] = page - 1
        mdwui.renderJournal()
      end, "previous page", true)
      co:decho(" ")
    else
      co:decho(pad)
    end
    if page < #pages then
      co:dechoLink(string.format("<%s>[next page >]", C.link), function()
        mdwui.state.pjBookPage[key] = page + 1
        mdwui.renderJournal()
      end, "next page", true)
    end
    co:decho("\n")
  end
  return true
end

local function renderEntryBody(co, C, W, id, pad)
  local entry = mdwui.state.pjEntries[tostring(id)]
  if not entry then
    requestEntry(id)
    co:decho(string.format("%s<%s><i>Loading...</i>\n", pad, C.charLabel))
    return
  end

  -- An entry whose source left the world still answers, with available:false
  -- and empty title/content - the stub text is ours to write (guide 5.15).
  if entry.available == false then
    co:decho(string.format("%s<%s><i>[no longer in the world]</i>\n", pad, C.faint))
    return
  end

  if entry.summary and entry.summary ~= "" then
    mdwui.wrapEcho(co, W, C.qjKv, entry.summary, pad, "i")
  end
  if entry.source and entry.source ~= "" then
    mdwui.wrapEcho(co, W, C.faint, "Heard from " .. entry.source, pad, "i")
  end
  if entry.room_title and entry.room_title ~= "" then
    local where = entry.room_title
    if entry.zone and entry.zone ~= "" then
      where = string.format("%s (%s)", where, entry.zone)
    end
    mdwui.wrapEcho(co, W, C.faint, "Found in " .. where, pad, "i")
  end

  local content = entry.content
  if type(content) ~= "string" or content == "" then
    co:decho(string.format("%s<%s><i>(no text)</i>\n", pad, C.faint))
    return
  end
  if entry.is_book then
    local book = decodeBook(content)
    -- A book that will not decode falls through to the prose path rather
    -- than showing nothing.
    if book and renderBookPages(co, C, W, id, book, pad) then return end
  end
  for line in (unescapeBreaks(content) .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" then
      co:decho("\n")
    else
      mdwui.wrapEcho(co, W, C.qjDesc, line, pad)
    end
  end
end

---------------------------------------------------------------------------
-- CATEGORY LIST (Tier 2)
---------------------------------------------------------------------------

local function categoryTitle(slug)
  for _, category in ipairs(mdwui.tbl(mdwui.tbl(gmcp and gmcp.Char and gmcp.Char.Journal).categories)) do
    if category.slug == slug then return category.title or slug end
  end
  return slug
end

--- The crumb row every drill-down view opens with: back to the categories,
-- then this category's title.
local function renderCrumbs(co, C, W, slug)
  co:dechoLink(string.format("<%s>[back]", C.link), function()
    mdwui.state.pjCategory = nil
    mdwui.renderJournal()
  end, "back to the journal categories", true)
  co:decho(string.format(" <%s>%s\n", C.charHeader, categoryTitle(slug)))
  mdwui.divider(co, W)
end

function mdwui.renderJournal()
  local widget = mdwui.w("Journal")
  if not widget then return end
  seedState()
  local C = mdwui.config.colors
  local co = widget.content
  local W = mdwui.wrapWidth(widget, 24)
  co:clear()

  local slug = mdwui.state.pjCategory
  if not slug then
    renderFrontPage(co, C, W)
    return
  end

  renderCrumbs(co, C, W, slug)

  -- The Quests category is the quest journal (Char.Quests), not a page of
  -- Char.Journal.List headers - see the file header.
  if slug == "quests" then
    if not (gmcp and gmcp.Char and gmcp.Char.Quests) then
      co:decho(string.format("<%s><i>Loading...</i>\n", C.charLabel))
      return
    end
    mdwui.renderQuestJournalInto(co, C, W)
    return
  end

  local list = currentListPayload()
  if not list then
    co:decho(string.format("<%s><i>Loading...</i>\n", C.charLabel))
    return
  end

  local entries = mdwui.tbl(list.entries)
  if #entries == 0 then
    -- An out-of-range page answers with the real total and no entries
    -- (guide 5.15) - say so rather than showing a blank panel.
    local total = tonumber(list.total) or 0
    co:decho(string.format("<%s><i>%s</i>\n", C.faint,
      total > 0 and "Nothing on this page" or "Nothing recorded here"))
  end

  for _, entry in ipairs(entries) do
    local id = entry.id
    local key = tostring(id)
    local open = mdwui.state.pjExpanded[key] and true or false
    co:dechoLink(string.format("<%s>%s", C.charLabel, open and "▼" or "▶"),
      function()
        mdwui.state.pjExpanded[key] = (not open) or nil
        mdwui.renderJournal()
      end, (open and "Collapse " or "Expand ") .. (entry.title or "this entry"), true)
    co:decho(" ")

    local idText = string.format("[%s]", tostring(entry.index or "?"))
    co:decho(string.format("<%s>%s ", C.charLabel, idText))
    -- The title sends the REAL command the player could type, which opens the
    -- entry in the main window too (guide 5.15's outbound rule). `index` is
    -- what that command takes - never `id`, which is only for caching.
    local title = (entry.available == false) and "[no longer in the world]"
      or ((entry.title ~= nil and entry.title ~= "") and entry.title or "(untitled)")
    local name = mdwui.clipText(title, math.max(4, W - 2 - #idText - 1))
    mdwui.link(co, string.format("<%s>%s",
      (entry.available == false) and C.faint or C.charHeader, name),
      string.format("journal %s %s", slug, tostring(entry.index or 0)),
      string.format("%s\nShow in the main window", title))
    co:decho("\n")

    if open then renderEntryBody(co, C, W, id, "  ") end
  end

  -- Pager: total is the post-search count, so the page count comes from it.
  local pageSize = math.max(1, tonumber(list.page_size) or 30)
  local total = tonumber(list.total) or 0
  local pages = math.max(1, math.ceil(total / pageSize))
  if pages > 1 then
    mdwui.divider(co, W)
    local page = mdwui.state.pjPage
    if page > 1 then
      co:dechoLink(string.format("<%s>[< prev]", C.link), function()
        mdwui.state.pjPage = page - 1
        requestList(slug, page - 1)
        mdwui.renderJournal()
      end, "previous page", true)
      co:decho(" ")
    end
    co:decho(string.format("<%s>page %d of %d ", C.charLabel, page, pages))
    if page < pages then
      co:dechoLink(string.format("<%s>[next >]", C.link), function()
        mdwui.state.pjPage = page + 1
        requestList(slug, page + 1)
        mdwui.renderJournal()
      end, "next page", true)
    end
    co:decho("\n")
  end
end

---------------------------------------------------------------------------
-- GMCP HANDLERS
---------------------------------------------------------------------------

--- Char.Journal (counts). Mudlet raises an event for EVERY path segment of a
-- GMCP key (TLuaInterpreter: "for key foo.bar.top we raise gmcp.foo,
-- gmcp.foo.bar and gmcp.foo.bar.top"), passing the real key as the argument.
-- So a Char.Journal.List arrival also fires this handler - and without the
-- guard below, re-requesting the list here would answer itself forever.
function mdwui.onJournalCounts(_, key)
  if key ~= nil and key ~= "gmcp.Char.Journal" then return end
  seedState()
  -- "Your counts changed, re-request the category you are showing" (guide
  -- 5.15). Entry content can have been rewritten too, so the cache goes with
  -- it; expanded rows re-request from the render below. Clearing pending
  -- alongside it is what unsticks a row whose entry was removed outright -
  -- that request is answered with silence, and a removal always moves a count.
  mdwui.state.pjEntries = {}
  mdwui.state.pjPending = {}
  -- requestList itself declines the Quests category: its rows come from
  -- Char.Quests, which arrives on its own push.
  requestList(mdwui.state.pjCategory, mdwui.state.pjPage)
  mdwui.renderJournal()
end

function mdwui.onJournalList()
  seedState()
  mdwui.renderJournal()
end

function mdwui.onJournalEntry()
  seedState()
  local entry = mdwui.tbl(gmcp and gmcp.Char and gmcp.Char.Journal
    and gmcp.Char.Journal.Entry)
  if entry.id then
    mdwui.state.pjEntries[tostring(entry.id)] = entry
    mdwui.state.pjPending[tostring(entry.id)] = nil
  end
  mdwui.renderJournal()
end

---------------------------------------------------------------------------
-- KEYBOARD ENTRY POINTS (`ui journal`, MDWUI_Commands.lua)
-- Thin wrappers over the locals the links above use, so the request format
-- and the state keys stay defined exactly once.
---------------------------------------------------------------------------

mdwui.journalOpen = openCategory

function mdwui.journalBack()
  seedState()
  mdwui.state.pjCategory = nil
  mdwui.renderJournal()
end

--- Turn to a list page (1-based; the renderer clamps the display, this
-- clamps the request). Returns the page it settled on.
function mdwui.journalPage(page)
  seedState()
  page = math.max(1, tonumber(page) or 1)
  mdwui.state.pjPage = page
  requestList(mdwui.state.pjCategory, page)
  mdwui.renderJournal()
  return page
end

--- The entry carrying `[index]` on the page currently shown, or nil. Index is
-- what the player sees and what the journal command takes; `id` is internal.
function mdwui.journalEntryByIndex(index)
  seedState()
  index = tonumber(index)
  local list = index and currentListPayload() or nil
  if not list then return nil end
  for _, entry in ipairs(mdwui.tbl(list.entries)) do
    if tonumber(entry.index) == index then return entry end
  end
  return nil
end

function mdwui.setJournalEntryExpanded(id, open)
  seedState()
  mdwui.state.pjExpanded[tostring(id)] = open and true or nil
  mdwui.renderJournal()
end

function mdwui.setJournalBookPage(id, page)
  seedState()
  mdwui.state.pjBookPage[tostring(id)] = math.max(1, tonumber(page) or 1)
  mdwui.renderJournal()
end

--- A character switch invalidates everything here: entry ids, indexes and
-- counts all belong to the previous character.
function mdwui.resetJournal()
  seedState()
  mdwui.state.pjEntries = {}
  mdwui.state.pjPending = {}
  mdwui.state.pjExpanded = {}
  mdwui.state.pjBookPage = {}
  mdwui.state.pjCategory = nil
  mdwui.state.pjPage = 1
end
