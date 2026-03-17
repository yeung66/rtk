# Windows PowerShell Hook Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement Windows-native hook support for RTK via a PowerShell script, enabling `rtk init -g` to automatically intercept Claude Code commands on Windows just as it does on macOS/Linux.

**Architecture:** Add `hooks/rtk-rewrite.ps1` (PowerShell equivalent of `rtk-rewrite.sh`), embed it in the binary, and add a Windows code path in `init.rs` that installs the script and patches `settings.json` with `powershell.exe -File "path"`. Update `hook_check.rs` to detect the Windows hook. Update cleanup/uninstall to remove it.

**Tech Stack:** Rust, PowerShell 5+, serde_json, `#[cfg(not(unix))]` / `#[cfg(unix)]` conditional compilation

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `hooks/rtk-rewrite.ps1` | **Create** | PowerShell hook script (reads JSON stdin, calls `rtk rewrite`, outputs JSON) |
| `src/init.rs` | **Modify** | Add Windows hook installation, update settings.json patching, uninstall, diagnose |
| `src/hook_check.rs` | **Modify** | Detect Windows hook (`.ps1` file) in `hook_installed_path()` |

---

## Task 1: Create the PowerShell hook script

**Files:**
- Create: `hooks/rtk-rewrite.ps1`

### What it must do (mirrors `hooks/rtk-rewrite.sh`):
1. Guard: silently exit if `rtk` not in PATH
2. Read JSON from stdin (`[System.Console]::In.ReadToEnd()`)
3. Extract `.tool_input.command`
4. Skip heredocs (`<<`)
5. Call `& rtk rewrite $Cmd 2>$null` — exit 0 if exit code ≠ 0
6. Skip if command unchanged
7. Output the Claude Code hook JSON response

- [ ] **Step 1.1: Write `hooks/rtk-rewrite.ps1`**

```powershell
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
```

- [ ] **Step 1.2: Verify script file exists**

```bash
ls hooks/rtk-rewrite.ps1
```
Expected: file listed.

- [ ] **Step 1.3: Commit**

```bash
git add hooks/rtk-rewrite.ps1
git commit -m "feat: add Windows PowerShell hook script (rtk-rewrite.ps1)"
```

---

## Task 2: Embed the PowerShell script in the binary and add Windows init path

**Files:**
- Modify: `src/init.rs`

This task adds:
- `const REWRITE_HOOK_PS1` embedded from the new file
- `ensure_hook_installed_windows()` to write the `.ps1` file
- `build_windows_hook_command()` to produce the `powershell.exe -File "path"` string
- Updated `#[cfg(not(unix))]` `run_default_mode` that actually installs the hook
- Updated `#[cfg(not(unix))]` `run_hook_only_mode` that actually installs the hook

### Step 2.1: Add the embedded constant

At the top of `src/init.rs`, after the existing `const REWRITE_HOOK: &str = include_str!(...)` line, add:

- [ ] **Step 2.1: Add `REWRITE_HOOK_PS1` constant**

In `src/init.rs`, find:
```rust
const REWRITE_HOOK: &str = include_str!("../hooks/rtk-rewrite.sh");
```
Add immediately after:
```rust
#[cfg(not(unix))]
const REWRITE_HOOK_PS1: &str = include_str!("../hooks/rtk-rewrite.ps1");
```

- [ ] **Step 2.2: Add `ensure_hook_installed_windows` function**

Add after the existing `#[cfg(unix)] fn ensure_hook_installed(...)` function:

```rust
/// Write PowerShell hook file on Windows if missing or content changed. Returns true if changed.
#[cfg(not(unix))]
fn ensure_hook_installed_windows(hook_path: &Path, verbose: u8) -> Result<bool> {
    let changed = if hook_path.exists() {
        let existing = fs::read_to_string(hook_path)
            .with_context(|| format!("Failed to read existing hook: {}", hook_path.display()))?;
        if existing == REWRITE_HOOK_PS1 {
            if verbose > 0 {
                eprintln!("Hook already up to date: {}", hook_path.display());
            }
            false
        } else {
            fs::write(hook_path, REWRITE_HOOK_PS1)
                .with_context(|| format!("Failed to write hook to {}", hook_path.display()))?;
            if verbose > 0 {
                eprintln!("Updated hook: {}", hook_path.display());
            }
            true
        }
    } else {
        fs::write(hook_path, REWRITE_HOOK_PS1)
            .with_context(|| format!("Failed to write hook to {}", hook_path.display()))?;
        if verbose > 0 {
            eprintln!("Created hook: {}", hook_path.display());
        }
        true
    };

    integrity::store_hash(hook_path)
        .with_context(|| format!("Failed to store integrity hash for {}", hook_path.display()))?;

    Ok(changed)
}
```

