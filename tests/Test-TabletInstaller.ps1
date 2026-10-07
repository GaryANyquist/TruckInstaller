<#
  Tests for Install-Tablets.ps1.
    .\tests\Test-TabletInstaller.ps1                fast checks of the parsing and file-finding code, and (if a tablet is
                                                    plugged in) a dry run and a "leave it alone" run that change nothing
    .\tests\Test-TabletInstaller.ps1 -Integration   also reinstalls the Kitchen Display app (same version, data kept),
                                                    tries the permission grant and a file copy, then restores the tablet
#>
param([switch]$Integration)
$ErrorActionPreference = 'Stop'
$installer = Join-Path (Split-Path $PSScriptRoot -Parent) 'Install-Tablets.ps1'
$script:fails = 0
function Check([string]$Name, $Got, $Want) {
    if ($Got -eq $Want) { Write-Host "ok   $Name -> $Got" } else { $script:fails++; Write-Host "FAIL $Name`n   got  $Got`n   want $Want" -ForegroundColor Red }
}
function CheckTrue([string]$Name, $Condition) { Check $Name ([bool]$Condition) $true }

. $installer   # loads the functions only

# ---- versions and files
Check 'version from a register file name' (Get-ApkVersion 'ComfortablyYum-2.1.5-live.apk').ToString() '2.1.5'
Check 'version from a kitchen file name' (Get-ApkVersion 'KitchenDisplay-1.1.1.apk').ToString() '1.1.1'
Check 'no version in the name' (Get-ApkVersion 'app.apk') $null

