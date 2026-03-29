# Claude Cowork Fix

A free and open-source Windows workaround for the Claude Desktop cowork/workspace startup failure.

This project targets the Windows error where Claude's packaged `CoworkVMService` fails to start because `cowork-svc.exe` lives inside the locked `WindowsApps` directory. The fix is simple:

1. Find Claude Desktop's installed `cowork-svc.exe`
2. Copy it to a writable local folder
3. Disable the broken packaged service
4. Run the copied binary directly
5. Keep the copied binary in sync after Claude updates

This repository does that without license checks, trials, payment gates, or remote activation.

## What it installs

The runtime is copied to:

`%LOCALAPPDATA%\ClaudeCoworkFix`

That folder stores:

- the copied `cowork-svc.exe`
- `config.json`
- `claude-cowork-fix.log`
- a copy of the PowerShell runtime files used by the scheduled tasks

The repo checkout is only the source. After `install.bat` runs, the scheduled tasks use the runtime files in `LocalAppData`.

## Features

- Installs the workaround with one command
- Copies the current Claude `cowork-svc.exe` out of `WindowsApps`
- Starts the copied binary directly
- Disables `CoworkVMService` to avoid conflicts
- Registers a logon task to start the copied binary automatically
- Registers a 2-hour watcher task to refresh the copied binary after Claude updates
- Restores the original `CoworkVMService` startup mode on uninstall
- Includes an optional tray monitor

## Requirements

- Windows 10 or Windows 11
- Claude Desktop installed
- Administrator rights for `install` and `uninstall`

## Quick start

1. Clone or download this repo.
2. Right-click [`install.bat`](./install.bat) and run it as Administrator.
3. Open Claude Desktop and test cowork/workspace again.

## Commands

- [`install.bat`](./install.bat): install the fix, scheduled tasks, and the copied runtime
- [`status.bat`](./status.bat): show current state
- [`start.bat`](./start.bat): start the copied cowork service
- [`stop.bat`](./stop.bat): stop the copied cowork service
- [`update.bat`](./update.bat): sync the copied binary with the current Claude install
- [`tray.bat`](./tray.bat): open the tray monitor
- [`uninstall.bat`](./uninstall.bat): remove tasks and restore the packaged service startup mode

You can also call the script directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\claude-cowork-fix.ps1 -Status
```

If you delete the repo after installing, the installed runtime still works from:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\ClaudeCoworkFix\scripts\claude-cowork-fix.ps1" -Status
```

## Notes

- `install` and `uninstall` need elevation because they modify scheduled tasks and the packaged Windows service state.
- `start`, `stop`, `status`, and `update` usually do not need elevation after the initial install.
- The updater does not download anything. It only re-copies the local Claude binary already on your machine.

## Project scope

This is a clean-room open-source implementation of the public workaround behavior. It does not reuse the paid repo's licensing system, trial logic, or admin tooling.

This project is not affiliated with Anthropic.

## License

MIT. See [`LICENSE`](./LICENSE).
