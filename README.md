# Windows Terminal Handoff Fix

**English** | [简体中文](README.zh-CN.md)

Windows Terminal Handoff Fix addresses two cases in which Windows falls back to the legacy console host: consoles allocated by GUI applications and elevated processes affected by COM activation failures.

| Component                   | Purpose                                                                                                                                         |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Windhawk mod                | Corrects the `ConsoleApp` flag in GUI applications' console connection requests so that Windows can evaluate them for default-terminal handoff. |
| Terminal deployment scripts | Install Microsoft's official unpackaged Windows Terminal distribution and register its x86 and x64 COM servers and proxies at machine scope.    |

The components can be used independently. The mod applies to applications that Windhawk can inject into; it requires no application-specific launcher and does not replace Windows system files.

## Requirements

- Windows 11 x64, with Windows Terminal selected as the default terminal application.
- A standard, registry-backed installation of Windhawk 1.7 or later, including its bundled compiler and import libraries.
- 64-bit PowerShell 7.4 or later to run the scripts.
- Administrator privileges to install, update, remove, enable, or disable a component.

The optional Terminal deployment downloads the latest stable release from Microsoft's GitHub Releases. Downloads are verified against GitHub's SHA-256 digests, and executables and COM proxies are checked for valid Microsoft signatures.

## Installation

Open an administrator PowerShell 7 session in the project directory, then build and install the mod:

```powershell
./scripts/Build-Mod.ps1
./scripts/Manage-Mod.ps1 -Action Install
```

The mod uses the existing default terminal and leaves its settings unchanged. Restart an application to ensure that the mod is loaded before it allocates a console. Consoles that are already open are not migrated.

### Application exceptions

Windhawk's global exclusions remain in effect. To allow a specific application during installation, replace the mod installation command with:

```powershell
./scripts/Manage-Mod.ps1 -Action Install -IncludeApplication 'C:\Applications\Example\Example.exe'
```

The executable must exist. The script adds an exception for that path and excludes the application from other matching mods to prevent those mods from being injected through the same exception. `-IncludeApplication` is an installation option; it does not modify an existing mod installation.

### Optional: repair elevated COM activation

If elevated applications cannot activate the packaged Terminal, install the unpackaged distribution with machine-level COM registration:

```powershell
./scripts/Manage-Terminal.ps1 -Action Install -RemoveStore -ContextMenu
```

Application files are installed in `C:\Program Files\Windows Terminal\app`. Use `-InstallPath` to choose a different installation root; application files are placed in its `app` subdirectory. The installation root must not already exist. The script does not adopt installations managed by other tools.

`-RemoveStore` removes the packaged Terminal for the account running the script. Before removal, the script saves the matching official package for recovery. Other accounts are unaffected. Without this option, the packaged Terminal remains installed and may still be preferred by non-elevated processes. Existing unpackaged settings are preserved; packaged settings and Fragments are copied only if the destination settings directory is empty.

`-ContextMenu` adds a classic "Open in Terminal" menu for folders, folder backgrounds, and drives. On Windows 11, the menu appears under "Show more options." The unpackaged distribution does not include Store updates or the packaged distribution's modern context-menu extension. See [Windows Terminal distributions](https://learn.microsoft.com/windows/terminal/distributions) for details.

## How it works

### GUI console allocation

Windows checks whether a console connection qualifies for handoff before activating the default terminal. A GUI application calling `AllocConsole()` can send a ConDrv connection request with `ConsoleApp` set to false. The console host's [`_shouldAttemptHandoff`](https://github.com/microsoft/terminal/blob/main/src/server/IoDispatchers.cpp) rejects such a request before attempting activation.

