-- One alias for the whole keyboard surface; the dispatcher lives in
-- MDWUI_Commands.lua so it is testable headlessly and reloads with the
-- scripts (an alias body only reloads with the package).
if mdwui and mdwui.command then
  mdwui.command(matches[2] or "")
else
  echo("[ui] The Willowdale UI scripts are not loaded.\n")
end
