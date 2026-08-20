---
description: Commit changes with optional version bump
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git status:*), Bash(git add:*), Bash(git commit:*), Read, Edit, Write, AskUserQuestion
---

### Version Bump Process

Before committing, handle version bumping:

1. Read the current version from `mfile` (JSON file with "version" field using semver: MAJOR.MINOR.PATCH)
2. Ask the user which version component to increment:
   - **Patch** (1.0.0 → 1.0.1): Bug fixes, small changes
   - **Minor** (1.0.0 → 1.1.0): New features, backward compatible
   - **Major** (1.0.0 → 2.0.0): Breaking changes
   - **Skip**: No version change for this commit
3. If not skipped:
   - Update the version in `mfile` using the Edit tool
   - Ask the user for player-facing changelog entries (see Releases Update below)
   - Update `releases/releases.json` with new release entry
4. Include `mfile` and `releases/releases.json` in staged changes before committing

Semver Rules:

| Bump Type | Example       | When to Use                        |
|-----------|---------------|------------------------------------|
| Patch     | 1.0.0 → 1.0.1 | Bug fixes, typos, small tweaks     |
| Minor     | 1.0.0 → 1.1.0 | New features (backward compatible) |
| Major     | 1.0.0 → 2.0.0 | Breaking changes, API changes      |

Reset rules:
- Minor bump: patch resets to 0
- Major bump: minor and patch reset to 0

---

### Releases Update Process

When version is bumped (not skipped), update `releases/releases.json`:

1. Ask the user: "What player-facing changes should be shown in the update notification?"
   - These are SHORT descriptions players see when an update is available
   - Should be 1-5 bullet points summarizing what changed from a player's perspective
   - Focus on features/fixes that matter to users, not internal code changes
   - Examples: "Added party vitals display", "Fixed inventory not updating", "New color customization options"

2. Read the current `releases/releases.json` file

3. Add a NEW entry at the TOP of the array with:
   ```json
   {
       "version": "X.Y.Z",
       "released": "YYYY-MM-DD",
       "changes": [
           "First change",
           "Second change"
       ]
   }
   ```
   - Use today's date for "released"
   - Use the new version number
   - Use the changelog entries from the user

4. Write the updated releases.json file (must remain valid JSON array)

Example releases.json structure:
```json
[
    {
        "version": "2.1.0",
        "released": "2025-12-17",
        "changes": [
            "Added group vitals display",
            "Fixed channel colors not applying"
        ]
    },
    {
        "version": "2.0.0",
        "released": "2025-12-16",
        "changes": [
            "Previous release notes..."
        ]
    }
]
```

If version was bumped, include "Bumped version to X.Y.Z" at the end of the commit message body.

---

### Commit Message Style and Guidelines

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

Example:

  Modified GMCP module architecture and exit information

  Added:
  - PlayerDespawn cleanup handlers to all combat modules
  - User validation with validateUserForGMCP helper function
  - ExitLockChanged event for exit state notifications
  - GMCP handler to send Room.Info.Exits updates on lock changes
  - Exit details map with type, state, name, hasKey, and hasPicked fields
  - Package documentation explaining design patterns for each module

  Fixed:
  - Memory leaks from uncleaned tracking maps
  - Function naming inconsistencies in Status and Events modules
  - Redundant "exits" wrapper in Room.Info.Exits output

  Changed:
  - Cooldown timer interval from 250ms to 200ms
  - Mutex usage to RLock for read-only operations
  - Exit state values to "locked" and "open"

  Removed:
  - Unused imports from gmcp.go and combat modules
  - Unused gmcp_batcher.go file
  - Rate limiting code from damage module

  Breaking Changes:
  - Room.Info.Exits now exists as a primary node (previously Room.Info.Exits.exits)

Keep it neutral, factual, and technical.

IMPORTANT: Make sure to remove the Claude Code signature.
