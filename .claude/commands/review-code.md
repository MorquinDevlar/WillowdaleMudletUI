---
description: Perform a comprehensive code review of current changes.
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(grep:*), Bash(rg:*), Bash(git merge-base:*), Bash(git show:*), Read, Glob, Grep
---

IMPORTANT: Use ultrathink when doing the review.

## Usage

```
/review-code                    # Review all changes in current branch vs base branch
/review-code HEAD               # Review the latest commit only
/review-code abc123             # Review specific commit by hash
/review-code HEAD~3             # Review the commit 3 commits ago
/review-code HEAD~3..HEAD       # Review last 3 commits
/review-code --full-context     # Review changes with analysis of surrounding code
/review-code --entire-codebase  # Full codebase review (not just changes)
```

## Review Process

I'll analyze your code changes focusing on these critical areas:

### 1. Lua/Mudlet Pattern Adherence
- **String literals**: Use double quotes for strings, escape internal quotes properly
- **Naming conventions**:
  - Global tables: PascalCase (e.g., `WillowdaleMudletUI`, `ui`)
  - Local variables: camelCase or snake_case consistently
  - Functions: camelCase for local, descriptive names for global (e.g., `ui.updatePlayerGauges`)
  - Constants: UPPER_SNAKE_CASE for true constants
- **Nil checking**: Always check for nil before accessing table fields from GMCP data
- **Event handlers**: Must be registered properly in UI_Settings.lua
- **GMCP data access**: Use GMCP helper functions from `Core Functions/GMCP_Helpers.lua`
- **Table initialization**: Initialize tables with `{}` before use
- **String formatting**: Use `f()` from fText library for formatted strings

### 2. Code Location and Organization
- **Core Functions** (`src/scripts/Core Functions/`): Utility functions, settings, color maps, GMCP helpers
- **UI Containers** (`src/scripts/UI Containers/`): Container creation and management
- **Update Container Info** (`src/scripts/Update Container Info/`): Display update functions
- **Informational** (`src/scripts/Informational/`): Walking, room tracking, notes
- **Triggers** (`src/triggers/`): Pattern-based triggers for game output
- **Aliases** (`src/aliases/`): User command shortcuts
- **Keys** (`src/keys/`): Keyboard bindings
- **scripts.json files**: Must correctly reference all Lua files in the folder

### 3. Event-Driven Architecture
- All UI updates should be triggered by GMCP events, not polling
- Event handlers defined in `UI_Settings.lua` using `registerAnonymousEventHandler`
- Common events: `gmcp.Char.*`, `gmcp.Room.*`, `gmcp.Game.*`, `gmcp.Party.*`
- System events: `sysConnectionEvent`, `sysLoadEvent`, `sysExitEvent`, `sysWindowResizeEvent`

### 4. Code Redundancy and Reuse
- Search for existing functionality in utility modules
- Check `Core Functions/Utility_Functions.lua` before creating new helpers
- Check `Core Functions/GMCP_Helpers.lua` for GMCP data access patterns
- Flag duplicate code, dead code, and unused variables
- Suggest specific existing functions that could be extended

### 5. Mudlet API Usage
- **Containers**: Use AdjustableContainer API correctly
- **Labels**: Proper use of `createLabel`, `setLabelStyleSheet`
- **Gauges**: Correct gauge creation and updates with `setGauge`
- **EMCO**: Proper multi-console object usage for tabbed displays
- **Timers**: Use `tempTimer` for one-shot, `registerAnonymousEventHandler` for recurring
- **Echo functions**: Use appropriate echo variant (`cecho`, `decho`, `hecho`, `echo`)

### 6. Data Persistence
- Settings saved to `getMudletHomeDir()/WillowdaleMudletUI/`
- Use `table.save()` and `table.load()` for Lua table persistence
- Handle missing files gracefully on first load

### 7. Code Efficiency and Clarity
- Avoid global variable pollution - use the `ui` namespace
- Prefer local variables for performance in loops
- Question unnecessary abstractions
- Prefer simple, self-documenting solutions
- Avoid numbered steps in comments like "STEP 1:"

### 8. Comment Quality
- Keep comments simple and direct
- Comments should explain WHY, not WHAT
- Remove redundant comments that just restate code
- Flag TODO/FIXME comments that should be addressed

## Execution Steps

1. First, I'll determine what to review:
   - If no argument provided: Detect actual branch commits by finding the merge base with main
   - Use `git merge-base main HEAD` to find where branch diverged
   - Review ONLY commits unique to current branch (not shared with main)
   - If commit specified: Review that specific commit or range
2. Verify JSON structure:
   - Check all `scripts.json`, `triggers.json`, `aliases.json`, `keys.json` files
   - Ensure they correctly reference all Lua files
   - Validate JSON syntax
3. Analyze existing codebase patterns for consistency
4. Review the changes against Mudlet/Lua patterns
5. Search for existing code that could be reused
6. Check for common Lua issues (nil access, global leaks)
7. Provide a comprehensive report with:
   - Quick summary of changes
   - Critical issues that must be fixed
   - Redundancy report with reusable code suggestions
   - Efficiency improvements
   - Actionable comment review

