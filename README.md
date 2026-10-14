# Windows Update automation

`Invoke-WindowsUpdateLoop.ps1` installs **all** Windows updates on a PC that is
being staged – normal updates, **optional updates** (preview cumulative updates,
drivers) and updates for other Microsoft products – and **reboots and resumes by
itself** until nothing is left.

No extra modules needed: it uses the Windows Update Agent API built into Windows 10/11.

## Usage

Open PowerShell **as Administrator** and run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Invoke-WindowsUpdateLoop.ps1
```

You can start it from a USB stick or network share – the script copies itself to
`C:\ProgramData\WUAutomation` so it keeps working after the reboots.

After the first reboot it continues in the background as SYSTEM (via a scheduled
task called `WUAutomation-ResumeAfterReboot`), so **nobody needs to log on**.
When it is done the scheduled task removes itself.

### Follow progress

```powershell
Get-Content C:\ProgramData\WUAutomation\WUAutomation.log -Wait
```

The last lines show `===== FINISHED: ... =====` with a list of everything installed
and any updates that failed.

### Options

| Parameter | Effect |
|---|---|
| `-Source MicrosoftUpdate` | *(default)* Microsoft Update online – Windows + Office/.NET/etc. Bypasses WSUS so optional updates are offered. |
| `-Source WindowsUpdate` | Windows Update online only. |
| `-Source Default` | Use whatever the PC is configured for (WSUS / Intune / GPO). |
| `-SkipOptional` | Don't install optional ("preview") updates. |
| `-SkipDrivers` | Don't install driver updates. |
| `-IncludeFeatureUpdates` | Also install Windows version upgrades (skipped by default). |
| `-MaxReboots 8` | Safety limit on automatic reboots (default 8). |
| `-NoReboot` | Install what's possible, never reboot automatically (exit code 3010 if a reboot is needed). |

## How it works

1. Reboots first if a reboot is already pending.
2. Searches for every update that isn't installed or hidden.
3. Downloads and installs them silently (servicing-stack style "exclusive" updates are installed on their own first).
4. If a reboot is needed: registers the resume task, reboots, and starts again at step 1.
5. If no reboot is needed: searches again straight away (new updates often appear after others install).
6. Stops when a search finds nothing. Updates that fail are logged and skipped so it can't loop forever.

## Notes / gotchas

- **Group Policy**: if your domain sets *"Do not connect to any Windows Update Internet
  locations"*, the online sources are blocked – use `-Source Default` or stage before
  the GPO applies. If execution policy is enforced by GPO (`AllSigned`), `-ExecutionPolicy Bypass`
  won't help; sign the script or run it from your deployment tool.
- Make sure the PC is on mains power and doesn't go to sleep during the run.
- Stop it early: `Unregister-ScheduledTask WUAutomation-ResumeAfterReboot -Confirm:$false`.