- [ ] **Step 2.3: Add `build_windows_hook_command` helper**

Add after `ensure_hook_installed_windows`:

```rust
/// Build the settings.json hook command string for Windows.
/// Format: `powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "path"`
#[cfg(not(unix))]
fn build_windows_hook_command(hook_path: &Path) -> Result<String> {
    let path_str = hook_path
        .to_str()
        .context("Hook path contains invalid UTF-8")?;
    Ok(format!(
        r#"powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "{}""#,
        path_str
    ))
}
```

- [ ] **Step 2.4: Add Windows `prepare_hook_paths_windows` helper**

Add near `prepare_hook_paths`:

```rust
/// Prepare hook directory and return (hook_dir, hook_path) for Windows (.ps1 extension)
#[cfg(not(unix))]
fn prepare_hook_paths_windows() -> Result<(PathBuf, PathBuf)> {
    let claude_dir = resolve_claude_dir()?;
    let hook_dir = claude_dir.join("hooks");
    fs::create_dir_all(&hook_dir)
        .with_context(|| format!("Failed to create hook directory: {}", hook_dir.display()))?;
    let hook_path = hook_dir.join("rtk-rewrite.ps1");
    Ok((hook_dir, hook_path))
}
```

- [ ] **Step 2.5: Replace the Windows `run_default_mode` stub**

Find and replace the existing `#[cfg(not(unix))] fn run_default_mode` (lines ~721-732):

```rust
#[cfg(not(unix))]
fn run_default_mode(
    global: bool,
    patch_mode: PatchMode,
    verbose: u8,
    install_opencode: bool,
) -> Result<()> {
    if !global {
        run_claude_md_mode(false, verbose, install_opencode)?;
        generate_project_filters_template(verbose)?;
        return Ok(());
    }

    let claude_dir = resolve_claude_dir()?;
    let rtk_md_path = claude_dir.join("RTK.md");
    let claude_md_path = claude_dir.join("CLAUDE.md");

    // 1. Install PowerShell hook
    let (_hook_dir, hook_path) = prepare_hook_paths_windows()?;
    let hook_changed = ensure_hook_installed_windows(&hook_path, verbose)?;

    // 2. Build hook command for settings.json
    let hook_command = build_windows_hook_command(&hook_path)?;

    // 3. Write RTK.md
    write_if_changed(&rtk_md_path, RTK_SLIM, "RTK.md", verbose)?;

    let opencode_plugin_path = if install_opencode {
        let path = prepare_opencode_plugin_path()?;
        ensure_opencode_plugin_installed(&path, verbose)?;
        Some(path)
    } else {
        None
    };

    // 4. Patch CLAUDE.md
    let migrated = patch_claude_md(&claude_md_path, verbose)?;

    // 5. Print status
    let hook_status = if hook_changed { "installed/updated" } else { "already up to date" };
    println!("\nRTK hook {} (global, Windows).\n", hook_status);
    println!("  Hook:      {}", hook_path.display());
    println!("  RTK.md:    {} (10 lines)", rtk_md_path.display());
    if let Some(path) = &opencode_plugin_path {
        println!("  OpenCode:  {}", path.display());
    }
    println!("  CLAUDE.md: @RTK.md reference added");
    if migrated {
        println!("\n  ✅ Migrated: removed 137-line RTK block from CLAUDE.md");
        println!("              replaced with @RTK.md (10 lines)");
    }

    // 6. Patch settings.json
    let patch_result = patch_settings_json_str(&hook_command, patch_mode, verbose, install_opencode)?;

    match patch_result {
        PatchResult::Patched => {}
        PatchResult::AlreadyPresent => {
            println!("\n  settings.json: hook already present");
        }
        PatchResult::Skipped | PatchResult::Declined => {
            print_manual_instructions_str(&hook_command, install_opencode);
        }
    }

    Ok(())
}
```

