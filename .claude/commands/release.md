---
description: Commit changes, build the mpackage, and commit the built package in one step.
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(grep:*), Bash(rg:*), Bash(git merge-base:*), Bash(git show:*), Bash(git add:*), Bash(git commit:*), Bash(git status:*), Bash(docker run:*), Read, Edit, AskUserQuestion
---

IMPORTANT: Use ultrathink when doing the review.

This command performs a full release cycle:
1. Review and commit source changes (with version bump)
2. Build the .mpackage using muddle
3. Commit the built package

---

## Step 1: Version Bump Process

Before committing, handle version bumping:

1. Read the current version from `mfile` (JSON file with "version" field using semver: MAJOR.MINOR.PATCH)
2. Ask the user which version component to increment:
   - **Patch** (1.0.0 → 1.0.1): Bug fixes, small changes
   - **Minor** (1.0.0 → 1.1.0): New features, backward compatible
   - **Major** (1.0.0 → 2.0.0): Breaking changes
   - **Skip**: No version change for this commit
3. If not skipped, update the version in `mfile` using the Edit tool
4. Include `mfile` in the staged changes before committing

Example version bump:
- Current: "version": "1.2.3"
- User selects: Minor
- New: "version": "1.3.0" (patch resets to 0 on minor bump, minor resets to 0 on major bump)

If version was bumped, include "Bumped version to X.Y.Z" at the end of the commit message body.

## Step 2: Release Notes Update

When a version is bumped (not skipped), update `releases/releases.json`:

1. Read the current `releases/releases.json` file
2. Add a new entry at the **beginning** of the array with:
   - `version`: The new version number
   - `released`: Today's date in YYYY-MM-DD format
   - `changes`: Array of user-facing changelog entries
3. Ask the user to provide or confirm the changelog entries:
   - These should be short, player-friendly descriptions (not technical commit details)
   - Focus on what the player will notice or benefit from
   - Use past tense ("Added", "Fixed", "Improved")
   - Keep each entry to one line
4. Include `releases/releases.json` in the staged changes

Example entry:
```json
{
    "version": "1.1.0",
    "released": "2025-01-20",
    "changes": [
        "Added support for locked doors",
        "Fixed map not updating after teleport"
    ]
}
```

## Step 3: Commit Message Style and Guidelines

When writing commit messages, follow this format:
NEVER add any information about the commit being written or handled by Claude Code

1. **Title**: Brief, factual description of changes (50-72 characters maximum, no adjectives like "better", "improved", etc.)
2. **Body**: Bullet points listing specific changes:
   - Use past tense ("Fixed", "Added", "Removed", not "Fix", "Add", "Remove")
   - Be specific and technical
   - No subjective assessments (avoid "simpler", "better", "faster", "cleaner")
   - No hyperbole
   - Just state what changed, not why it is good
   - Group related changes together in this order: Added, Fixed, Changed, Removed
3. **Breaking changes**: List any breaking changes separately at the end

Keep it neutral, factual, and technical.

IMPORTANT: Make sure to remove the Claude Code signature.

## Step 4: Build the Package

After the source commit succeeds, build the .mpackage:

```bash
docker run --pull always --rm -v "$(pwd)":"$(pwd)" -w "$(pwd)" demonnic/muddler
```

This will create/update `build/WillowdaleMudletUI.mpackage`.

## Step 5: Commit the Built Package

After the build succeeds:

1. Stage the built package: `git add build/WillowdaleMudletUI.mpackage`
2. Commit with message: `Built mpackage for version X.Y.Z`

---

## Summary of Actions

1. Review changes with `git status` and `git diff`
2. Ask user for version bump choice
3. Update `mfile` and `releases/releases.json` if version bumped
4. Create source commit
5. Run muddle build
6. Commit the built .mpackage
