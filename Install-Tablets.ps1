<#
.SYNOPSIS
  Installs the Comfortably Yum register app and the Kitchen Display app on Android tablets plugged into this PC.

.DESCRIPTION
  Uses adb (Android platform-tools) over a USB cable. It finds adb (and downloads it if needed), finds the newest
  APK files, installs or updates the apps (an update keeps the app's data), and can pre-allow the permissions the
  apps need, copy key and settings files to the tablet's Download folder, and switch Developer options off.

  It never uninstalls an app (that would erase its sales and settings).

  On each tablet first: Settings > About tablet > tap "Build number" 7 times, then Settings > System > Developer options >
  turn on USB debugging. Plug in the cable, and tap Allow on the tablet's "Allow USB debugging?" box.
  The register tablet must have Developer options turned OFF again afterwards (use -TurnOffDeveloperOptions).

.EXAMPLE
  .\Install-Tablets.ps1                                  asks what each connected tablet is
  .\Install-Tablets.ps1 -Role Register -GrantPermissions -TurnOffDeveloperOptions
  .\Install-Tablets.ps1 -RegisterSerial ABC123 -KitchenSerial DEF456 -Yes
#>
[CmdletBinding()]
param(
    [string]$RegisterApk = '',
    [string]$KitchenApk = '',
    [string]$RegisterSerial = '',
    [string]$KitchenSerial = '',
    [ValidateSet('', 'Register', 'Kitchen', 'Both')][string]$Role = '',
    [string]$AdbPath = '',
    [string]$PcAddress = '',
    [string]$WixKeyFile = '',
    [string]$SettingsBackup = '',
    [int]$WaitSeconds = 0,
    [switch]$GrantPermissions,
    [switch]$TurnOffDeveloperOptions,
    [switch]$SetKitchenAsHome,
    [switch]$Reinstall,
    [switch]$NoLaunch,
    [switch]$NoDownload,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Adb = $null
$script:Problems = New-Object System.Collections.Generic.List[string]
$script:Report = New-Object System.Collections.Generic.List[string]
$script:ToolsDir = Join-Path $PSScriptRoot 'tools'

$script:Apps = @{
    Register = @{
        Name        = 'Register (Annaware CashRegister)'
        Package     = 'com.davcotech.foodtruckpos'
        Patterns    = @('AnnawareCashRegister-*-live.apk', 'ComfortablyYum-*-live.apk')
        Dirs        = @('C:\Source\CashRegister\dist-apk')
        Permissions = @('android.permission.BLUETOOTH_CONNECT', 'android.permission.BLUETOOTH_SCAN', 'android.permission.ACCESS_FINE_LOCATION', 'android.permission.READ_PHONE_STATE', 'android.permission.RECORD_AUDIO')
    }
    Kitchen  = @{
        Name        = 'Annaware Kitchen Display'
        Package     = 'com.davcotech.kitchendisplay'
        Patterns    = @('KitchenDisplay-*.apk')
        Dirs        = @('C:\Source\KitchenDisplay\app\dist-apk')
        Permissions = @('android.permission.RECORD_AUDIO')
    }
}

# ---------------------------------------------------------------- helpers (also used by the tests)

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'STEP' { 'Cyan' } 'OK' { 'Green' } default { 'Gray' } }
    Write-Host ('{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message) -ForegroundColor $color
}

function Add-Problem([string]$Text) { $script:Problems.Add($Text); Write-Log $Text 'ERROR' }

# 1.2.3 out of "ComfortablyYum-2.1.5-live.apk"; $null if there is none.
function Get-ApkVersion([string]$FileName) {
    if ($FileName -match '(\d+)\.(\d+)\.(\d+)') { return [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3]) }
    $null
}