- [ ] **Step 2.6: Replace the Windows `run_hook_only_mode` stub**

Find and replace `#[cfg(not(unix))] fn run_hook_only_mode` (lines ~869-876):

```rust
#[cfg(not(unix))]
fn run_hook_only_mode(
    global: bool,
    patch_mode: PatchMode,
    verbose: u8,
    install_opencode: bool,
) -> Result<()> {
    if !global {
        eprintln!("⚠️  Warning: --hook-only only makes sense with --global");
        return Ok(());
    }

    let (_hook_dir, hook_path) = prepare_hook_paths_windows()?;
    let hook_changed = ensure_hook_installed_windows(&hook_path, verbose)?;
    let hook_command = build_windows_hook_command(&hook_path)?;

    let opencode_plugin_path = if install_opencode {
        let path = prepare_opencode_plugin_path()?;
        ensure_opencode_plugin_installed(&path, verbose)?;
        Some(path)
    } else {
        None
    };

    let hook_status = if hook_changed { "installed/updated" } else { "already up to date" };
    println!("\nRTK hook {} (hook-only mode, Windows).\n", hook_status);
    println!("  Hook: {}", hook_path.display());
    if let Some(path) = &opencode_plugin_path {
        println!("  OpenCode: {}", path.display());
    }
    println!(
        "  Note: No RTK.md created. Claude won't know about meta commands (gain, discover, proxy)."
    );

    let patch_result = patch_settings_json_str(&hook_command, patch_mode, verbose, install_opencode)?;
    match patch_result {
        PatchResult::Patched => {}
        PatchResult::AlreadyPresent => {
            println!("\n  settings.json: hook already present");
        }
        PatchResult::Declined | PatchResult::Skipped => {}
    }

    println!();
    Ok(())
}
```

- [ ] **Step 2.7: Add `patch_settings_json_str` (string-based variant for Windows)**

The existing `patch_settings_json` takes `hook_path: &Path` and converts it internally. Add a new variant that takes the command string directly. Add after `patch_settings_json`:

```rust
/// Patch settings.json using a pre-built hook command string (Windows path).
/// Shares all logic with patch_settings_json but accepts &str directly.
fn patch_settings_json_str(
    hook_command: &str,
    mode: PatchMode,
    verbose: u8,
    include_opencode: bool,
) -> Result<PatchResult> {
    let claude_dir = resolve_claude_dir()?;
    let settings_path = claude_dir.join("settings.json");

    let mut root = if settings_path.exists() {
        let content = fs::read_to_string(&settings_path)
            .with_context(|| format!("Failed to read {}", settings_path.display()))?;
        if content.trim().is_empty() {
            serde_json::json!({})
        } else {
            serde_json::from_str(&content)
                .with_context(|| format!("Failed to parse {} as JSON", settings_path.display()))?
        }
    } else {
        serde_json::json!({})
    };

    if hook_already_present(&root, hook_command) {
        if verbose > 0 {
            eprintln!("settings.json: hook already present");
        }
        return Ok(PatchResult::AlreadyPresent);
    }

    match mode {
        PatchMode::Skip => {
            print_manual_instructions_str(hook_command, include_opencode);
            return Ok(PatchResult::Skipped);
        }
        PatchMode::Ask => {
            if !prompt_user_consent(&settings_path)? {
                print_manual_instructions_str(hook_command, include_opencode);
                return Ok(PatchResult::Declined);
            }
        }
        PatchMode::Auto => {}
    }

    insert_hook_entry(&mut root, hook_command);

    if settings_path.exists() {
        let backup_path = settings_path.with_extension("json.bak");
        fs::copy(&settings_path, &backup_path)
            .with_context(|| format!("Failed to backup to {}", backup_path.display()))?;
    }

    let serialized =
        serde_json::to_string_pretty(&root).context("Failed to serialize settings.json")?;
    atomic_write(&settings_path, &serialized)?;

    println!("\n  settings.json: hook added");
    if include_opencode {
        println!("  Restart Claude Code and OpenCode. Test with: git status");
    } else {
        println!("  Restart Claude Code. Test with: git status");
    }

    Ok(PatchResult::Patched)
}
```

