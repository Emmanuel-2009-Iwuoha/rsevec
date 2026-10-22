@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "SELF=%~f0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$identity=[Security.Principal.WindowsIdentity]::GetCurrent(); $principal=New-Object Security.Principal.WindowsPrincipal($identity); if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { try { Start-Process -FilePath $env:SELF -WorkingDirectory (Split-Path -Parent $env:SELF) -Verb RunAs -WindowStyle Normal; exit 10 } catch { Write-Error ('Could not start run.cmd as administrator: ' + $_.Exception.Message); exit 1 } }"
if errorlevel 10 exit /b 0
if errorlevel 1 (
    echo Administrator access could not be started. If you canceled the UAC prompt, run run.cmd again and approve it.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$path=$env:SELF; $lines=[IO.File]::ReadAllLines($path); $ps=New-Object 'System.Collections.Generic.List[string]'; $section=''; foreach($line in $lines){ if($line -ceq '::PS_BEGIN'){$section='PS';continue}; if($line -ceq '::PS_END'){$section='';break}; if($section -eq 'PS'){$ps.Add($line)} }; Set-Location -LiteralPath (Split-Path -Parent $path); try { & ([scriptblock]::Create([string]::Join([Environment]::NewLine,$ps))) } catch { Write-Error ('Installation failed: ' + $_.Exception.Message); exit 1 }"
if errorlevel 1 (
    echo Installation failed. See the error above.
    pause
    exit /b 1
)

echo The program has been successfully installed. Enjoy!
pause >nul
exit /b 0

::PS_BEGIN
$ErrorActionPreference = 'Stop'
$ScriptDir = (Get-Location).Path
$InstallDir = Join-Path $env:WINDIR 'System32'
$SourceExe = Join-Path $ScriptDir 'dist\rsevec.exe'
$AppExe = Join-Path $InstallDir 'rsevec.exe'
$WatchdogPath = Join-Path $InstallDir 'watchdog.bat'
$VbsPath = Join-Path $InstallDir 'run_tserver_hidden.vbs'

if (-not (Test-Path -LiteralPath $SourceExe -PathType Leaf)) {
    throw "Could not find rsevec.exe in the dist folder: $SourceExe"
}

Copy-Item -LiteralPath $SourceExe -Destination $AppExe -Force

@'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "APP_DIR=%~dp0"
set "APP_EXE=%APP_DIR%rsevec.exe"
set "APP_NAME=rsevec.exe"
set "LOG_FILE=%APP_DIR%watchdog_log.txt"
set "LOCK_DIR=%APP_DIR%watchdog.lock"
set "RESTART_DELAY_SECONDS=5"

cd /d "%APP_DIR%"
md "%LOCK_DIR%" 2>nul
if errorlevel 1 (
    tasklist /FI "IMAGENAME eq %APP_NAME%" 2>nul | find /I "%APP_NAME%" >nul
    if not errorlevel 1 exit /b 0
    rd "%LOCK_DIR%" 2>nul
    md "%LOCK_DIR%" 2>nul
    if errorlevel 1 exit /b 0
)

echo [%date% %time%] TServer watchdog started.>>"%LOG_FILE%"
:RUN_LOOP
if not exist "%LOCK_DIR%" goto :EOF
if not exist "%APP_EXE%" (
    echo [%date% %time%] rsevec.exe is missing; watchdog stopped.>>"%LOG_FILE%"
    rd "%LOCK_DIR%" 2>nul
    goto :EOF
)
echo [%date% %time%] Starting rsevec.exe...>>"%LOG_FILE%"
start "" /wait "%APP_EXE%"
if not exist "%LOCK_DIR%" goto :EOF
echo [%date% %time%] TServer exited; restarting in %RESTART_DELAY_SECONDS% seconds.>>"%LOG_FILE%"
ping 127.0.0.1 -n %RESTART_DELAY_SECONDS% >nul
goto RUN_LOOP
'@ | Set-Content -LiteralPath $WatchdogPath -Encoding ASCII

@'
Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")
strScriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
strWatchdogBat = """" & strScriptDir & "\watchdog.bat" & """"
objShell.Run strWatchdogBat, 0, False
'@ | Set-Content -LiteralPath $VbsPath -Encoding ASCII

$VbsLauncher = $VbsPath
$TaskAction = New-ScheduledTaskAction -Execute 'wscript.exe' `
    -Argument ('"{0}"' -f $VbsLauncher) -WorkingDirectory $InstallDir
$Principal = New-ScheduledTaskPrincipal `
    -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive -RunLevel Highest
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -MultipleInstances IgnoreNew

$AutoStartTriggers = @(
    (New-ScheduledTaskTrigger -AtStartup),
    (New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name))
)
Register-ScheduledTask -TaskName 'RemoteDashboardAutoStart' `
    -Action $TaskAction -Trigger $AutoStartTriggers `
    -Principal $Principal -Settings $Settings `
    -Description 'Starts TServer for the current user at startup or sign-in.' `
    -Force | Out-Null

$WakeQuery = @'
<QueryList>
  <Query Id="0" Path="System">
    <Select Path="System">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select>
  </Query>
</QueryList>
'@
$EventTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger `
    -Namespace Root/Microsoft/Windows/TaskScheduler
$EventTrigger = New-CimInstance -CimClass $EventTriggerClass -ClientOnly
$EventTrigger.Subscription = $WakeQuery
$EventTrigger.Enabled = $true
$EventTrigger.Delay = 'PT10S'

Register-ScheduledTask -TaskName 'RemoteDashboardWakeResume' `
    -Action $TaskAction -Trigger $EventTrigger `
    -Principal $Principal -Settings $Settings `
    -Description 'Starts TServer after this computer resumes from sleep or hibernation.' `
    -Force | Out-Null

Start-ScheduledTask -TaskName 'RemoteDashboardAutoStart'
::PS_END
