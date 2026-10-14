<#
.SYNOPSIS
    Installs all available Windows updates (including optional updates and drivers),
    rebooting and resuming automatically until nothing is left to install.

.DESCRIPTION
    Uses the built-in Windows Update Agent COM API, so no extra modules (such as
    PSWindowsUpdate) are needed and it works on a freshly staged PC.

    Each round the script:
      1. Searches for every update that is not installed and not hidden
         (normal, optional/"BrowseOnly" preview updates and drivers).
      2. Downloads and installs them silently.
      3. If a reboot is required, registers a scheduled task that runs this
         script again as SYSTEM at the next startup, then reboots.
      4. Stops when a search finds nothing new, removes the scheduled task
         and writes a summary to the log.

    The script copies itself to C:\ProgramData\WUAutomation so that it keeps
    working after a reboot even if it was started from a USB stick or network share.

    Progress is logged to C:\ProgramData\WUAutomation\WUAutomation.log.
    Follow it live with:
        Get-Content C:\ProgramData\WUAutomation\WUAutomation.log -Wait

.PARAMETER Source
    Where to get updates from:
      MicrosoftUpdate (default) - Microsoft Update online, includes updates for
                                  other Microsoft products (Office, .NET, ...).
                                  Bypasses WSUS so optional updates are offered.
      WindowsUpdate             - Windows Update online only (bypasses WSUS).
      Default                   - Whatever the PC is configured for (WSUS/Intune policy).

.PARAMETER SkipOptional
    Do not install optional ("BrowseOnly") updates such as preview cumulative updates.

.PARAMETER SkipDrivers
    Do not install driver updates.

.PARAMETER IncludeFeatureUpdates
    Also install feature updates / version upgrades (e.g. Windows 11 24H2 -> 25H2).
    Skipped by default because staging normally targets a fixed Windows version.

.PARAMETER MaxReboots
    Safety limit on the number of automatic reboots. Default 8.

.PARAMETER NoReboot
    Install what can be installed but never reboot automatically.

.EXAMPLE
    .\Invoke-WindowsUpdateLoop.ps1
    Installs everything (normal + optional + drivers) from Microsoft Update,
    rebooting as often as needed.

.EXAMPLE
    .\Invoke-WindowsUpdateLoop.ps1 -SkipDrivers -MaxReboots 5

.NOTES
    Run from an elevated PowerShell prompt:
        powershell.exe -ExecutionPolicy Bypass -File .\Invoke-WindowsUpdateLoop.ps1
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('MicrosoftUpdate', 'WindowsUpdate', 'Default')]
    [string]$Source = 'MicrosoftUpdate',

    [switch]$SkipOptional,

    [switch]$SkipDrivers,

    [switch]$IncludeFeatureUpdates,

    [ValidateRange(1, 50)]
    [int]$MaxReboots = 8,

    [switch]$NoReboot,

    # Internal: set by the scheduled task when resuming after a reboot.
    [switch]$Resumed
)

$ErrorActionPreference = 'Stop'

# --- Constants ---------------------------------------------------------------
$WorkDir            = Join-Path $env:ProgramData 'WUAutomation'
$LogFile            = Join-Path $WorkDir 'WUAutomation.log'
$StateFile          = Join-Path $WorkDir 'state.json'
$ScriptCopy         = Join-Path $WorkDir 'Invoke-WindowsUpdateLoop.ps1'
$TaskName           = 'WUAutomation-ResumeAfterReboot'
$MicrosoftUpdateId  = '7971f918-a847-4430-9279-4a52d1efe18d'
$UpgradesCategoryId = '3689bdc8-b205-4af4-8d4a-a63924c5e9d5'
$MaxPassesPerBoot   = 5

# --- Helpers -----------------------------------------------------------------
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

function Get-State {
    if (Test-Path $StateFile) {
        try {
            $s = Get-Content $StateFile -Raw | ConvertFrom-Json
            return @{
                RebootCount = [int]$s.RebootCount
                FailedIds   = @($s.FailedIds | Where-Object { $_ })
                Installed   = @($s.Installed | Where-Object { $_ })
                StartedAt   = [string]$s.StartedAt
            }
        } catch {
            Write-Log "State file unreadable, starting fresh: $_" 'WARN'
        }
    }
    return @{ RebootCount = 0; FailedIds = @(); Installed = @(); StartedAt = (Get-Date).ToString('s') }
}

function Save-State($State) {
    $State | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

function Test-PendingReboot {
    try {
        if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { return $true }
    } catch { }
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )
    foreach ($k in $keys) { if (Test-Path $k) { return $true } }
    return $false
}