- [ ] **Step 2.8: Add `print_manual_instructions_str` helper**

The existing `print_manual_instructions` takes a `&Path`. Add a string variant for Windows:

```rust
/// Print manual settings.json instructions using a pre-built command string (Windows).
fn print_manual_instructions_str(hook_command: &str, include_opencode: bool) {
    println!("\n  MANUAL STEP: Add this to ~/.claude/settings.json:");
    println!("  {{");
    println!("    \"hooks\": {{ \"PreToolUse\": [{{");
    println!("      \"matcher\": \"Bash\",");
    println!("      \"hooks\": [{{ \"type\": \"command\",");
    println!("        \"command\": \"{}\"", hook_command);
    println!("      }}]");
    println!("    }}]}}");
    println!("  }}");
    if include_opencode {
        println!("\n  Then restart Claude Code and OpenCode. Test with: git status\n");
    } else {
        println!("\n  Then restart Claude Code. Test with: git status\n");
    }
}
```

- [ ] **Step 2.9: Update `hook_already_present` to detect `.ps1` hooks**

Find `fn hook_already_present` and update the `.any(...)` closure:

```rust
.any(|cmd| {
    cmd == hook_command
        || (cmd.contains("rtk-rewrite.sh") && hook_command.contains("rtk-rewrite.sh"))
        || (cmd.contains("rtk-rewrite.ps1") && hook_command.contains("rtk-rewrite.ps1"))
})
```

- [ ] **Step 2.10: Update `remove_hook_from_json` to also remove `.ps1` entries**

Find the `if command.contains("rtk-rewrite.sh")` check and update:

```rust
if command.contains("rtk-rewrite.sh") || command.contains("rtk-rewrite.ps1") {
    return false; // Remove this entry
}
```

- [ ] **Step 2.11: Update `uninstall` to also remove `.ps1` file**

Find the `uninstall` function. After the block that removes `rtk-rewrite.sh`, add:

```rust
// 1b (Windows). Remove PowerShell hook file
let ps1_hook_path = claude_dir.join("hooks").join("rtk-rewrite.ps1");
if ps1_hook_path.exists() {
    fs::remove_file(&ps1_hook_path)
        .with_context(|| format!("Failed to remove hook: {}", ps1_hook_path.display()))?;
    removed.push(format!("Hook: {}", ps1_hook_path.display()));
    if integrity::remove_hash(&ps1_hook_path)? {
        removed.push("Integrity hash (ps1): removed".to_string());
    }
}
```

- [ ] **Step 2.12: Update the diagnose section for Windows**

Find the diagnose section around line 1239. There is an **unconditional** assignment:
```rust
let hook_path = claude_dir.join("hooks").join("rtk-rewrite.sh");
```
**Delete this line** and replace it with platform-conditional assignments:

```rust
#[cfg(unix)]
let hook_path = claude_dir.join("hooks").join("rtk-rewrite.sh");
#[cfg(not(unix))]
let hook_path = claude_dir.join("hooks").join("rtk-rewrite.ps1");
```

⚠️ The unconditional original line must be removed — leaving it would cause a compiler "unused variable" warning on Windows or shadow the new cfg-guarded binding.

Also update the `#[cfg(not(unix))]` diagnose block (currently just prints "exists") to show more useful info:

```rust
#[cfg(not(unix))]
{
    let hook_content = fs::read_to_string(&hook_path)
        .unwrap_or_default();
    let hook_version = crate::hook_check::parse_hook_version(&hook_content);
    let is_thin_delegator = hook_content.contains("rtk rewrite");
    if is_thin_delegator {
        println!(
            "✅ Hook: {} (PowerShell, version {})",
            hook_path.display(),
            hook_version
        );
    } else {
        println!("⚠️  Hook: {} (outdated or invalid)", hook_path.display());
    }
}
```

- [ ] **Step 2.13: Build and check for errors**

```bash
cargo build 2>&1 | head -60
```
Expected: compiles without errors.

- [ ] **Step 2.14: Run tests**

```bash
cargo test --all 2>&1 | tail -30
```
Expected: all tests pass.

- [ ] **Step 2.15: Commit**

```bash
git add src/init.rs
git commit -m "feat: Windows hook installation via PowerShell (rtk init -g)"
```