# The newest APK for an app: the file you named, or the highest version found next to this script or in the build folder.
function Find-LatestApk {
    param([hashtable]$App, [string]$Explicit, [string[]]$ExtraDirs = @())
    if ($Explicit) { if (Test-Path $Explicit) { return Get-Item $Explicit } else { return $null } }
    $dirs = @($PSScriptRoot, (Join-Path $PSScriptRoot 'apk')) + $ExtraDirs + $App.Dirs
    $found = @()
    foreach ($d in $dirs) {
        if (-not ($d -and (Test-Path $d))) { continue }
        foreach ($pattern in $App.Patterns) { $found += @(Get-ChildItem -Path $d -Filter $pattern -File -ErrorAction SilentlyContinue) }
    }
    if ($found.Count -eq 0) { return $null }
    $found | Sort-Object @{ Expression = { Get-ApkVersion $_.Name }; Descending = $true }, @{ Expression = { $_.LastWriteTime }; Descending = $true } | Select-Object -First 1
}

# What "adb install" printed, in plain words.
function ConvertFrom-InstallOutput([string]$Text) {
    if ($Text -match '(?m)^\s*Success\b') { return [pscustomobject]@{ Success = $true; Code = ''; Advice = '' } }
    $code = ''
    if ($Text -match '\[(INSTALL_[A-Z_]+)') { $code = $Matches[1] } elseif ($Text -match '(INSTALL_[A-Z_]+)') { $code = $Matches[1] }
    $advice = switch ($code) {
        'INSTALL_FAILED_UPDATE_INCOMPATIBLE' { 'A copy of this app signed with a different key is already on the tablet. It was NOT removed: uninstalling erases its sales and settings. Back up first (register: Settings > Backup), then uninstall by hand if you are sure.' }
        'INSTALL_FAILED_VERSION_DOWNGRADE' { 'The tablet already has a newer version. Nothing was changed.' }
        'INSTALL_FAILED_USER_RESTRICTED' { 'The tablet refused the install over USB. In Developer options turn on "Install via USB" (and "USB debugging (Security settings)" if shown), and look for a prompt on the tablet screen.' }
        'INSTALL_FAILED_INSUFFICIENT_STORAGE' { 'The tablet is out of storage space. Free some space and try again.' }
        'INSTALL_FAILED_OLDER_SDK' { 'This tablet runs an Android version that is too old for the app (it needs Android 9 or newer).' }
        'INSTALL_PARSE_FAILED_NOT_APK' { 'The file is not a valid APK. It may be damaged; copy it again.' }
        'INSTALL_FAILED_ALREADY_EXISTS' { 'The app is already installed.' }
        default { if ($Text.Trim()) { 'Android said: ' + ($Text.Trim() -replace '\s+', ' ') } else { 'No answer from the tablet.' } }
    }
    [pscustomobject]@{ Success = $false; Code = $code; Advice = $advice }
}

# Lines of "adb devices -l" as objects. State is "device" when the tablet is ready, "unauthorized" when it is waiting for you to tap Allow.
function ConvertFrom-AdbDevices([string]$Text) {
    $out = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^List of devices' -or -not $line.Trim() -or $line -match '^\*') { continue }
        if ($line -match '^(\S+)\s+(device|unauthorized|offline|recovery|sideload|no permissions)\b\s*(.*)$') {
            $serial = $Matches[1]; $state = $Matches[2]; $rest = $Matches[3]
            $model = ''
            if ($rest -match 'model:(\S+)') { $model = $Matches[1] }
            $out += [pscustomobject]@{ Serial = $serial; State = $state; Model = $model }
        }
    }
    $out
}

function Get-VersionNameFromDumpsys([string]$Text) {
    if ($Text -match '(?m)^\s*versionName=(\S+)') { return $Matches[1] }
    $null
}

# ---------------------------------------------------------------- adb

function Invoke-Adb {
    param([string[]]$ArgList, [string]$Serial = '')
    $full = @()
    if ($Serial) { $full += @('-s', $Serial) }
    $full += $ArgList
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # Windows PowerShell 5.1 turns a program's stderr text into errors otherwise
    try {
        $lines = @(& $script:Adb @full 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
        [pscustomobject]@{ Output = ($lines -join "`n"); ExitCode = $code }
    } finally { $ErrorActionPreference = $old }
}

function Find-Adb {
    $candidates = @()
    if ($AdbPath) { $candidates += $AdbPath }
    $onPath = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }
    if ($env:ANDROID_HOME) { $candidates += (Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe') }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe') }
    $candidates += (Join-Path $script:ToolsDir 'platform-tools\adb.exe')
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    if ($NoDownload) { return $null }
    Write-Log 'adb was not found. Downloading Google''s Android platform-tools (about 7 MB)'
    if ($DryRun) { Write-Log '[dry run] would: download platform-tools-latest-windows.zip from dl.google.com'; return $null }
    $zip = Join-Path ([IO.Path]::GetTempPath()) 'platform-tools-latest-windows.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zip -UseBasicParsing
    New-Item -ItemType Directory -Force -Path $script:ToolsDir | Out-Null
    Expand-Archive -Path $zip -DestinationPath $script:ToolsDir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    $adb = Join-Path $script:ToolsDir 'platform-tools\adb.exe'
    if (Test-Path $adb) { return $adb }
    $null
}