function Get-ResumeArguments {
    # Rebuild the original parameters so the resumed run behaves the same.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$ScriptCopy`"")
    foreach ($p in $script:BoundParams.GetEnumerator()) {
        if ($p.Key -eq 'Resumed') { continue }
        if ($p.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($p.Value.IsPresent) { $argList += "-$($p.Key)" }
        } else {
            $argList += "-$($p.Key)", "`"$($p.Value)`""
        }
    }
    $argList += '-Resumed'
    return ($argList -join ' ')
}

function Register-ResumeTask {
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (Get-ResumeArguments)
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT1M'   # give networking a moment after boot
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 6) -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Force | Out-Null
    Write-Log "Scheduled task '$TaskName' registered to resume after reboot."
}

function Unregister-ResumeTask {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log "Scheduled task '$TaskName' removed."
    }
}

function Complete-Run($State, [string]$Reason) {
    Unregister-ResumeTask
    Write-Log "===== FINISHED: $Reason ====="
    Write-Log ("Reboots performed: {0}. Updates installed: {1}." -f $State.RebootCount, $State.Installed.Count)
    foreach ($t in $State.Installed) { Write-Log "  installed: $t" }
    if ($State.FailedIds.Count -gt 0) {
        Write-Log ("{0} update(s) failed and were skipped - see log above for details." -f $State.FailedIds.Count) 'WARN'
    }
    Remove-Item $StateFile -ErrorAction SilentlyContinue
}

function Invoke-Reboot($State) {
    if ($NoReboot) {
        Write-Log 'A reboot is required but -NoReboot was specified. Reboot manually and run the script again.' 'WARN'
        Unregister-ResumeTask
        Save-State $State
        exit 3010
    }
    if ($State.RebootCount -ge $MaxReboots) {
        Complete-Run $State "reached MaxReboots ($MaxReboots) - a reboot is still pending, please check manually"
        exit 1
    }
    $State.RebootCount++
    Save-State $State
    Register-ResumeTask
    Write-Log ("Rebooting (reboot {0} of max {1})..." -f $State.RebootCount, $MaxReboots)
    Restart-Computer -Force
    exit 0
}

function Register-MicrosoftUpdate {
    try {
        $sm = New-Object -ComObject Microsoft.Update.ServiceManager
        $registered = $false
        foreach ($svc in $sm.Services) { if ($svc.ServiceID -eq $MicrosoftUpdateId) { $registered = $true } }
        if (-not $registered) {
            $sm.ClientApplicationID = 'WUAutomation'
            # 7 = AllowPendingRegistration + AllowOnlineRegistration + RegisterServiceWithAU
            $sm.AddService2($MicrosoftUpdateId, 7, '') | Out-Null
            Write-Log 'Registered Microsoft Update service (updates for other Microsoft products).'
        }
    } catch {
        Write-Log "Could not register Microsoft Update service, falling back to Windows Update: $_" 'WARN'
        $script:Source = 'WindowsUpdate'
    }
}

function Set-ServerSelection($ComObject) {
    switch ($Source) {
        'MicrosoftUpdate' { $ComObject.ServerSelection = 3; $ComObject.ServiceID = $MicrosoftUpdateId }
        'WindowsUpdate'   { $ComObject.ServerSelection = 2 }
        default           { $ComObject.ServerSelection = 0 }
    }
}

function Find-Updates($Session, $State) {
    $searcher = $Session.CreateUpdateSearcher()
    Set-ServerSelection $searcher

    $criteria = "IsInstalled=0 and IsHidden=0 and Type='Software'"
    if (-not $SkipDrivers) { $criteria += " or IsInstalled=0 and IsHidden=0 and Type='Driver'" }

    # Network may not be up yet right after a reboot - retry a few times.
    $result = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Write-Log "Searching for updates (source: $Source, attempt $attempt)..."
            $result = $searcher.Search($criteria)
            break
        } catch {
            Write-Log ("Search failed: {0}" -f $_.Exception.Message) 'WARN'
            if ($attempt -eq 5) { throw }
            Start-Sleep -Seconds 60
        }
    }

    $seen = @{}
    $selected = @()
    foreach ($u in $result.Updates) {
        if ($seen.ContainsKey($u.Identity.UpdateID)) { continue }
        $seen[$u.Identity.UpdateID] = $true

        $isUpgrade = $false
        foreach ($c in $u.Categories) { if ($c.CategoryID -eq $UpgradesCategoryId) { $isUpgrade = $true } }

        $skip = $null
        if ($State.FailedIds -contains $u.Identity.UpdateID)     { $skip = 'failed earlier' }
        elseif ($isUpgrade -and -not $IncludeFeatureUpdates)     { $skip = 'feature update' }
        elseif ($u.BrowseOnly -and $SkipOptional)                { $skip = 'optional' }
        elseif ($u.InstallationBehavior.CanRequestUserInput)     { $skip = 'requires user input' }

        if ($skip) {
            Write-Log "  skipping ($skip): $($u.Title)"
            continue
        }
        $selected += $u
    }
    return $selected
}

function Install-Updates($Session, $Updates, $State) {
    # Updates needing exclusive handling (e.g. servicing stack) must be installed on their own.
    $exclusive = @($Updates | Where-Object { $_.InstallationBehavior.Impact -eq 2 })
    if ($exclusive.Count -gt 0) {
        Write-Log "Installing exclusive update on its own first: $($exclusive[0].Title)"
        $Updates = @($exclusive[0])
    }

    $collection = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $Updates) {
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        $kind = if ($u.BrowseOnly) { 'optional' } else { 'normal' }
        Write-Log "  queued ($kind): $($u.Title)"
        $collection.Add($u) | Out-Null
    }

    Write-Log "Downloading $($collection.Count) update(s)..."
    $downloader = $Session.CreateUpdateDownloader()
    Set-ServerSelection $downloader
    $downloader.Updates = $collection
    try { $downloader.Download() | Out-Null }
    catch { Write-Log "Download reported an error: $($_.Exception.Message)" 'WARN' }

    $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $collection) {
        if ($u.IsDownloaded) { $toInstall.Add($u) | Out-Null }
        else {
            Write-Log "  download failed: $($u.Title)" 'ERROR'
            $State.FailedIds += $u.Identity.UpdateID
        }
    }
    if ($toInstall.Count -eq 0) { return $false }

    Write-Log "Installing $($toInstall.Count) update(s)... (this can take a while)"
    $installer = $Session.CreateUpdateInstaller()
    $installer.ForceQuiet = $true
    $installer.Updates = $toInstall
    $result = $installer.Install()

    $resultNames = @{ 0 = 'NotStarted'; 1 = 'InProgress'; 2 = 'Succeeded'; 3 = 'SucceededWithErrors'; 4 = 'Failed'; 5 = 'Aborted' }
    for ($i = 0; $i -lt $toInstall.Count; $i++) {
        $u = $toInstall.Item($i)
        $r = $result.GetUpdateResult($i)
        $code = $resultNames[[int]$r.ResultCode]
        if ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3) {
            Write-Log "  $code : $($u.Title)"
            $State.Installed += $u.Title
        } else {
            Write-Log ("  {0} (0x{1:X8}): {2}" -f $code, $r.HResult, $u.Title) 'ERROR'
            $State.FailedIds += $u.Identity.UpdateID
        }
    }
    Save-State $State
    return [bool]$result.RebootRequired
}

# --- Main --------------------------------------------------------------------
$script:BoundParams = $PSBoundParameters

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
if ($PSCommandPath -and ($PSCommandPath -ne $ScriptCopy)) {
    Copy-Item -Path $PSCommandPath -Destination $ScriptCopy -Force
}

if (-not $Resumed) {
    # Fresh start: forget any leftovers from an earlier, interrupted run.
    Remove-Item $StateFile -ErrorAction SilentlyContinue
}
$state = Get-State
Write-Log ("===== Windows Update run on {0} {1} (reboots so far: {2}) =====" -f $env:COMPUTERNAME, $(if ($Resumed) { '- resumed after reboot' } else { '- started' }), $state.RebootCount)

try {
    $wu = Get-Service wuauserv
    if ($wu.StartType -eq 'Disabled') { throw 'The Windows Update service (wuauserv) is disabled.' }
    if ($wu.Status -ne 'Running') { Start-Service wuauserv }

    if ($Source -eq 'MicrosoftUpdate') { Register-MicrosoftUpdate }

    if (Test-PendingReboot) {
        Write-Log 'A reboot is already pending before searching - rebooting first.'
        Invoke-Reboot $state
    }

    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'WUAutomation'

    for ($pass = 1; $pass -le $MaxPassesPerBoot; $pass++) {
        $updates = @(Find-Updates $session $state)
        if ($updates.Count -eq 0) {
            if (Test-PendingReboot) { Invoke-Reboot $state }
            Complete-Run $state 'no more updates available'
            exit 0
        }
        Write-Log "Found $($updates.Count) update(s) to install (pass $pass)."

        $rebootRequired = Install-Updates $session $updates $state
        if ($rebootRequired -or (Test-PendingReboot)) { Invoke-Reboot $state }
        # No reboot needed: search again right away, installing updates can unlock new ones.
    }

    Write-Log "Reached $MaxPassesPerBoot passes without a reboot - rebooting to make sure everything is applied."
    Invoke-Reboot $state
} catch {
    Write-Log "Unexpected error: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    Save-State $state
    # Keep the resume task (if any) so a manual reboot continues the run.
    exit 1
}