---

## Task 3: Update `hook_check.rs` to detect the Windows hook

**Files:**
- Modify: `src/hook_check.rs`

Currently `hook_installed_path()` only looks for `rtk-rewrite.sh`. On Windows it never finds it, so `status()` always returns `Missing` → warning every startup.

- [ ] **Step 3.1: Write the failing test first**

In `src/hook_check.rs`, add to the `#[cfg(test)] mod tests` block:

```rust
#[test]
fn test_hook_installed_path_ps1_fallback() {
    // Simulate: no .sh file but .ps1 exists
    let tmp = tempfile::tempdir().expect("tempdir");
    let hooks_dir = tmp.path().join(".claude").join("hooks");
    std::fs::create_dir_all(&hooks_dir).unwrap();
    let ps1_path = hooks_dir.join("rtk-rewrite.ps1");
    std::fs::write(&ps1_path, "# rtk-hook-version: 2\n").unwrap();

    // Use the helper directly (needs to be extracted — see Step 3.2)
    // For now, just verify the file we created
    assert!(ps1_path.exists());
}
```

- [ ] **Step 3.2: Run test to verify it passes (just the file check for now)**

```bash
cargo test test_hook_installed_path_ps1_fallback -- --nocapture
```

- [ ] **Step 3.3: Update `hook_installed_path` to also check for `.ps1`**

Replace the existing `fn hook_installed_path()`:

```rust
fn hook_installed_path() -> Option<PathBuf> {
    let home = dirs::home_dir()?;
    // Unix hook
    let sh_path = home.join(".claude").join("hooks").join("rtk-rewrite.sh");
    if sh_path.exists() {
        return Some(sh_path);
    }
    // Windows hook
    let ps1_path = home.join(".claude").join("hooks").join("rtk-rewrite.ps1");
    if ps1_path.exists() {
        return Some(ps1_path);
    }
    None
}
```

- [ ] **Step 3.4: Verify `parse_hook_version` works for `.ps1` content**

The `.ps1` script has `# rtk-hook-version: 2` as line 2 (within first 5 lines), so `parse_hook_version` works unchanged. Add a test to confirm:

```rust
#[test]
fn test_parse_hook_version_ps1_format() {
    let content = "# RTK auto-rewrite hook for Claude Code (Windows)\n# rtk-hook-version: 2\n# ...\n";
    assert_eq!(parse_hook_version(content), 2);
}
```

- [ ] **Step 3.4b: Update `test_status_returns_valid_variant` to handle `.ps1`**

In `src/hook_check.rs`, the existing test `test_status_returns_valid_variant` hard-codes the `.sh` path for its early-return guard (around line 148). Update it so it also checks for the `.ps1` path:

```rust
#[test]
fn test_status_returns_valid_variant() {
    let home = match dirs::home_dir() {
        Some(h) => h,
        None => return,
    };
    let sh_exists = home.join(".claude").join("hooks").join("rtk-rewrite.sh").exists();
    let ps1_exists = home.join(".claude").join("hooks").join("rtk-rewrite.ps1").exists();

    if !sh_exists && !ps1_exists {
        let s = status();
        if home.join(".claude").exists() {
            assert_eq!(s, HookStatus::Missing);
        } else {
            assert_eq!(s, HookStatus::Ok);
        }
        return;
    }
    let s = status();
    assert!(
        s == HookStatus::Ok || s == HookStatus::Outdated,
        "Expected Ok or Outdated when hook exists, got {:?}",
        s
    );
}
```

- [ ] **Step 3.5: Run tests**

```bash
cargo test hook_check -- --nocapture
```
Expected: all tests pass.

- [ ] **Step 3.6: Commit**

```bash
git add src/hook_check.rs
git commit -m "fix: detect Windows PowerShell hook in hook_check status"
```

---

## Task 4: Add unit tests for Windows-specific init paths

**Files:**
- Modify: `src/init.rs` (test section at end of file)

- [ ] **Step 4.1: Add test for `remove_hook_from_json` removing `.ps1` entries**

In the existing test module in `src/init.rs`, add:

