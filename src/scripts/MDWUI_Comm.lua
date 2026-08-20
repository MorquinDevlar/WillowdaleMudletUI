--[[
  MDWUI_Comm.lua
  The Communications widget: an MDW TabbedWidget with the web client's channel
  tabs (All / Room / Global / Tells / Group), fed by Comm.Channel pushes and
  the one-shot Comm.History batch.

  Unlike the panel renderers, chat is a STREAM: messages append through MDW's
  echo pipeline, so its buffer handles reflow-on-resize and the "All" tab
  mirror comes free from allTab.

  Dependencies: MDWUI_Config.lua, MDWUI_Core.lua.
]]

--- Append one Comm.Channel-shaped message to its tab. Routing mirrors the
-- web client's channelToTab map; unknown channels land in Global rather than
-- vanishing. The `ansi` rendering is the Mudlet-intended one (guide 8.1) -
-- color aliases are already resolved server-side, so no palette map here.
function mdwui.appendCommMessage(msg)
  local widget = mdw and mdw.widgets and mdw.widgets["Comm"]
  if not widget or not widget.dechoTo then return end
  if not msg then return end
  -- Skip content-free packets (guide 8.22's residual advice).
  if (not msg.text or msg.text == "") and (not msg.channel or msg.channel == "") then return end

  local C = mdwui.config.colors
  local tab = mdwui.config.channelToTab[msg.channel] or "Global"
  local when = msg.timestamp and tostring(msg.timestamp):match("(%d+:%d+)") or os.date("%H:%M")
  local body = mdwui.ansiToDecho(msg.ansi or msg.text or "")
  widget:dechoTo(tab, string.format("<%s>[%s]<r> %s\n", C.dim, when, body))
end

function mdwui.onCommChannel()
  mdwui.appendCommMessage(gmcp and gmcp.Comm and gmcp.Comm.Channel)
end

--- Comm.History is a one-shot batch of up to ~60 past messages (guide 8.23),
-- requested once at build. Clear first: history can be re-sent by a full
-- payload refresh, and appending it twice would duplicate the backlog.
function mdwui.onCommHistory()
  local widget = mdw and mdw.widgets and mdw.widgets["Comm"]
  if not widget or not widget.clearAll then return end
  local history = mdwui.tbl(gmcp and gmcp.Comm and gmcp.Comm.History)
  widget:clearAll()
  for _, msg in ipairs(history) do
    mdwui.appendCommMessage(msg)
  end
end
