---
description: Cut a release by handing off to tools/release.sh X.Y.Z, after checking the tree and the Unreleased notes.
allowed-tools: Bash(git status:*), Bash(git log:*), Bash(git rev-parse:*), Bash(git fetch:*), Bash(git diff:*), Bash(gh auth status), Bash(gh release view:*), Bash(tools/release.sh:*), Read, AskUserQuestion
---

CRITICAL: Read and follow EVERY instruction in this file exactly. Do not fall back on default behaviors.
- `tools/release.sh X.Y.Z` is the ONLY way a release is cut. Never bump `mfile`
  or `mdwui.version` by hand, never `git tag`, never `gh release create`, never
  run `muddle` and commit its output - the script does all of it in one order
  and undoes the whole thing if any step fails
- NEVER commit the built `.mpackage`. `build/` is gitignored; the package ships
  as a release asset, which is exactly where the in-package updater looks
- Uncommitted work is NOT part of a release. If the tree is dirty, run
  `/commit` first - that is where the changelog entry and the verification gate
  belong
- Follow the execution order step by step

### What the script does

`tools/release.sh X.Y.Z`, in this order: checks its prerequisites (git, gh, lua5.1, muddle, luacheck, an authenticated `gh`), refuses to run off `main`, with a dirty tree, when `main` is behind origin, when the tag or GitHub release already exists, or when `## Unreleased` is empty; bumps `"version"` in `mfile` and `mdwui.version` in `src/scripts/MDWUI_Config.lua`; promotes `## Unreleased` in `CHANGELOG.md` to `## X.Y.Z - <today>` and extracts that body as the release notes; runs `lua5.1 tests/smoke.lua`, luacheck, and `muddle`, and checks that `build/WillowdaleMudletUI.mpackage` exists and is non-empty; commits "Release X.Y.Z"; tags `vX.Y.Z`; pushes `main` and the tag; publishes the GitHub release with the built `.mpackage` attached.

Anything that fails from the bump onwards restores `mfile`, `src/scripts/MDWUI_Config.lua` and `CHANGELOG.md` and stops, so a failed run leaves the tree as clean as it found it.

The tag format `vX.Y.Z` and the asset name `WillowdaleMudletUI.mpackage` are a contract: the package's own updater builds `https://github.com/MorquinDevlar/WillowdaleMudletUI/releases/download/vX.Y.Z/WillowdaleMudletUI.mpackage` out of the version number and reads the notes from `CHANGELOG.md` raw on `main`. Neither may change without breaking every installed client's update path.

### Execution Order

1. **Check the tree**: `git status --porcelain`. If it is not empty, stop and tell the user to run `/commit` first - the release script will refuse a dirty tree anyway, and an uncommitted change would be released untested and unlisted.
2. **Check the branch and origin**: `git rev-parse --abbrev-ref HEAD` must be `main`; `git fetch origin` then confirm `main` is not behind `origin/main`. Report either problem instead of trying to fix it.
3. **Check gh**: `gh auth status`. If it fails, stop - the script would otherwise fail after the tag was already pushed.
4. **Read the notes**: read the `## Unreleased` section of `CHANGELOG.md`. If it is empty, stop: there is nothing to release, and entries belong in the commit that made the change (see `/commit`). Otherwise show the full section verbatim - this is the text GitHub and the updater will show players.
5. **Pick the version**: read the current version from `mfile`, then use **AskUserQuestion**: "Which release?" with the concrete numbers computed into the labels:
   - **Patch** (X.Y.Z -> X.Y.Z+1): fixes, nothing new to learn
   - **Minor** (X.Y.Z -> X.Y+1.0): new widgets, new `ui` verbs, new keys - and, while the package is 0.x, anything that changes existing behaviour
   - **Major** (X.Y.Z -> X+1.0.0): reserved for 1.0 and later breaking changes
   - **Cancel**: stop here
   Base the recommendation on the `## Unreleased` body you just read.
6. **Confirm**: show the exact command and state that it pushes `main`, the tag `vX.Y.Z`, and a public GitHub release that installed clients will offer to their players. Use **AskUserQuestion**: "Run tools/release.sh X.Y.Z now?" with options Yes/No.
7. **Run it**: on Yes, run `tools/release.sh X.Y.Z`. Relay its summary - the tag and the release URL. On failure, report the failing step verbatim and confirm with `git status` that the tree was restored; do not retry or patch around it without asking.
