---
description: Commit work with verification first, a CHANGELOG entry under Unreleased, a docs check, and an optional release at the end.
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git status:*), Bash(git add:*), Bash(git commit:*), Bash(git pull:*), Bash(git rev-parse:*), Bash(lua5.1:*), Bash(luacheck:*), Bash(~/.luarocks/bin/luacheck:*), Bash(muddle), Bash(tools/release.sh:*), Read, Edit, AskUserQuestion
---

CRITICAL: Read and follow EVERY instruction in this file exactly. Do not fall back on default behaviors.

- Use the AskUserQuestion tool for ALL user questions (changelog, docs, release)
- NEVER add Co-Authored-By or any Claude attribution to commits
- The CHANGELOG is player-facing ONLY: development tooling, tests, CI, and
  Claude Code commands never get an entry - anyone interested reads the code
- NEVER bump the version here. `mfile` and `mdwui.version` move only in
  `tools/release.sh`: the in-package updater compares `mdwui.version` against
  the tags on GitHub, so a version bumped outside a release would make every
  installed client believe it is already up to date with a release that does
  not exist
- NEVER commit `build/` - it is gitignored, and the built `.mpackage` ships as
  a GitHub release asset, not as a tracked file
- Follow the execution order step by step

### Execution Order

Follow these steps in sequence - do not skip ahead to committing:

1. **Pull**: `git pull --ff-only`. If it fails (diverged history), stop and ask the user.
2. **Analyze**: `git status`, `git diff` (staged and unstaged), `git log -5 --oneline`. Read the whole diff and review it against the CLAUDE.md invariants: nothing calls `mdw.*` at load time (seed tables only); panels stay pure functions of the `gmcp` table; renderers write to `widget.content` through `mdwui.bindRenderer` and never through `widget:echo`/`:decho` (that would kill the links on resize); widget actions `send()` real game commands rather than GMCP; payloads are read from the `ansi` field via `ansi2decho`, never `html`; handlers, timers and widgets go through `mdwui.registerHandler` / `mdwui.addTimer` / `mdwui.state.widgets` so `onUninstall` can reach them; every MDW 0.4 call in the `ui` dispatcher is guarded on existence; GMCP field names match the guide exactly. Raise anything off BEFORE committing - that review is the point of this step.
3. **Verify**: run `lua5.1 tests/smoke.lua` and `luacheck src/ tests/` (fall back to `~/.luarocks/bin/luacheck` when `luacheck` is not on PATH). If `src/` or `mfile` changed, also run `muddle`. On any failure: stop, show the output, do not commit.
4. **Smoke coverage**: a new widget, a new `ui` verb, or a new player-facing toggle must arrive with its own check in `tests/smoke.lua` (CLAUDE.md rule). If the diff adds one without a check, say so and add it before continuing.
5. **Changelog**: classify; internal-only changes get NO entry (say so and move on); otherwise ask, draft, get approval, write (see Changelog Entry Process).
6. **Docs**: when the change adds or alters something `README.md` documents, ask whether the README was updated (see Docs Process).
7. **Stage**: the relevant files, including `CHANGELOG.md` if it changed. Never `git add -A` blindly; say what is staged.
8. **Commit**: use the message format below.
9. **Release**: ask whether to cut a release now (see Release Process).

### Before Committing Checklist

Verify these are complete before running `git commit`:

- [ ] Pull: ran `git pull --ff-only`
- [ ] Verify: smoke suite and luacheck passed (and muddle, when `src/` or `mfile` changed)
- [ ] Smoke coverage: new widget / `ui` verb / toggle has a check
- [ ] Changelog: internal-only -> no entry; player-facing -> asked, entry approved and written if wanted
- [ ] Docs: asked when README-documented behaviour changed
- [ ] Version: NOT bumped
- [ ] Staging: `CHANGELOG.md` included if it was modified, `build/` never

---

### Changelog Entry Process

Two rules. First: entries land under `## Unreleased` in `CHANGELOG.md` in the same commit as the change, and `tools/release.sh` later turns that section into the GitHub release notes verbatim - and into what the in-package updater shows a player who is offered the update. Whatever is written there is published, twice. Second: the changelog is player-facing ONLY. The reader is someone playing Willowdale in Mudlet: what they see in the widgets, the prompt bar, the keys, and the `ui` command. Development tooling, tests, CI, and Claude Code commands never get an entry; anyone interested reads the code.

**Player-facing paths (entry expected):**

- `src/scripts/`, `src/aliases/`, `src/keys/`
- `mfile` (the package description players read in the package manager)

**Internal paths (NO entry, do not ask):**

- `tests/`, `tools/`, `.claude/`, `CLAUDE.md`, `.luacheckrc`, `.gitignore`
- `README.md`, unless it documents a behaviour that is itself new - then the entry belongs to the behaviour, not to the README edit

**Process:**