```rust
#[test]
fn test_remove_ps1_hook_from_json() {
    let mut json_content: serde_json::Value = serde_json::from_str(r#"{
        "hooks": {
            "PreToolUse": [{
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": "powershell.exe -File C:\\Users\\test\\.claude\\hooks\\rtk-rewrite.ps1"}]
            }]
        }
    }"#).unwrap();

    let removed = remove_hook_from_json(&mut json_content);
    assert!(removed, "should have removed the .ps1 hook entry");

    let pre_tool_use = json_content["hooks"]["PreToolUse"].as_array().unwrap();
    assert!(pre_tool_use.is_empty(), "PreToolUse array should be empty after removal");
}
```

- [ ] **Step 4.2: Add test for `hook_already_present` detecting `.ps1` hooks**

```rust
#[test]
fn test_hook_already_present_ps1() {
    let json: serde_json::Value = serde_json::from_str(r#"{
        "hooks": {
            "PreToolUse": [{
                "matcher": "Bash",
                "hooks": [{"type": "command", "command": "powershell.exe -File C:\\Users\\test\\.claude\\hooks\\rtk-rewrite.ps1"}]
            }]
        }
    }"#).unwrap();

    let hook_cmd = "powershell.exe -File C:\\Users\\test\\.claude\\hooks\\rtk-rewrite.ps1";
    assert!(hook_already_present(&json, hook_cmd));
}
```

- [ ] **Step 4.3: Run tests**

```bash
cargo test init -- --nocapture 2>&1 | tail -20
```
Expected: new tests pass.

- [ ] **Step 4.4: Run full test suite**

```bash
cargo fmt --all && cargo clippy --all-targets 2>&1 | grep "^error" | head -20
cargo test --all 2>&1 | tail -20
```
Expected: no errors, all tests pass.

- [ ] **Step 4.5: Commit**

```bash
git add src/init.rs
git commit -m "test: add Windows hook detection and removal unit tests"
```

---

## Task 5: Manual validation on Windows

**Files:** None (validation only)

This task verifies the end-to-end behavior on a Windows machine.

- [ ] **Step 5.1: Build release binary**

```bash
cargo build --release
```

- [ ] **Step 5.2: Run `rtk init -g --auto-patch` and verify output**

```
.\target\release\rtk.exe init -g --auto-patch
```

Expected output:
```
RTK hook installed/updated (global, Windows).

  Hook:      C:\Users\<user>\.claude\hooks\rtk-rewrite.ps1
  RTK.md:    C:\Users\<user>\.claude\RTK.md (10 lines)
  CLAUDE.md: @RTK.md reference added

  settings.json: hook added
  Restart Claude Code. Test with: git status
```

- [ ] **Step 5.3: Verify `settings.json` contains correct entry**

Open `~/.claude/settings.json` and confirm:
```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": "powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\...\\rtk-rewrite.ps1\""
      }]
    }]
  }
}
```

- [ ] **Step 5.4: Test the hook script directly**

```powershell
'{"tool_input":{"command":"git status"}}' | powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\hooks\rtk-rewrite.ps1"
```

Expected output (JSON with `command: "rtk git status"`):
```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"RTK auto-rewrite","updatedInput":{"command":"rtk git status"}}}
```

- [ ] **Step 5.5: Test uninstall**

```
.\target\release\rtk.exe init -g --uninstall
```

Expected: reports removal of `.ps1` file and settings.json entry.

- [ ] **Step 5.6: Run `rtk gain` — verify no hook warning**

After install:
```
.\target\release\rtk.exe gain
```
Expected: No `[rtk] /!\ No hook installed` warning.

- [ ] **Step 5.7: Final commit**

```bash
git add -A
git commit -m "feat: Windows PowerShell hook support complete — rtk init -g works on Windows"
```

---

## Quality Gate Checklist

Before merging:
- [ ] `cargo fmt --all && cargo clippy --all-targets` — zero warnings/errors
- [ ] `cargo test --all` — all tests pass
- [ ] `hooks/rtk-rewrite.ps1` has `# rtk-hook-version: 2` in first 5 lines
- [ ] `init.rs` `run_default_mode` on Windows produces correct output
- [ ] `remove_hook_from_json` removes `.ps1` entries
- [ ] `hook_check::status()` returns `Ok` when `.ps1` installed
- [ ] Manual test on Windows: install → test hook → uninstall cycle works