function Get-ReadyDevices {
    $all = @(ConvertFrom-AdbDevices (Invoke-Adb @('devices', '-l')).Output)
    $all
}

function Wait-ForDevices {
    $until = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $devs = @(Get-ReadyDevices)
        if (@($devs | Where-Object { $_.State -eq 'device' }).Count -gt 0) { return $devs }
        if ($WaitSeconds -le 0) { return $devs }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $until)
    @(Get-ReadyDevices)
}

function Get-DeviceProp([string]$Serial, [string]$Name) { ((Invoke-Adb @('shell', 'getprop', $Name) $Serial).Output).Trim() }

function Get-InstalledVersion([string]$Serial, [string]$Package) {
    Get-VersionNameFromDumpsys (Invoke-Adb @('shell', 'dumpsys', 'package', $Package) $Serial).Output
}

function Get-DevSetting([string]$Serial, [string]$Name) { ((Invoke-Adb @('shell', 'settings', 'get', 'global', $Name) $Serial).Output).Trim() }

# ---------------------------------------------------------------- one tablet, one app

function Install-App {
    param([string]$Serial, [string]$Model, [string]$Key, [IO.FileInfo]$Apk)
    $app = $script:Apps[$Key]
    $apkVersion = Get-ApkVersion $Apk.Name
    $installed = Get-InstalledVersion $Serial $app.Package
    $label = "$($app.Name) on $Model ($Serial)"
    Write-Log "$label : installed = $(if ($installed) { $installed } else { 'not installed' }); file = $($Apk.Name)" 'STEP'

    if ($installed -and $apkVersion -and ([version]($installed -replace '[^\d.].*$', '')) -eq $apkVersion -and -not $Reinstall) {
        Write-Log "$label is already at version $installed, leaving it (use -Reinstall to install it again)" 'OK'
        $script:Report.Add("$label : already $installed")
        return $true
    }
    if ($DryRun) { Write-Log "[dry run] would: adb -s $Serial install -r `"$($Apk.FullName)`" ($([int]($Apk.Length / 1MB)) MB, takes a minute or two)"; return $true }

    Write-Log "Installing $($Apk.Name) ($([int]($Apk.Length / 1MB)) MB). This takes a minute or two; do not unplug the tablet"
    $r = Invoke-Adb @('install', '-r', $Apk.FullName) $Serial
    $res = ConvertFrom-InstallOutput $r.Output
    if (-not $res.Success) { Add-Problem "$label : $($res.Advice) [$($res.Code)]"; return $false }
    $now = Get-InstalledVersion $Serial $app.Package
    Write-Log "$label : installed, now version $now" 'OK'
    $script:Report.Add("$label : $(if ($installed) { "updated $installed -> $now" } else { "installed $now" })")
    $true
}

function Grant-AppPermissions {
    param([string]$Serial, [string]$Key)
    $app = $script:Apps[$Key]
    if ($DryRun) { Write-Log "[dry run] would: allow $($app.Permissions.Count) permissions for $($app.Name)"; return }
    $granted = 0
    foreach ($p in $app.Permissions) {
        $r = Invoke-Adb @('shell', 'pm', 'grant', $app.Package, $p) $Serial
        if ($r.ExitCode -eq 0 -and $r.Output -notmatch 'Exception|Unknown permission|not a changeable') { $granted++ }
        else { Write-Log "  could not pre-allow $p (the app will ask for it when needed)" 'WARN' }
    }
    Write-Log "Pre-allowed $granted of $($app.Permissions.Count) permissions for $($app.Name)"
}

function Copy-FileToTablet {
    param([string]$Serial, [string]$Path, [string]$What)
    if (-not (Test-Path $Path)) { Add-Problem "$What file not found: $Path"; return }
    $name = Split-Path $Path -Leaf
    if ($DryRun) { Write-Log "[dry run] would: copy $name to the tablet's Download folder"; return }
    $r = Invoke-Adb @('push', $Path, "/sdcard/Download/$name") $Serial
    if ($r.ExitCode -eq 0) { Write-Log "Copied $name to the tablet's Download folder ($What). Delete it from the tablet after you have used it." 'OK' }
    else { Add-Problem "Could not copy $name to the tablet: $($r.Output)" }
}

# "package/.Activity" out of the last line of "cmd package resolve-activity --brief".
function Get-HomeComponent([string]$Text) {
    foreach ($line in ($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3)) {
        if ($line.Trim() -match '^([A-Za-z0-9_.]+/[A-Za-z0-9_.$]+)$') { return $Matches[1] }
    }
    $null
}

# Makes the Kitchen Display the tablet's Home app, so Android opens it every time the tablet starts (needs app version 1.2.0 or newer).
# The previous Home app is recorded in the summary with the command that puts it back.
function Set-KitchenAsHome {
    param([string]$Serial)
    $pkg = $script:Apps.Kitchen.Package
    $component = "$pkg/.MainActivity"
    if ($DryRun) { Write-Log "[dry run] would: make the Kitchen Display the Home app on $Serial"; return }
    $before = Get-HomeComponent (Invoke-Adb @('shell', 'cmd', 'package', 'resolve-activity', '--brief', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.HOME') $Serial).Output
    if ($before -and $before.StartsWith("$pkg/")) { Write-Log "The Kitchen Display is already the Home app on $Serial" 'OK'; return }
    $candidates = (Invoke-Adb @('shell', 'cmd', 'package', 'query-activities', '--brief', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.HOME') $Serial).Output
    if ($candidates -notmatch [regex]::Escape($pkg)) { Add-Problem "The Kitchen Display on $Serial has no Home entry (it needs version 1.2.0 or newer), so it cannot be made the Home app."; return }
    $r = Invoke-Adb @('shell', 'cmd', 'package', 'set-home-activity', $component) $Serial
    $after = Get-HomeComponent (Invoke-Adb @('shell', 'cmd', 'package', 'resolve-activity', '--brief', '-a', 'android.intent.action.MAIN', '-c', 'android.intent.category.HOME') $Serial).Output
    if ($after -and $after.StartsWith("$pkg/")) {
        Write-Log "The Kitchen Display is now the Home app on $Serial (it opens by itself when the tablet starts)" 'OK'
        $script:Report.Add("HOME $Serial : Kitchen Display is the Home app. To put the old one back: adb -s $Serial shell cmd package set-home-activity $before")
    } else { Add-Problem "Could not make the Kitchen Display the Home app on $Serial ($($r.Output.Trim())). Do it on the tablet: open the app's Settings > Choose Home app." }
}

function Start-App {
    param([string]$Serial, [string]$Key)
    $app = $script:Apps[$Key]
    if ($DryRun) { Write-Log "[dry run] would: open $($app.Name) on the tablet"; return }
    [void](Invoke-Adb @('shell', 'monkey', '-p', $app.Package, '-c', 'android.intent.category.LAUNCHER', '1') $Serial)
}

# ---------------------------------------------------------------- choosing tablets

# Returns a list of @{ Serial; Model; Key } to work on.
function Get-Jobs {
    param($Devices)
    $ready = @($Devices | Where-Object { $_.State -eq 'device' })
    $jobs = @()
    $byName = @{}; foreach ($d in $Devices) { $byName[$d.Serial] = $d }
    $add = { param($serial, $key)
        if (-not $byName.ContainsKey($serial)) { Add-Problem "No tablet with serial $serial is connected."; return }
        if ($byName[$serial].State -ne 'device') { Add-Problem "Tablet $serial is $($byName[$serial].State). Tap Allow on its screen."; return }
        $script:Jobs.Add([pscustomobject]@{ Serial = $serial; Model = $byName[$serial].Model; Key = $key })
    }
    $script:Jobs = New-Object System.Collections.Generic.List[object]
    if ($RegisterSerial -or $KitchenSerial) {
        if ($RegisterSerial) { & $add $RegisterSerial 'Register' }
        if ($KitchenSerial) { & $add $KitchenSerial 'Kitchen' }
        return $script:Jobs
    }
    if ($Role) {
        if ($ready.Count -ne 1) { Add-Problem "-Role needs exactly one connected tablet (found $($ready.Count)). Use -RegisterSerial / -KitchenSerial to say which is which."; return $script:Jobs }
        $s = $ready[0].Serial
        if ($Role -in 'Register', 'Both') { & $add $s 'Register' }
        if ($Role -in 'Kitchen', 'Both') { & $add $s 'Kitchen' }
        return $script:Jobs
    }
    if ($Yes -or $DryRun) {
        if ($ready.Count -eq 1 -and $DryRun) { & $add $ready[0].Serial 'Register' ; return $script:Jobs }
        Add-Problem 'Say which tablet is which with -Role, or -RegisterSerial and -KitchenSerial.'
        return $script:Jobs
    }
    foreach ($d in $ready) {
        $reg = Get-InstalledVersion $d.Serial $script:Apps.Register.Package
        $kit = Get-InstalledVersion $d.Serial $script:Apps.Kitchen.Package
        Write-Host ''
        Write-Host "Tablet: $($d.Model)  serial $($d.Serial)" -ForegroundColor White
        Write-Host "  Register app: $(if ($reg) { $reg } else { 'not installed' })    Kitchen Display app: $(if ($kit) { $kit } else { 'not installed' })"
        $answer = (Read-Host '  What is this tablet?  [R]egister, [K]itchen, [B]oth, [S]kip').Trim().ToUpper()
        switch ($answer) {
            'R' { & $add $d.Serial 'Register' }
            'K' { & $add $d.Serial 'Kitchen' }
            'B' { & $add $d.Serial 'Register'; & $add $d.Serial 'Kitchen' }
            default { Write-Log "Skipping $($d.Serial)" }
        }
    }
    $script:Jobs
}

# ---------------------------------------------------------------- main

function Invoke-Main {
    Write-Log 'Tablet setup starting'
    $script:Adb = Find-Adb
    if (-not $script:Adb) {
        if ($DryRun) { Write-Log '[dry run] stopping here: there is no adb to ask about tablets' } else { Add-Problem 'adb is not available. Install Android platform-tools, or run again without -NoDownload.' }
        return
    }
    Write-Log "Using adb: $script:Adb ($(((Invoke-Adb @('version')).Output -split "`n")[0]))"

    $apks = @{}
    foreach ($k in 'Register', 'Kitchen') {
        $explicit = if ($k -eq 'Register') { $RegisterApk } else { $KitchenApk }
        $apks[$k] = Find-LatestApk $script:Apps[$k] $explicit
        if ($apks[$k]) { Write-Log "$($script:Apps[$k].Name) file: $($apks[$k].FullName)" }
        else { Write-Log "No APK found for $($script:Apps[$k].Name) (looked next to this script, in .\apk and in the build folder)" 'WARN' }
    }

    $devices = @(Wait-ForDevices)
    if ($devices.Count -eq 0) {
        Add-Problem 'No tablet found. Plug it in with a USB data cable, turn on USB debugging (see the help at the top of this script), and set the USB mode to File transfer.'
        return
    }
    foreach ($d in $devices) {
        if ($d.State -eq 'unauthorized') { Write-Log "Tablet $($d.Serial) is waiting for you: tap Allow on its 'Allow USB debugging?' box (tick Always allow), then run this again." 'WARN' }
        elseif ($d.State -ne 'device') { Write-Log "Tablet $($d.Serial) is '$($d.State)' and cannot be used." 'WARN' }
        else { Write-Log "Found tablet $($d.Model) ($($d.Serial))" }
    }

    $jobs = @(Get-Jobs $devices)
    if ($jobs.Count -eq 0) { if ($script:Problems.Count -eq 0) { Write-Log 'Nothing to do.' }; return }

    $registerSerials = @()
    foreach ($j in $jobs) {
        $apk = $apks[$j.Key]
        if (-not $apk) { Add-Problem "No APK for $($script:Apps[$j.Key].Name): pass -$($j.Key)Apk <file>."; continue }
        $sdk = Get-DeviceProp $j.Serial 'ro.build.version.sdk'
        if ($sdk -match '^\d+$' -and [int]$sdk -lt 28) { Add-Problem "Tablet $($j.Serial) runs Android API $sdk; the apps need Android 9 (API 28) or newer."; continue }
        if (-not (Install-App -Serial $j.Serial -Model $j.Model -Key $j.Key -Apk $apk)) { continue }
        if ($GrantPermissions) { Grant-AppPermissions -Serial $j.Serial -Key $j.Key }
        if ($SetKitchenAsHome -and $j.Key -eq 'Kitchen') { Set-KitchenAsHome -Serial $j.Serial }
        if ($j.Key -eq 'Register') {
            $registerSerials += $j.Serial
            if ($WixKeyFile) { Copy-FileToTablet $j.Serial $WixKeyFile 'Wix API key: Settings > Wix menu > Load key from file' }
            if ($SettingsBackup) { Copy-FileToTablet $j.Serial $SettingsBackup 'settings backup: Settings > Backup > Restore settings' }
        }
        if (-not $NoLaunch) { Start-App -Serial $j.Serial -Key $j.Key }
    }

    # Developer options must be off on the register tablet or the live Square reader will not pair.
    foreach ($s in ($registerSerials | Select-Object -Unique)) {
        if ($DryRun) { continue }
        $dev = Get-DevSetting $s 'development_settings_enabled'
        if ($dev -ne '1') { Write-Log "Developer options are off on $s (good for Square)" 'OK'; continue }
        if ($TurnOffDeveloperOptions) {
            Write-Log "Turning Developer options and USB debugging off on $s (the cable stops working for adb after this)"
            [void](Invoke-Adb @('shell', 'settings', 'put', 'global', 'development_settings_enabled', '0') $s)
            [void](Invoke-Adb @('shell', 'settings', 'put', 'global', 'adb_enabled', '0') $s)
        } else {
            $script:Report.Add("REGISTER $s : Developer options are still ON. Turn them off (Settings > System > Developer options > switch at the top) before pairing the Square reader, or run this again with -TurnOffDeveloperOptions.")
            Write-Log "Developer options are still on for register tablet $s. Turn them off before pairing the Square reader (or use -TurnOffDeveloperOptions)." 'WARN'
        }
    }
}

function Write-Summary {
    Write-Host ''
    Write-Host '=========================== TABLET SETUP SUMMARY ===========================' -ForegroundColor White
    foreach ($l in $script:Report) { Write-Host "  $l" }
    $addr = if ($PcAddress) { $PcAddress } else { '<PC address from the truck PC setup>' }
    Write-Host ''
    Write-Host 'Still to do by hand on the tablets:' -ForegroundColor White
    Write-Host '  Register: open Settings and set Business, Tax, Printers, Square, Venmo, Wix menu, and KFDisplay sync'
    Write-Host "            (KFDisplay PC address = $addr , Sync key = the key from the truck PC summary). Manual section 4."
    Write-Host "  Kitchen : on first start type the PC address followed by :8790, for example ${addr}:8790, then Test connection and Save. Manual section 5."
    if (Test-Path 'C:\KFDisplay\tablet-setup.txt') { Write-Host '  The truck PC summary is in C:\KFDisplay\tablet-setup.txt (on the PC).' }
    if ($script:Problems.Count -gt 0) {
        Write-Host ''
        Write-Host 'PROBLEMS:' -ForegroundColor Red
        foreach ($p in $script:Problems) { Write-Host "  ! $p" -ForegroundColor Red }
    } else { Write-Host ''; Write-Host 'No problems found.' -ForegroundColor Green }
    Write-Host '============================================================================' -ForegroundColor White
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-Main } catch { Add-Problem ('Stopped by an error: ' + $_.Exception.Message) }
    Write-Summary
    if (-not $NoPause -and -not $DryRun -and -not $Yes) { Read-Host 'Press Enter to close' | Out-Null }
    if ($script:Problems.Count -gt 0) { exit 1 }
}
