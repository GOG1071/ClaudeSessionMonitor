# Create a Shortcut

Make a desktop (or Start Menu / pinned) shortcut that opens **Claude Session
Monitor** with a double-click. The shortcut points at `Start Overlay.vbs`, which
launches `overlay.ps1` with **no visible PowerShell console window**.

---

## Quickest way (automated, ~5 seconds)

Run this from the repo folder in PowerShell. It creates **Claude Session
Monitor.lnk** on your Desktop, wired to this clone's `Start Overlay.vbs`:

```powershell
$repo = $PWD.Path
$ws   = New-Object -ComObject WScript.Shell
$lnk  = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Session Monitor.lnk'))
$lnk.TargetPath       = Join-Path $repo 'Start Overlay.vbs'
$lnk.WorkingDirectory = $repo
$lnk.IconLocation     = 'powershell.exe,0'
$lnk.Description       = 'Open the Claude Session Monitor overlay'
$lnk.Save()
Write-Host "Shortcut created on your Desktop."
```

Double-click the new Desktop icon to launch the overlay.

> **Want it in the Start Menu too?** Change the `Desktop` line to:
> `[Environment]::GetFolderPath('ApplicationData') + '\Microsoft\Windows\Start Menu\Programs'`
> then re-run.

---

## Manual way (Explorer, no scripting)

1. In File Explorer, open this repo folder (the one containing `Start Overlay.vbs`).
2. **Right-click `Start Overlay.vbs` → Show more options → Send to → Desktop (create shortcut)**.
   (On Windows 10, it's just **Send to → Desktop (create shortcut)**.)
3. *(Optional)* Rename the Desktop shortcut to **Claude Session Monitor**.
4. *(Optional)* Give it a nicer icon: right-click the shortcut → **Properties → Change Icon…**
   → browse to `powershell.exe` (or any `.ico`) → **OK**.

---

## Launch on Windows startup (optional)

To open the overlay automatically every time you log in, drop the shortcut into
your Startup folder:

1. Press **Win + R**, type `shell:startup`, press **Enter**.
2. Copy the **Claude Session Monitor** shortcut (from above) into that folder.

Or do it in one line from PowerShell (after creating the Desktop shortcut above):

```powershell
Copy-Item `
  (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude Session Monitor.lnk') `
  (Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Session Monitor.lnk')
```

---

## Notes

- The shortcut targets **`Start Overlay.vbs`** (not `overlay.ps1`) so no console
  window flashes. If you point a shortcut at `overlay.ps1` directly, set
  **Target** to:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<REPO>\overlay.ps1"`.
- Moving or re-cloning the repo breaks an existing shortcut — re-run the
  automated command from the new location to recreate it.
- First time setup of the overlay itself (the `~/.claude/settings.json` hooks)
  is covered in [INSTALL.md](INSTALL.md); the shortcut only handles launching.