$tmp = Join-Path $env:TEMP ('tabinst-' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp | Out-Null
foreach ($n in 'ComfortablyYum-2.0.9-live.apk', 'ComfortablyYum-2.1.5-live.apk', 'ComfortablyYum-2.1.10-live.apk', 'ComfortablyYum-2.1.5-sandbox.apk', 'KitchenDisplay-1.0.3.apk', 'KitchenDisplay-1.1.0.apk') {
    Set-Content -Path (Join-Path $tmp $n) -Value 'x'
}
# copies without the real build folders, so only the scratch folder is searched
$reg = @{ Patterns = $script:Apps.Register.Patterns; Dirs = @() }
$kit = @{ Patterns = $script:Apps.Kitchen.Patterns; Dirs = @() }
Check 'newest register APK is picked by version, not by name' (Find-LatestApk $reg '' @($tmp)).Name 'ComfortablyYum-2.1.10-live.apk'
Check 'a sandbox build is never picked' ((Find-LatestApk $reg '' @($tmp)).Name -like '*sandbox*') $false
# the register app was renamed: files under the new name are found, and the highest version wins across both names
Set-Content -Path (Join-Path $tmp 'AnnawareCashRegister-2.1.6-live.apk') -Value 'x'
Check 'the renamed register APK is found and wins on version' (Find-LatestApk $reg '' @($tmp)).Name 'ComfortablyYum-2.1.10-live.apk'
Remove-Item (Join-Path $tmp 'ComfortablyYum-2.1.10-live.apk')
Check 'with the old 2.1.10 gone, the renamed 2.1.6 beats the old 2.1.5' (Find-LatestApk $reg '' @($tmp)).Name 'AnnawareCashRegister-2.1.6-live.apk'
Check 'newest kitchen APK' (Find-LatestApk $kit '' @($tmp)).Name 'KitchenDisplay-1.1.0.apk'
Check 'an explicit file wins' (Find-LatestApk $reg (Join-Path $tmp 'ComfortablyYum-2.0.9-live.apk') @()).Name 'ComfortablyYum-2.0.9-live.apk'
Check 'an explicit file that is missing gives nothing' (Find-LatestApk $reg (Join-Path $tmp 'nope.apk') @()) $null
Remove-Item $tmp -Recurse -Force

# ---- adb output
$ok = ConvertFrom-InstallOutput "Performing Streamed Install`nSuccess"
CheckTrue 'install: success is recognised' $ok.Success
foreach ($c in 'INSTALL_FAILED_UPDATE_INCOMPATIBLE', 'INSTALL_FAILED_VERSION_DOWNGRADE', 'INSTALL_FAILED_USER_RESTRICTED', 'INSTALL_FAILED_INSUFFICIENT_STORAGE', 'INSTALL_FAILED_OLDER_SDK') {
    $r = ConvertFrom-InstallOutput "adb: failed to install x.apk: Failure [${c}: detail]"
    Check "install: $c is recognised" $r.Code $c
    CheckTrue "install: $c has advice" ($r.Advice.Length -gt 20 -and -not $r.Success)
}
CheckTrue 'install: an incompatible-signature failure says nothing was uninstalled' ((ConvertFrom-InstallOutput 'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: x]').Advice -match 'NOT removed')
CheckTrue 'install: unknown text is passed on' ((ConvertFrom-InstallOutput 'weird thing').Advice -match 'weird thing')
CheckTrue 'install: empty output is not success' (-not (ConvertFrom-InstallOutput '').Success)

$list = "List of devices attached`nHA2MHPGR   device product:TB336FU model:TB336FU device:TB336FU transport_id:1`nZZ99   unauthorized transport_id:2`nOFF1   offline`n`n* daemon started successfully"
$d = @(ConvertFrom-AdbDevices $list)
Check 'devices: three found' $d.Count 3
Check 'devices: serial' $d[0].Serial 'HA2MHPGR'
Check 'devices: state' $d[0].State 'device'
Check 'devices: model' $d[0].Model 'TB336FU'
Check 'devices: unauthorized is kept apart' $d[1].State 'unauthorized'
Check 'devices: offline' $d[2].State 'offline'
Check 'devices: nothing connected' @(ConvertFrom-AdbDevices "List of devices attached`n`n").Count 0
Check 'version name from dumpsys' (Get-VersionNameFromDumpsys "Packages:`n  Package [x] (1):`n    versionCode=1 minSdk=28`n    versionName=2.1.5`n    flags=[ ]") '2.1.5'
Check 'version name when not installed' (Get-VersionNameFromDumpsys '') $null

# ---- with the real tablet
$script:Adb = Find-Adb
$tablet = $null
if ($script:Adb) { $tablet = @(ConvertFrom-AdbDevices (Invoke-Adb @('devices', '-l')).Output | Where-Object { $_.State -eq 'device' }) | Select-Object -First 1 }
if (-not $tablet) { Write-Host "`n(no tablet plugged in: skipping the tests that need one)" -ForegroundColor Yellow }
else {
    Write-Host "`n--- with the tablet $($tablet.Model) ($($tablet.Serial))"
    $before = @{
        Reg = Get-InstalledVersion $tablet.Serial 'com.davcotech.foodtruckpos'
        Kit = Get-InstalledVersion $tablet.Serial 'com.davcotech.kitchendisplay'
    }
    $run = { param($extra) & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer @extra -NoPause 2>&1 | Out-String }

    $dry = & $run @('-DryRun', '-Role', 'Kitchen')
    CheckTrue 'dry run finds the tablet' ($dry -match 'Found tablet')
    CheckTrue 'dry run reports no problems' ($dry -match 'No problems found')
    CheckTrue 'dry run ends with a summary' ($dry -match 'TABLET SETUP SUMMARY')
    Check 'dry run changed nothing (kitchen version)' (Get-InstalledVersion $tablet.Serial 'com.davcotech.kitchendisplay') $before.Kit

    $skip = & $run @('-Role', 'Register', '-NoLaunch', '-Yes')
    CheckTrue 'an app that is already current is left alone' ($skip -match 'already at version')
    CheckTrue 'it notices Developer options are on' ($skip -match 'Developer options')
    Check 'nothing changed (register version)' (Get-InstalledVersion $tablet.Serial 'com.davcotech.foodtruckpos') $before.Reg

    $none = & $run @('-Yes')
    CheckTrue 'with no role and -Yes it asks you to say which tablet is which' ($none -match 'Say which tablet is which')
    $bad = & $run @('-RegisterSerial', 'NOSUCHTABLET', '-Yes')
    CheckTrue 'an unknown serial is reported' ($bad -match 'No tablet with serial NOSUCHTABLET')

    if ($Integration) {
        Write-Host "`n--- integration: reinstall the Kitchen Display app over itself, then restore"
        $micBefore = (Invoke-Adb @('shell', 'dumpsys', 'package', 'com.davcotech.kitchendisplay') $tablet.Serial).Output -match 'RECORD_AUDIO: granted=true'
        $out = & $run @('-Role', 'Kitchen', '-Reinstall', '-GrantPermissions', '-NoLaunch', '-Yes')
        CheckTrue 'reinstall reports success' ($out -match 'installed, now version')
        CheckTrue 'reinstall reports no problems' ($out -match 'No problems found')
        Check 'kitchen app version is unchanged' (Get-InstalledVersion $tablet.Serial 'com.davcotech.kitchendisplay') $before.Kit
        $micAfter = (Invoke-Adb @('shell', 'dumpsys', 'package', 'com.davcotech.kitchendisplay') $tablet.Serial).Output -match 'RECORD_AUDIO: granted=true'
        CheckTrue 'the microphone permission was pre-allowed' $micAfter
        if (-not $micBefore) { [void](Invoke-Adb @('shell', 'pm', 'revoke', 'com.davcotech.kitchendisplay', 'android.permission.RECORD_AUDIO') $tablet.Serial); Write-Host '     (restored: microphone permission revoked again)' }

        $f = Join-Path $env:TEMP 'tabinst-test-key.txt'; Set-Content $f 'not a real key'
        Copy-FileToTablet $tablet.Serial $f 'test'
        $ls = (Invoke-Adb @('shell', 'ls', '/sdcard/Download/tabinst-test-key.txt') $tablet.Serial).Output
        CheckTrue 'a file was copied to the Download folder' ($ls -match 'tabinst-test-key.txt' -and $ls -notmatch 'No such file')
        [void](Invoke-Adb @('shell', 'rm', '/sdcard/Download/tabinst-test-key.txt') $tablet.Serial)
        Remove-Item $f -Force
        Write-Host '     (cleaned up: test file removed from the tablet)'
    }
}

Write-Host ''
if ($script:fails -eq 0) { Write-Host 'All tablet installer checks passed.' -ForegroundColor Green; exit 0 }
Write-Host "$script:fails FAILED" -ForegroundColor Red; exit 1
