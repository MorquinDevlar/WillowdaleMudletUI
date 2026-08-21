#!/usr/bin/env bash
#
# Cut a WillowdaleMUD UI release. Usage: tools/release.sh X.Y.Z
#
# One command for the whole sequence, so every release is made the same way:
# bump the two version strings, run the verification gate, build the package,
# promote the changelog, commit, tag, push, and publish the GitHub release.
#
# The script expects the CHANGELOG "Unreleased" discipline: each change lands
# with its entry under "## Unreleased" as it is written, so at release time
# there are no notes to reconstruct from the git log. The promoted section
# becomes the GitHub release notes verbatim, and an empty Unreleased section
# is a hard stop rather than a release with no notes.
#
# The tag format vX.Y.Z and the asset basename WillowdaleMudletUI.mpackage are
# a CONTRACT with the package's own updater. It derives the download URL from
# the version alone:
#   https://github.com/MorquinDevlar/WillowdaleMudletUI/releases/download/vX.Y.Z/WillowdaleMudletUI.mpackage
# and reads the release notes by fetching CHANGELOG.md raw from main. Rename
# the tag or the asset, or move the changelog, and every already-installed
# client loses its update path - they have no other way to find a release.

set -euo pipefail

die() {
    printf 'release: %s\n' "$*" >&2
    exit 1
}

step() {
    printf '==> %s\n' "$*"
}

# Everything from the bump onwards is undone on failure, so a botched run
# leaves the tree exactly as clean as it was found.
restore_and_die() {
    git checkout -- mfile src/scripts/MDWUI_Config.lua CHANGELOG.md
    die "$*"
}

[ $# -eq 1 ] || die "usage: tools/release.sh X.Y.Z"
version=$1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z, got '$version'"
tag="v$version"

repo_root=$(git rev-parse --show-toplevel) || die "not inside a git repository"
cd "$repo_root"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
notes_file="$tmpdir/notes.md"

step "Checking prerequisites"
for tool in git gh lua5.1 muddle; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not on PATH: $tool"
done
# luacheck is a luarocks install, whose bin dir is often not on PATH.
if command -v luacheck >/dev/null 2>&1; then
    luacheck=luacheck
else
    luacheck="$HOME/.luarocks/bin/luacheck"
fi
[ -x "$luacheck" ] || die "luacheck not found on PATH or at $luacheck"
# An unauthenticated gh would only fail at the very end, after the tag is
# already pushed - a half-made release. Fail here instead.
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run 'gh auth login' first"

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = main ] || die "releases are cut from main, but HEAD is on '$branch'"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean; commit or stash first"

step "Fetching origin"
git fetch origin
# Being ahead of origin is fine - the script pushes main itself, so unpushed
# commits (e.g. the one /commit just made) ride along. Being behind is the
# hazard: the push would be rejected after the release commit and tag exist.
git merge-base --is-ancestor origin/main main ||
    die "main is behind origin/main; pull first"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    die "tag $tag already exists locally"
fi
if [ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]; then
    die "tag $tag already exists on origin"
fi
if gh release view "$tag" >/dev/null 2>&1; then
    die "a GitHub release for $tag already exists"
fi

[ -f CHANGELOG.md ] || die "CHANGELOG.md is missing"
grep -q '^## Unreleased[[:space:]]*$' CHANGELOG.md || die "CHANGELOG.md has no '## Unreleased' heading"
if ! awk '/^## Unreleased[[:space:]]*$/ { inside = 1; next }
          inside && /^## / { exit }
          inside' CHANGELOG.md | grep -q '[^[:space:]]'; then
    die "the '## Unreleased' section is empty; write the release notes under '## Unreleased' first"
fi

# The smoke suite asserts that mfile and mdwui.version agree (as it asserts
# mdwui.packageName matches the mfile "package"), so both must be bumped
# before the gate runs, not after it.
step "Bumping version to $version"
sed "s/\"version\": \"[^\"]*\"/\"version\": \"$version\"/" mfile >"$tmpdir/mfile"
mv "$tmpdir/mfile" mfile
sed "s/^mdwui\.version = \".*\"/mdwui.version = \"$version\"/" src/scripts/MDWUI_Config.lua >"$tmpdir/config.lua"
mv "$tmpdir/config.lua" src/scripts/MDWUI_Config.lua
grep -q "\"version\": \"$version\"" mfile || restore_and_die "failed to bump the version in mfile"
grep -q "^mdwui\.version = \"$version\"$" src/scripts/MDWUI_Config.lua ||
    restore_and_die "failed to bump mdwui.version in src/scripts/MDWUI_Config.lua"

step "Promoting the changelog"
today=$(date +%F)
heading="## $version - $today"
awk -v heading="$heading" '
    !promoted && /^## Unreleased[[:space:]]*$/ {
        print "## Unreleased"
        print ""
        print heading
        promoted = 1
        next
    }
    { print }
' CHANGELOG.md >"$tmpdir/CHANGELOG.md"
mv "$tmpdir/CHANGELOG.md" CHANGELOG.md
# The section body, minus leading and trailing blank lines, is the release
# note - both on GitHub and in the updater's "what changed" prompt, which
# parses this same heading out of the raw file on main.
awk -v heading="$heading" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside
' CHANGELOG.md | awk '
    /[^[:space:]]/ { for (i = 0; i < blanks; i++) print ""; blanks = 0; started = 1; print; next }
    started { blanks++ }
' >"$notes_file"
[ -s "$notes_file" ] || restore_and_die "could not extract release notes for $version"

step "Running the smoke suite"
lua5.1 tests/smoke.lua || restore_and_die "smoke suite failed"
step "Running luacheck"
"$luacheck" src/ tests/ || restore_and_die "luacheck reported warnings"
step "Building the package"
muddle || restore_and_die "muddle build failed"
# Muddler names the output after the mfile "package" value, so this check also
# catches an mfile whose package name drifted away from the asset the updater
# expects to download.
[ -s build/WillowdaleMudletUI.mpackage ] ||
    restore_and_die "muddle produced no build/WillowdaleMudletUI.mpackage"

step "Committing"
git add mfile src/scripts/MDWUI_Config.lua CHANGELOG.md
git commit -m "Release $version"

step "Tagging $tag"
git tag -a "$tag" -m "WillowdaleMUD UI $version"

# main goes up before the release exists, so the CHANGELOG the updater fetches
# raw from main already carries the section for the version it is about to see.
step "Pushing to origin"
git push origin main
git push origin "$tag"

# The asset keeps its basename, WillowdaleMudletUI.mpackage, which is the half
# of the download URL the updater constructs rather than discovers.
step "Publishing the GitHub release"
release_url=$(gh release create "$tag" build/WillowdaleMudletUI.mpackage --title "$tag" --notes-file "$notes_file")
printf '    %s\n' "$release_url"

printf '\nReleased WillowdaleMUD UI %s\n' "$version"
printf '  tag:     %s\n' "$tag"
printf '  release: %s\n' "$release_url"