### Branch Detection Logic
When reviewing without arguments, I will:
1. Find the merge base: `git merge-base main HEAD`
2. List branch-only commits: `git log --oneline <merge-base>..HEAD`
3. Review diff of branch changes: `git diff <merge-base>..HEAD`
4. This ensures I ONLY review changes introduced by your branch, not changes from main
5. The diff is still against current main, so it validates your changes work with latest code

## Architecture-Specific Checks

### UI Structure
- **Left Panel**: Character info, equipment, affects, room details
- **Right Panel**: Chat channels, mapper integration
- **Bottom Panel**: Health/mana gauges, prompt display
- **Top Panel**: Status bar with mapper info

### GMCP Data Flow
1. **GMCP Data Arrival** → Event triggered (e.g., `gmcp.Char.Vitals`)
2. **Event Handler** → Calls update function (e.g., `ui.updatePlayerGauges()`)
3. **Update Function** → Processes GMCP data and updates display
4. **Display Update** → Updates labels, gauges, or console output

### Key GMCP Structures
- `gmcp.Char.Vitals` - Health, mana, movement points
- `gmcp.Char.Balance` - Combat balance timing
- `gmcp.Char.Combat.*` - Combat status, targets, enemies
- `gmcp.Char.Inventory.*` - Equipment and backpack
- `gmcp.Room.Info.*` - Room details and contents
- `gmcp.Party.*` - Group member information

### External Dependencies
- **EMCO** - Multi-console management (loaded via require)
- **fText** - Text formatting and tables
- **DemonTools** - Utility functions

## Critical Review Focus

### Default Behavior (Branch/Commit Review)
When reviewing specific changes, I will:
1. **ONLY flag issues introduced by the changes** - Not pre-existing problems
2. **Check if new code follows existing patterns** - Even if those patterns have issues
3. **Verify issues are actually new** - Compare with base branch before reporting
4. **Focus on the diff** - Only review code that was actually modified
5. **Note when following bad patterns** - "Follows existing pattern (which has issues)"

### Full Context Review (--full-context)
When requested, I will also:
- Analyze surrounding code that interacts with changes
- Identify pre-existing issues that might affect new code
- Suggest broader refactoring opportunities

### Entire Codebase Review (--entire-codebase)
Comprehensive analysis including:
- All existing code quality issues
- Systemic pattern problems
- Technical debt identification
- JSON configuration completeness

## Review Philosophy

**By default, I assume you want a focused PR review** that helps you merge clean changes without being blocked by pre-existing issues. The review will:
- Distinguish between "new problems" and "following existing bad patterns"
- Not penalize you for consistency with existing code
- Focus on regressions and new bugs introduced
- Suggest fixes only for issues your changes created

Example output for pre-existing pattern:
```
Note: The new code follows the existing pattern of not nil-checking GMCP data.
This is a pre-existing issue in the codebase, not introduced by this PR.
```

## Review Verification Standards

### CRITICAL: Preventing False Positives
**NEVER report issues without complete verification. False positives destroy trust.**

### Mandatory Verification Process
Before reporting ANY issue, you MUST:

1. **Verify the Issue Actually Exists**
   - NEVER assume based on patterns that "look wrong"
   - ALWAYS trace the full code path to confirm
   - Check for nil guards, default values, or error handling elsewhere
   - Verify issues are INTRODUCED BY THIS BRANCH, not pre-existing

2. **Test Your Claims**
   - For "nil access": Check if guards exist in the call chain
   - For "missing event handler": Verify it's not registered elsewhere
   - For "unused variable": Search entire codebase first
   - For "JSON mismatch": Verify the actual file references

3. **Common False Positive Patterns to AVOID**
   - "Nil access risk" - CHECK for guards in calling code first
   - "Missing from scripts.json" - CHECK if file is included via parent folder
   - "Unused function" - CHECK for dynamic calls via string names
   - "Event not handled" - CHECK UI_Settings.lua event registrations

4. **Evidence Requirements**
   - Show EXACT code proving the issue (not just line numbers)
   - Trace COMPLETE execution path showing how issue occurs
   - Provide COUNTER-EVIDENCE search (did you look for guards?)
   - If guards exist elsewhere, issue is FALSE POSITIVE

5. **Three-Strike Verification**
   Before reporting an issue, ask yourself:
   - Strike 1: Did I verify this is actually broken, not just different?
   - Strike 2: Did I check for defensive code/guards elsewhere?
   - Strike 3: Is this actually NEW in this branch or pre-existing?

   If ANY strike fails, DO NOT REPORT THE ISSUE.

6. **Language for Uncertainty**
   If you cannot fully verify:
   - "Unable to verify if..." (not "There is a problem with...")
   - "Could not find guard for..." (not "Nil access bug in...")
   - "Recommend manual verification of..." (not "Found issue in...")

### Review Trust Guidelines
Users should:
- **Request evidence**: "Show me where that issue exists"
- **Ask for examples**: "Give me 3 specific instances of that problem"
- **Challenge vague claims**: Vague warnings often indicate unverified assumptions
- **Demand specifics**: If a review claims issues without line numbers, ask for them
- **Question theoretical issues**: "Will this actually cause problems in practice?"

Ready to analyze your WillowdaleMudletUI code changes with verified, evidence-based feedback!