The mod hooks the exported `AllocConsole` API and, when available, `AllocConsoleWithOptions`. During a console allocation call, it inspects `NtCreateFile` requests to ConDrv and parses their extended attributes according to the [console connection layout](https://github.com/microsoft/terminal/blob/main/dep/Console/conmsgl1.h) published in the Windows Terminal repository.

Before modifying a request, the parser validates the device path or parent device, EA names and chain boundaries, payload size, Boolean fields, and UTF-16 string bounds. It then forwards a corrected copy of an eligible `server` request, leaving the caller's buffer unchanged. Attach requests, hidden or minimized windows, and unrecognized messages pass through unchanged. Windows continues to apply the remaining handoff conditions.

Function addresses are resolved from exports at runtime. The mod does not depend on private function offsets, instruction signatures, system-DLL hashes, or downloaded symbols. `AllocConsoleWithOptions` is optional because it was introduced in Windows 11 24H2; earlier releases use `AllocConsole`. Changes to DLL addresses do not require offset updates, but an incompatible ConDrv protocol change may require changes to the parser.

### Elevated COM activation

Handoff also depends on COM activation. If an elevated process cannot discover the packaged Terminal's COM server, activation may fail with `REGDB_E_CLASSNOTREG` (`0x80040154`), causing a fallback to the legacy host. This limitation is discussed in [microsoft/terminal#10276](https://github.com/microsoft/terminal/issues/10276); its applicability depends on the Windows version and installation method.

The optional deployment scripts register the unpackaged Terminal's x86 and x64 COM servers and proxies at machine scope. This addresses activation failures independently of the mod's correction to GUI console requests.

## Maintenance

To inspect or change the mod's state:

```powershell
./scripts/Manage-Mod.ps1 -Action Status
./scripts/Manage-Mod.ps1 -Action Disable
./scripts/Manage-Mod.ps1 -Action Enable
```

Installing the mod or changing its state restarts the Windhawk service.

For Terminal installations managed by the deployment script:

```powershell
./scripts/Manage-Terminal.ps1 -Action Status
./scripts/Manage-Terminal.ps1 -Action Update
./scripts/Manage-Terminal.ps1 -Action Repair
```

Close all sessions using the managed Terminal installation before updating, and run the update script from another console host. Updates preserve the installation path and user settings, attempt to restore the previous version on failure, and remove obsolete binaries and temporary downloads after success. `Repair` reapplies COM registration and the other registered integration settings. Updates are started manually.

Modification commands support `-WhatIf` to preview operations without applying changes or requesting elevation:

```powershell
./scripts/Manage-Mod.ps1 -Action Install -WhatIf
./scripts/Manage-Terminal.ps1 -Action Install -RemoveStore -WhatIf
```

## Uninstallation and recovery

To remove the mod:

```powershell
./scripts/Manage-Mod.ps1 -Action Uninstall
```

To remove a Terminal installation managed by the deployment script:

```powershell
./scripts/Manage-Terminal.ps1 -Action Uninstall
```

Mod removal uses the installation records to identify its libraries and application exceptions. Terminal removal restores recorded registry values and removes the PATH entry added by the installer. Independently modified registry values are preserved. If the packaged Terminal was removed during installation, the saved official package is used to restore it and copy the Terminal settings back. Unpackaged user settings are retained.

Installation records and recovery packages are stored under `%PROGRAMDATA%\WindowsTerminalHandoffFix`. Use `-StateRoot` to select a different state directory, and supply the same path for maintenance and uninstallation. Run these operations under the Windows account used for installation. Keep the records and recovery packages until uninstallation is complete.

Temporary directory deletion is limited to verified directories created by the scripts and bypasses the Recycle Bin. If automatic rollback fails, the script returns an error and retains the recovery state.

## Limitations

- The mod supports x86 and x64 applications. Native ARM64 applications and Windhawk's portable storage layout are not supported by the deployment scripts.
- Services, non-interactive sessions, and requests for hidden or minimized consoles retain their existing behavior.
- Protected processes, globally excluded applications, and applications that Windhawk cannot inject into may still use the legacy host.
- Windows handoff checks remain in effect, including explicit requests to disable handoff. The system's compatibility fallback is preserved.
- Machine-level COM registration does not change every account's default-terminal preference. Default-terminal selection and settings migration apply to the account running the script.

## License

Source code and scripts are licensed under the [MIT License](LICENSE). Windows Terminal, Windhawk, and their toolchains are covered by their respective licenses. Microsoft binaries and Windhawk runtime libraries are not bundled with the project.
