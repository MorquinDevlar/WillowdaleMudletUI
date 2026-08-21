# Changelog

Only what a player notices: widgets, commands, keys, and the things that go
wrong for them. Development tooling, tests, and Claude Code commands are not
listed here - anyone who cares about those reads the code.

An entry is written under `## Unreleased` in the same commit as the change it
describes. That way the notes for a release already exist when the release is
cut, instead of being reconstructed from the git log after the fact.
`tools/release.sh X.Y.Z` promotes `## Unreleased` to `## X.Y.Z - YYYY-MM-DD`,
leaves a fresh empty `## Unreleased` behind, and publishes the promoted body
verbatim as the GitHub release notes.

Installed clients read this file too: the package fetches the raw copy from
`main` and shows the matching `## X.Y.Z` section when it finds a newer
release. Everything written here is text a player will eventually be shown.

The release tag format `vX.Y.Z` and the asset name
`WillowdaleMudletUI.mpackage` are a contract - the in-package updater builds
`https://github.com/MorquinDevlar/WillowdaleMudletUI/releases/download/vX.Y.Z/WillowdaleMudletUI.mpackage`
out of the version number alone - so neither may change.

## Unreleased

### Added
- **The Willowdale widget set on MDW.** Character, Combat, Affects, Group,
  Equipment, Inventory, Keyring, Forage, Quests, Journal, Communications and
  Mudlet's native map, arranged in the web client's layout across the two
  docks and driven live by the game's GMCP feed. Every widget can be moved,
  grouped into tabs, resized, floated or closed, and MDW remembers where you
  put it.
- **Character, Combat, Affects and Group panels.** Identity, attributes,
  wealth, XP and the game clock/calendar; HP/AE/Balance/Enemy gauges with
  combat status and a clickable enemy list that targets on click and
  re-targets when your target dies; buffs and states with countdowns that keep
  ticking between updates; group members with health bands.
- **Clickable item lists.** Equipment, Inventory, Keyring and Forage each act
  on a click - look, use with the item's own verb, drop, remove - by sending
  the real game command, exactly as if you had typed it.
- **Quests widget** - the quests you are tracking plus anything turn-in-able
  in the zone you are standing in, with track toggles and per-quest detail
  fetched on demand.
- **Journal widget** - the whole `journal` command in one place: books,
  documents, rumors, observations and your own notes, paginated and pulled a
  page at a time, plus a Quests category holding the full quest list with zone,
  status and category filters.
- **Communications** - channel tabs (All / Room / Global / Tells / Group) with
  the server's own history replayed when the UI loads, and an All tab that
  mirrors every message.
- **GMCP prompt bar** - your real in-game prompt as the server sends it, with
  HP, AE, Balance and Enemy gauges and a worth line beside it. Each element
  toggles from the bar's own menu, and your choices persist with the layout.
- **Top bar** - character name and class, how long this session has been
  connected, and the UI, MDW and mapper versions.
- **Numpad walking** - keypad 1-9 walk (5 looks), `-` goes up and `+` goes
  down, whether or not the command line already holds text. They are ordinary
  Mudlet keys under WillowdaleMudletUI > Numpad Walking, so you can read and
  edit them; on by default, and `ui numpad off` hands the keypad back. PC
  keypads need NumLock on; the arrow keys are untouched.
- **The `ui` command** - the entire interface from the keyboard, with all
  output on the main window where a screen reader is reading. Show, hide,
  toggle, focus, float, dock, group and ungroup widgets; flip the sidebars and
  the prompt bar; set dock widths, widget heights, fonts and the theme; scroll
  and read a widget's text; switch comm tabs; toggle prompt-bar and Combat
  elements; walk quests and the journal; `ui refresh` to re-ask the server for
  data, `ui debug` to see what actually arrived, `ui reset` and `ui rebuild`.
  Bare `ui` prints a status screen listing every command with its current
  value and its options, each line clickable, and `ui help <command>`
  explains one. Names match on a unique prefix and widgets answer to their
  spoken shorthands, so `ui sh que` is `ui show quests`.
- Revealing a widget with the keyboard puts it back where it was - its old
  group, otherwise the end of its old dock - rather than floating it in the
  middle of the screen where there is no drag to put it back with.
- **The package's own icon**, so it is recognisable in Mudlet's package
  manager, and Fira Code - the same face the web client and the website use -
  bundled so the interface renders in it and you can pick it in Mudlet's
  settings for the main window too.
- **Self-update.** The UI checks GitHub once when it builds and tells you
  what a newer release changed, straight from this changelog. Nothing is
  downloaded until you say so: click the offer's link or type `ui update
  install`, and `ui update` asks again whenever you want. There is no
  background polling. The download is checked before anything is removed, so
  a failed one leaves the working UI exactly where it was.
- **One package to install.** The UI runs on the MDW framework, and installs
  it for you when it is missing or too old - Mudlet cannot do that on its own.
  A newer MDW than the UI needs is never touched, the download is checked
  before the MDW you are running is replaced, and if it cannot be fetched you
  are told where to get it by hand.
- Install order with MDW does not matter, in either direction, and the UI
  rebuilds itself when MDW updates. MDW 0.4.0 or newer is required: with an
  older MDW the package declines to build and prints one explanatory line
  instead of half a UI while the version it needs is fetched.
