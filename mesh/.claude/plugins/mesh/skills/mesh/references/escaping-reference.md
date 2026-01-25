# Escaping Reference

Quick reference for character escaping when running PowerShell commands via SSH.

## Escaping Layers

When executing PowerShell via SSH, commands pass through multiple interpretation layers:

```
Python string → SSH client → Remote shell (CMD) → PowerShell → Execution
```

Each layer has distinct escaping rules that must be considered.

## Character Reference Table

| Character | Python String | PowerShell Single Quote | SSH→PowerShell Combined |
|-----------|---------------|------------------------|-------------------------|
| Single quote `'` | `'` (no escape) | `''` (doubled) | `''''` (in complex cases) |
| Double quote `"` | `\"` | `"` (literal in SQ) | `\\\"` |
| Backslash `\` | `\\` | `\` (literal) | `\\` |
| Dollar sign `$` | `$` (no escape) | `$` (literal in SQ) | `$` |
| Backtick `` ` `` | `` ` `` | `` ` `` (escape char in DQ) | `` ` `` |
| Newline | `\n` | Not allowed in SQ | Use `;` instead |

## Common Patterns

### Simple Command Execution

```python
# Check if file exists
cmd = 'powershell -Command "Test-Path \'C:\\Program Files\\Tailscale\\tailscale.exe\'"'
```

Breakdown:
- Outer Python string uses single quotes
- PowerShell command wrapped in double quotes
- Path uses escaped single quotes (for Python) that become literal single quotes in PowerShell

### Command with Variable

```python
ts_exe = "C:\\Program Files\\Tailscale\\tailscale.exe"
cmd = f"powershell -Command \"& '{ts_exe}' status\""
```

Pattern: `& 'path with spaces' arguments`

The `&` call operator executes the path as a command.

### Multi-Statement Command

```python
cmd = (
    'powershell -Command "'
    "Stop-Service Tailscale -Force; "
    "Start-Sleep 2; "
    'Start-Service Tailscale"'
)
```

Use semicolons to separate statements within a single `-Command` string.

### Writing File Content

```python
content = "Write-Host 'Hello World'"
escaped = content.replace("'", "''")  # Double single quotes
cmd = f"powershell -Command \"Set-Content 'C:\\temp\\script.ps1' '{escaped}'\""
```

## Multi-Line Script Creation

For complex scripts, build line-by-line:

```python
lines = [
    "# Script header",
    "$Message = 'Hello'",
    "Write-Host $Message",
]

ps_cmds = ["New-Item -Path 'C:\\temp' -ItemType Directory -Force | Out-Null"]
for i, line in enumerate(lines):
    escaped = line.replace("'", "''")
    if i == 0:
        ps_cmds.append(f"Set-Content 'C:\\temp\\script.ps1' '{escaped}'")
    else:
        ps_cmds.append(f"Add-Content 'C:\\temp\\script.ps1' '{escaped}'")

full_cmd = "; ".join(ps_cmds)
ssh_cmd = f'powershell -Command "{full_cmd}"'
```

## Base64 Alternative

For very complex scripts, encode as Base64 to avoid escaping entirely:

```python
import base64

script = """
Write-Host 'Complex script with "quotes" and $variables'
Get-Process | Where-Object { $_.CPU -gt 100 }
"""

# PowerShell expects UTF-16LE encoding
encoded = base64.b64encode(script.encode('utf-16-le')).decode('ascii')
cmd = f'powershell -EncodedCommand {encoded}'
```

**Advantages:**
- No escaping issues
- Handles any characters including newlines

**Disadvantages:**
- Harder to debug (not human-readable)
- Larger command size

## Debugging Tips

### Print Before Execute

```python
cmd = build_powershell_command()
print(f"Executing: {cmd}")
ssh_run(host, port, cmd)
```

### Test Locally

```bash
# Test the command locally before SSH
powershell -Command "Write-Host 'test'"
```

### Verify Created Files

```python
# After creating a script, read it back
check_cmd = "powershell -Command \"Get-Content 'C:\\temp\\script.ps1'\""
success, content = ssh_run(host, port, check_cmd)
print(f"Created file:\n{content}")
```

## Common Mistakes

### Mistake 1: Unescaped Single Quotes

```python
# Wrong - single quote breaks PowerShell string
cmd = "powershell -Command \"Write-Host 'Hello'\""

# Right - use doubled single quotes
cmd = "powershell -Command \"Write-Host ''Hello''\""
```

### Mistake 2: Forgetting Python String Escaping

```python
# Wrong - \P and \T are escape sequences
path = "C:\Program Files\Tailscale"

# Right - use raw string or double backslashes
path = r"C:\Program Files\Tailscale"
path = "C:\\Program Files\\Tailscale"
```

### Mistake 3: Newlines in SSH Commands

```python
# Wrong - newlines interpreted by SSH
cmd = """powershell -Command "
    Write-Host 'Line 1'
    Write-Host 'Line 2'
"""

# Right - use semicolons
cmd = 'powershell -Command "Write-Host ''Line 1''; Write-Host ''Line 2''"'
```

### Mistake 4: Variable Scope Confusion

```python
# Python variable - expanded before SSH
server_url = "http://sfspark1.local:8080"
cmd = f'powershell -Command "$url = \'{server_url}\'; Write-Host $url"'

# PowerShell variable - expanded on remote (single quotes prevent expansion)
cmd = 'powershell -Command "$env:PATH"'  # Works - shows remote PATH
```

## Related

- `../topics/ssh-powershell-escaping.md` - Detailed escaping patterns
- `../examples/ssh-script-creation.md` - Complete walkthrough
