# RTK auto-rewrite hook for Claude Code PreToolUse:Bash (Windows)
# rtk-hook-version: 2
# Reads JSON from stdin, rewrites command via `rtk rewrite`, outputs updated JSON.
# Uses `rtk rewrite` as single source of truth — no duplicate mapping logic here.

# Guard: skip silently if rtk is not available
if (-not (Get-Command rtk -ErrorAction SilentlyContinue)) { exit 0 }

# Read JSON from stdin
try {
    $InputJson = [System.Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($InputJson)) { exit 0 }
    $InputData = $InputJson | ConvertFrom-Json
} catch { exit 0 }

$Cmd = $InputData.tool_input.command
if ([string]::IsNullOrWhiteSpace($Cmd)) { exit 0 }

# Skip heredocs (rtk rewrite also skips them, but bail early)
if ($Cmd -match "<<") { exit 0 }

# Rewrite via rtk — single source of truth for all command mappings.
# Non-zero exit = no RTK equivalent, pass through unchanged.
$Rewritten = & rtk rewrite $Cmd 2>$null
if ($LASTEXITCODE -ne 0) { exit 0 }

# If output is identical, command was already using RTK — nothing to do.
if ($Cmd -eq $Rewritten) { exit 0 }

# Build the updated tool_input with all original fields preserved, only command changed.
$UpdatedInput = $InputData.tool_input.PSObject.Copy()
$UpdatedInput.command = $Rewritten

# Output the rewrite instruction in Claude Code hook format.
@{
    hookSpecificOutput = @{
        hookEventName        = "PreToolUse"
        permissionDecision   = "allow"
        permissionDecisionReason = "RTK auto-rewrite"
        updatedInput         = $UpdatedInput
    }
} | ConvertTo-Json -Depth 10 -Compress