1. Classify the changed files with the paths above plus your judgment.
2. Internal-only change: state that no changelog entry is added (the changelog is player-facing only) and continue with the next step. Otherwise use **AskUserQuestion**: "Add a CHANGELOG entry under Unreleased?" with options Yes/No, stating what looks player-facing.
3. If yes, draft the entry (do NOT write it yet):
   - One bullet per change under `### Added`, `### Changed`, `### Fixed`, or `### Removed` inside `## Unreleased`; create a subsection if missing and keep that order
   - Never add dates or version numbers - the release script does that
   - Name the widget, the `ui` verb, or the key in backticks; describe what the player sees, not how it is implemented
   - No `mdwui.*` internals: a player cannot call them
4. **Get the draft approved.** Show the complete draft in your response text, then use **AskUserQuestion**: "Use this changelog entry?" with options:
   - **Yes**: proceed
   - **Revise**: the user says what to change - rework the draft and ask again
5. Only after approval: edit `CHANGELOG.md` and stage it with the other changes.

**Example lines:**

- Good: "`ui height <widget>` accepts `+n` and `-n` as well as an absolute pixel value."
- Good: "The Affects countdowns keep ticking between GMCP updates instead of freezing at the last received value."
- Bad: "Refactored renderAffects" (implementation, not behaviour)
- Bad: "Various fixes" (too vague)
- Bad: "Added a smoke check for the numpad folder" (tests - never in the changelog)

---

### Docs Process

`README.md` is the player's documentation: the widget list, the `ui` command reference, numpad walking, install, and build instructions. A change to any of those must land in the README in the same commit.

1. If the diff adds or changes a widget, a `ui` verb, a key binding, or the MDW version requirement, use **AskUserQuestion**: "README updated for this change?" with options:
   - **Yes**: continue
   - **Not needed**: continue
   - **Do it now**: make the README edit, then continue
2. There is no wiki clone for this repo; the README is the whole of the player documentation.

---

### Commit Message Style and Guidelines

When writing commit messages, follow this format:

1. **Title**: Brief, factual description of changes (50-72 characters maximum, no adjectives like "better", "improved", etc.)
2. **Body**: Bullet points listing specific changes:
   - Use past tense ("Fixed", "Added", "Removed", not "Fix", "Add", "Remove")
   - Be specific and technical
   - No subjective assessments (avoid "simpler", "better", "faster", "cleaner")
   - No hyperbole
   - Just state what changed, not why it is good
   - Group related changes together in this order: Added, Fixed, Changed, Removed
3. **Breaking changes**: List any breaking changes separately at the end

Example:

Add the ui height verb and its dock-row resolution

Added:

- ui height <widget> <px|+n|-n>, resolving the widget's row through its stack
- Overview row and smoke checks for absolute and relative heights

Fixed:

- ui show on a grouped widget returning it to the dock end instead of its group

Changed:

- Widget resolution tries mdwui.widgetSynonyms before mdw.findWidget

Keep it neutral, factual, and technical.

---

### Release Process

Releases are cut by `tools/release.sh X.Y.Z` and only by it. The script bumps `mfile` and `mdwui.version`, promotes `## Unreleased` to `## X.Y.Z - <date>`, runs smoke/luacheck/muddle, commits "Release X.Y.Z", tags `vX.Y.Z`, pushes main (unpushed commits from this session ride along), and publishes the GitHub release with `build/WillowdaleMudletUI.mpackage`. The tag format and the asset name are a contract: the in-package updater constructs `https://github.com/MorquinDevlar/WillowdaleMudletUI/releases/download/vX.Y.Z/WillowdaleMudletUI.mpackage` from the version alone and reads the notes from `CHANGELOG.md` raw on main.

1. Read the current version from `mfile` (`"version": "X.Y.Z"`).
2. Use **AskUserQuestion**: "Cut a release now?" with options (compute the concrete numbers into the labels):
   - **No** (Recommended): commit only; the Unreleased section keeps accumulating
   - **Patch** (X.Y.Z -> X.Y.Z+1): fixes, nothing new to learn
   - **Minor** (X.Y.Z -> X.Y+1.0): new widgets, new `ui` verbs, new keys - and, while the package is 0.x, anything that changes existing behaviour
   - **Major** (X.Y.Z -> X+1.0.0): reserved for 1.0 and later breaking changes
3. If a bump was chosen: show the exact command (`tools/release.sh X.Y.Z`) and the full `## Unreleased` body (that text is what both GitHub and the updater will show), state that it pushes main and publishes the release, then use **AskUserQuestion**: "Run tools/release.sh X.Y.Z now?" with options Yes/No.
4. On Yes: run `tools/release.sh X.Y.Z` and relay its summary (tag, release URL). On failure the script restores the tree to the committed state; report the failing step verbatim. Its preconditions: clean tree (the commit just made satisfies it), on main and not behind origin, `gh auth status` OK, a non-empty `## Unreleased`.
