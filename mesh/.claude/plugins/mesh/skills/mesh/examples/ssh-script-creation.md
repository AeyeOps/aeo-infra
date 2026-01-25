# Example: Creating Scripts via SSH

This walkthrough demonstrates creating a PowerShell script on a Windows machine via SSH, handling the escaping complexities.

## The Challenge

Creating a multi-line PowerShell script on a remote Windows machine via SSH involves:
1. Python string escaping
2. SSH command escaping
3. CMD/PowerShell outer layer
4. PowerShell content escaping

## Simple Approach: Single-Line Commands

For simple scripts, chain commands with semicolons:

```python
cmd = 'powershell -Command "Write-Host ''Line 1''; Write-Host ''Line 2''"'
ssh_run(host, port, cmd)
```

**Output on remote:**
```
Line 1
Line 2
```

## Complex Approach: Multi-Line Script Files

For complex scripts, create a file on the remote machine.

### Step 1: Define Script Content

```python
script_path = "C:\\temp\\test-script.ps1"

lines = [
    "# test-script.ps1 - Generated via SSH",
    "$Message = 'Hello from remote script'",
    "",
    "Write-Host '=== Script Starting ===' -ForegroundColor Cyan",
    "Write-Host $Message",
    "Write-Host '=== Script Done ===' -ForegroundColor Green",
]
```

### Step 2: Escape Single Quotes

PowerShell single-quoted strings use doubled single quotes for escaping:

```python
escaped_lines = []
for line in lines:
    escaped = line.replace("'", "''")
    escaped_lines.append(escaped)

# Example:
# "Write-Host 'Hello'" becomes "Write-Host ''Hello''"
```

### Step 3: Build File Creation Commands

Use `Set-Content` for first line, `Add-Content` for subsequent:

```python
ps_cmds = [
    "New-Item -Path 'C:\\temp' -ItemType Directory -Force | Out-Null"
]

for i, line in enumerate(escaped_lines):
    if i == 0:
        ps_cmds.append(f"Set-Content '{script_path}' '{line}'")
    else:
        ps_cmds.append(f"Add-Content '{script_path}' '{line}'")
```

### Step 4: Execute via SSH

Join commands with semicolons and wrap in PowerShell:

```python
ps_script = "; ".join(ps_cmds)
write_cmd = f'powershell -Command "{ps_script}"'

success, output = ssh_run(host, port, write_cmd, timeout=15)
```

### Step 5: Run the Created Script

```python
run_cmd = f"powershell -ExecutionPolicy Bypass -File {script_path}"
success, output = ssh_run(host, port, run_cmd)
```

## Complete Example

```python
def create_and_run_remote_script(host: str, port: int):
    script_path = "C:\\temp\\test-script.ps1"

    # Script content
    lines = [
        "# test-script.ps1",
        "$Name = 'MeSH'",
        "Write-Host \"Hello from $Name\" -ForegroundColor Cyan",
        "Get-Date",
    ]

    # Build creation commands
    ps_cmds = ["New-Item -Path 'C:\\temp' -ItemType Directory -Force | Out-Null"]

    for i, line in enumerate(lines):
        escaped = line.replace("'", "''")
        if i == 0:
            ps_cmds.append(f"Set-Content '{script_path}' '{escaped}'")
        else:
            ps_cmds.append(f"Add-Content '{script_path}' '{escaped}'")

    # Create the script
    ps_script = "; ".join(ps_cmds)
    write_cmd = f'powershell -Command "{ps_script}"'
    success, _ = ssh_run(host, port, write_cmd, timeout=15)

    if not success:
        print("Failed to create script")
        return

    # Run the script
    run_cmd = f"powershell -ExecutionPolicy Bypass -File {script_path}"
    success, output = ssh_run(host, port, run_cmd)

    print(output)
```

## Escaping Reference

| Character | In Python | In PowerShell SQ | Combined |
|-----------|-----------|------------------|----------|
| Single quote `'` | `'` | `''` | `''''` (doubled twice) |
| Double quote `"` | `\"` | `"` | `\\\"` |
| Backslash `\` | `\\` | `\` | `\\` |
| Dollar sign `$` | `$` | `$` (literal in SQ) | `$` |

### Example Transformations

| Original | After `.replace("'", "''")`| In Python String |
|----------|---------------------------|------------------|
| `Write-Host 'Hi'` | `Write-Host ''Hi''` | `"Write-Host ''Hi''"` |
| `$x = 'test'` | `$x = ''test''` | `"$x = ''test''"` |

## Alternative: Base64 Encoding

For very complex scripts, encode in Base64:

```python
import base64

script = """
Write-Host 'Complex script with "quotes" and $variables'
Get-Process | Where-Object { $_.CPU -gt 100 }
"""

# Encode as UTF-16LE (PowerShell's expected format)
encoded = base64.b64encode(script.encode('utf-16-le')).decode('ascii')

cmd = f'powershell -EncodedCommand {encoded}'
ssh_run(host, port, cmd)
```

Advantages:
- No escaping issues
- Handles any characters

Disadvantages:
- Harder to debug
- Larger command size

## Debugging Tips

### Print the Command

```python
print(f"Command: {write_cmd}")
```

### Test Locally First

```bash
# Test on local PowerShell
powershell -Command "Set-Content 'C:\temp\test.txt' 'Hello'; Add-Content 'C:\temp\test.txt' 'World'"
Get-Content C:\temp\test.txt
```

### Check Created File

```python
# Verify file was created
check_cmd = f"powershell -Command \"Get-Content '{script_path}'\""
success, content = ssh_run(host, port, check_cmd)
print(f"File content:\n{content}")
```

## Real-World Example: join-mesh.ps1

See `share-tools/src/mesh/commands/remote.py` line 226-290 for the actual implementation that creates the mesh join script. It demonstrates:
- Complex multi-step script
- Variable interpolation
- Error handling
- User-facing output formatting

## Related

- `../topics/ssh-powershell-escaping.md` - Escaping patterns reference
- `../topics/windows-ipn-limitation.md` - Why script creation is needed
- `./provision-windows.md` - Where this is used in practice
