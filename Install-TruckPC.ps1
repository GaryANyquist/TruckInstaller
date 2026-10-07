<#
.SYNOPSIS
  Sets up the truck PC: SQL Server Express, Node.js, Git, the KFDisplay sync service, the Kitchen Display
  server, the KFDisplay database and logins, the KFIDisplay menu board, firewall rules and start-at-boot tasks.

.DESCRIPTION
  Safe to run again: every step checks first and skips what is already done. It never overwrites an existing
  .env file, never drops a database, and never changes an existing SQL login.
  Run it from Install-TruckPC.bat (or an administrator PowerShell). It asks for administrator permission itself.

  Use -DryRun to see what it would do without changing anything (no administrator rights needed).


.PARAMETER KfiDisplayExe
  A KFIDisplay.exe that is already in place (for example on a development PC). It is used as it is and nothing is installed.

.PARAMETER KfiDisplaySource
  Where to get the menu board program: a folder containing KFIDisplay.exe, a .zip of that folder, or the .msi
  from the KFIDisplay installer. If omitted, the script looks next to itself (a "KFIDisplay" folder, .zip or .msi)
  and in C:\Source\KFIDisplay\bin\Release on a development PC.
#>
[CmdletBinding()]
param(
    [string]$SourceRoot = 'C:\Source',
    [string]$ImagesDir = 'C:\images',
    [string]$AppDataDir = 'C:\KFDisplay',
    [string]$KfiDisplaySource = '',
    [string]$KfiDisplayExe = '',
    [string]$SqlInstallerPath = '',
    [string]$SqlInstance = 'SQLEXPRESS',
    [string]$DatabaseName = 'KFDisplay',
    [string]$SyncLogin = 'register_sync',
    [string]$KitchenLogin = 'kitchen_display',
    [string]$GitHubOwner = 'GaryANyquist',
    [switch]$SkipPrerequisites,
    [switch]$SkipSql,
    [switch]$SkipKfiDisplay,
    [switch]$SkipWindowsSetup,
    [switch]$NoStart,
    [switch]$NoAutostart,
    [switch]$NoShortcuts,
    [switch]$DryRun,
    [switch]$NoElevate,
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Problems = New-Object System.Collections.Generic.List[string]
$script:Notes = New-Object System.Collections.Generic.List[string]
$script:LogFile = $null

# ---------------------------------------------------------------- small helpers (also used by the tests)

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'STEP' { 'Cyan' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) { try { Add-Content -Path $script:LogFile -Value $line } catch { } }
}

function Add-Problem([string]$Text) { $script:Problems.Add($Text); Write-Log $Text 'ERROR' }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Runs a native program, logging its output. Windows PowerShell 5.1 turns a program's stderr text (git and npm print
# progress there) into errors when $ErrorActionPreference is Stop, so that is relaxed here. Returns the exit code.
function Invoke-Native {
    param([scriptblock]$Command)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Command 2>&1 | ForEach-Object { Write-Log ("  " + ([string]$_).TrimEnd()) }
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

# Runs $Action unless -DryRun, in which case it only says what it would do.
function Invoke-Change {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) { Write-Log "[dry run] would: $Description"; return $null }
    Write-Log $Description
    & $Action
}

# 24 random bytes as URL-safe base64: 32 characters, what the sync service's own make-key tool prints.
function New-SyncKey {
    $b = New-Object byte[] 24
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($b); $rng.Dispose()
    [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# Fills KEY=value lines of an .env template. A key that is not in the template is added at the end.
function Set-EnvValues {
    param([string]$Template, [hashtable]$Values)
    $text = $Template
    foreach ($k in $Values.Keys) {
        $v = [string]$Values[$k]
        $pattern = '(?m)^' + [regex]::Escape($k) + '=.*$'
        if ([regex]::IsMatch($text, $pattern)) {
            $text = [regex]::Replace($text, $pattern, ($k + '=' + $v.Replace('$', '$$')))
        } else {
            if (-not $text.EndsWith("`n")) { $text += "`r`n" }
            $text += "$k=$v`r`n"
        }
    }
    $text
}

function Get-EnvValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path $Path)) { return $null }
    foreach ($line in Get-Content -Path $Path) {
        if ($line -match ('^\s*' + [regex]::Escape($Key) + '=(.*)$')) { return $Matches[1].Trim() }
    }
    $null
}

function Save-TextFile([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# SQL Server 2014 and older only offer old TLS versions to Node: the services need the "legacy TLS" setting.
function Test-LegacyTls([string]$InstanceId) {
    if ($InstanceId -match '^MSSQL(\d+)\.') { return ([int]$Matches[1] -le 12) }
    $false
}

# Addresses the tablets can use to reach this PC: IPv4 on adapters that have a default gateway, with the adapter name.
function Get-PcAddresses {
    $out = @()
    try {
        foreach ($c in Get-NetIPConfiguration) {
            if ($c.IPv4DefaultGateway -and $c.IPv4Address) {
                foreach ($a in $c.IPv4Address) { $out += [pscustomobject]@{ Adapter = $c.InterfaceAlias; Address = $a.IPAddress } }
            }
        }
    } catch { }
    $out
}

function Test-PortListening([int]$Port) {
    $l = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    @($l | Where-Object { $_.Port -eq $Port }).Count -gt 0
}

function Wait-Port([int]$Port, [int]$Seconds = 45) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) { if (Test-PortListening $Port) { return $true }; Start-Sleep -Milliseconds 700 }
    $false
}

# ---------------------------------------------------------------- steps

function Install-WingetPackage {
    param([string]$Id, [string]$Name, [string[]]$Override)
    $wingetArgs = @('install', '--id', $Id, '-e', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    if ($Override) { $wingetArgs += @('--override', ($Override -join ' ')) }
    Write-Log "Installing $Name with winget (this can take several minutes)"
    $code = Invoke-Native { & winget @wingetArgs }
    # -1978335189 = already installed / no newer version
    if ($code -ne 0 -and $code -ne 3010 -and $code -ne -1978335189) { throw "winget could not install $Name (exit code $code)" }
    Update-SessionPath
}

function Install-Prerequisites {
    Write-Log 'Step: Git, Node.js and .NET' 'STEP'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Add-Problem 'winget is not available. Install "App Installer" from the Microsoft Store (or update Windows), then run this again.'
        return
    }
    if (Get-Command git -ErrorAction SilentlyContinue) { Write-Log ('Git already installed: ' + (git --version)) }
    else { Invoke-Change 'install Git (winget Git.Git)' { Install-WingetPackage -Id 'Git.Git' -Name 'Git' } | Out-Null }

    $needNode = $true
    if (Get-Command node -ErrorAction SilentlyContinue) {
        $v = (node -v) -replace '^v', ''
        if ([int]($v.Split('.')[0]) -ge 20) { Write-Log "Node.js already installed: v$v"; $needNode = $false }
        else { Write-Log "Node.js v$v is too old (need 20 or newer)" 'WARN' }
    }
    if ($needNode) { Invoke-Change 'install Node.js LTS (winget OpenJS.NodeJS.LTS)' { Install-WingetPackage -Id 'OpenJS.NodeJS.LTS' -Name 'Node.js' } | Out-Null }

    $rel = 0
    try { $rel = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release } catch { }
    if ($rel -ge 528040) { Write-Log '.NET Framework 4.8 or newer is installed' }
    else { Add-Problem '.NET Framework 4.8 is not installed. Install it from Windows Update or Microsoft, then run this again (the menu board needs it).' }
}

function Get-SqlInstanceId {
    $k = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (-not (Test-Path $k)) { return $null }
    $p = Get-ItemProperty $k
    if ($p.PSObject.Properties.Name -contains $SqlInstance) { return $p.$SqlInstance }
    $null
}

function Install-SqlServer {
    Write-Log "Step: SQL Server Express (instance $SqlInstance)" 'STEP'
    $svc = "MSSQL`$$SqlInstance"
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) { Write-Log 'SQL Server instance is already installed' }
    else {
        $setupArgs = "/ACTION=Install /QUIET /IACCEPTSQLSERVERLICENSETERMS /INSTANCENAME=$SqlInstance"
        if ($SqlInstallerPath) {
            Invoke-Change "run the SQL Server installer $SqlInstallerPath" {
                $p = Start-Process -FilePath $SqlInstallerPath -ArgumentList $setupArgs -Wait -PassThru
                if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "SQL Server setup failed (exit code $($p.ExitCode))" }
            } | Out-Null
        } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
            Invoke-Change 'install SQL Server 2022 Express (winget Microsoft.SQLServer.2022.Express)' {
                Install-WingetPackage -Id 'Microsoft.SQLServer.2022.Express' -Name 'SQL Server Express' -Override @($setupArgs)
            } | Out-Null
        } else {
            Add-Problem 'Cannot install SQL Server: no winget and no -SqlInstallerPath. Install SQL Server Express by hand (manual section 3.2), then run this again.'
            return
        }
        if (-not $DryRun -and -not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) {
            Add-Problem "SQL Server setup finished but the service $svc is missing. See C:\Program Files\Microsoft SQL Server\*\Setup Bootstrap\Log, or install it by hand (manual section 3.2)."
            return
        }
    }
    if ($DryRun) { Write-Log '[dry run] would: allow SQL logins, enable TCP/IP on port 1433, restart SQL Server if that changed anything'; return }

    # Mixed-mode logins and a fixed TCP port: the services connect to localhost:1433 with SQL logins.
    $id = Get-SqlInstanceId
    if (-not $id) { Add-Problem "Cannot find SQL Server instance $SqlInstance in the registry."; return }
    $base = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$id\MSSQLServer"
    $tcp = "$base\SuperSocketNetLib\Tcp"
    $ipall = "$tcp\IPAll"
    $changed = $false
    if ((Get-ItemProperty $base).LoginMode -ne 2) { Set-ItemProperty $base -Name LoginMode -Value 2; $changed = $true; Write-Log 'Turned on mixed-mode (SQL) logins' }
    if ((Get-ItemProperty $tcp).Enabled -ne 1) { Set-ItemProperty $tcp -Name Enabled -Value 1; $changed = $true; Write-Log 'Enabled TCP/IP' }
    $p = Get-ItemProperty $ipall
    if ($p.TcpPort -ne '1433' -or $p.TcpDynamicPorts -ne '') {
        Set-ItemProperty $ipall -Name TcpPort -Value '1433'
        Set-ItemProperty $ipall -Name TcpDynamicPorts -Value ''
        $changed = $true; Write-Log 'Set the TCP port to 1433'
    }
    $service = Get-Service -Name $svc
    if ($changed -or $service.Status -ne 'Running') {
        Write-Log 'Restarting SQL Server'
        if ($service.Status -eq 'Running') { Restart-Service -Name $svc -Force } else { Start-Service -Name $svc }
    }
    if (-not (Wait-Port 1433 60)) { Add-Problem 'SQL Server is not listening on port 1433 after setup.'; return }

    # Can this Windows account administer it? KFIDisplay creates the database with it.
    try {
        $c = New-Object System.Data.SqlClient.SqlConnection('Data Source=localhost,1433;Initial Catalog=master;Integrated Security=True;Connect Timeout=15')
        $c.Open()
        $cmd = $c.CreateCommand(); $cmd.CommandText = "SELECT IS_SRVROLEMEMBER('sysadmin')"
        $isAdmin = [int]$cmd.ExecuteScalar(); $c.Close()
        if ($isAdmin -ne 1) { Add-Problem "Your Windows account ($env:USERDOMAIN\$env:USERNAME) is not a SQL Server administrator. Add it in SSMS (Security > Logins > Server Roles > sysadmin), then run this again." }
        else { Write-Log "SQL Server is ready on port 1433 and $env:USERNAME is an administrator" }
    } catch { Add-Problem ('Cannot sign in to SQL Server with this Windows account: ' + $_.Exception.Message) }
}

function Get-Code([string]$Name) {
    $path = Join-Path $SourceRoot $Name
    if (Test-Path (Join-Path $path '.git')) {
        $dirty = git -C $path status --porcelain 2>$null
        if ($dirty) { Write-Log "$Name has local changes, leaving it as it is" 'WARN' }
        elseif (-not $DryRun) { Write-Log "Updating $Name"; Invoke-Native { git -C $path pull --ff-only } | Out-Null }
        else { Write-Log "[dry run] would: update $Name" }
    } elseif (Test-Path $path) {
        Write-Log "$path exists but is not a git folder, leaving it as it is" 'WARN'
    } else {
        Invoke-Change "clone https://github.com/$GitHubOwner/$Name into $path" {
            $code = Invoke-Native { git clone "https://github.com/$GitHubOwner/$Name" $path }
            if ($code -ne 0) { throw "git clone of $Name failed (exit code $code)" }
        } | Out-Null
    }
}

function Install-Code {
    Write-Log 'Step: program folders and packages' 'STEP'
    foreach ($d in @($SourceRoot, $ImagesDir, $AppDataDir)) {
        if (-not (Test-Path $d)) { Invoke-Change "create folder $d" { New-Item -ItemType Directory -Force -Path $d | Out-Null } | Out-Null }
    }
    foreach ($n in @('kfdisplay-sync', 'KitchenDisplay', 'KFIDisplay')) { Get-Code $n }

    $slash = Join-Path $ImagesDir 'slash.gif'
    $slashSrc = Join-Path $SourceRoot 'KFIDisplay\slash.gif'
    if (-not (Test-Path $slash) -and (Test-Path $slashSrc)) { Invoke-Change "copy slash.gif into $ImagesDir" { Copy-Item $slashSrc $slash } | Out-Null }
    if (-not (Test-Path (Join-Path $ImagesDir 'disclaimer.jpg'))) {
        $script:Notes.Add("Put your own disclaimer.jpg in $ImagesDir (it is shown on the menu board every 16th picture).")
    }

    foreach ($n in @('kfdisplay-sync', 'KitchenDisplay')) {
        $dir = Join-Path $SourceRoot $n
        if ((Test-Path (Join-Path $dir 'package.json')) -and -not (Test-Path (Join-Path $dir 'node_modules'))) {
            Invoke-Change "npm install in $dir" {
                Push-Location $dir
                try { $code = Invoke-Native { & npm.cmd install --omit=dev --no-audit --no-fund }; if ($code -ne 0) { throw "npm install failed in $dir (exit code $code)" } }
                finally { Pop-Location }
            } | Out-Null
        } elseif (Test-Path (Join-Path $dir 'node_modules')) { Write-Log "$n packages are already installed" }
    }
}

function Resolve-KfiDisplaySource {
    $candidates = @()
    if ($KfiDisplaySource) { $candidates += $KfiDisplaySource }
    else {
        $here = $PSScriptRoot
        $candidates += (Join-Path $here 'KFIDisplay')
        $candidates += @(Get-ChildItem -Path $here -Filter 'KFIDisplay*.msi' -ErrorAction SilentlyContinue | ForEach-Object FullName)
        $candidates += @(Get-ChildItem -Path $here -Filter 'KFIDisplay*.zip' -ErrorAction SilentlyContinue | ForEach-Object FullName)
        $candidates += (Join-Path $SourceRoot 'KFIDisplay\bin\Release')
    }
    foreach ($c in $candidates) {
        if (-not (Test-Path $c)) { continue }
        if ((Get-Item $c).PSIsContainer) { if (Test-Path (Join-Path $c 'KFIDisplay.exe')) { return $c } }
        elseif ($c -match '\.(msi|zip)$') { return $c }
    }
    $null
}

function Find-KfiExe {
    $dirs = @("$env:ProgramFiles\KF\Menu Display", "${env:ProgramFiles(x86)}\KF\Menu Display", "$env:LOCALAPPDATA\Apps\KF\Menu Display")
    foreach ($d in $dirs) { if ($d -and (Test-Path (Join-Path $d 'KFIDisplay.exe'))) { return (Join-Path $d 'KFIDisplay.exe') } }
    $null
}

function Install-KfiDisplay {
    Write-Log 'Step: KFIDisplay menu board program' 'STEP'
    $exe = Find-KfiExe
    if ($exe) { Write-Log "KFIDisplay is already installed: $exe"; return $exe }
    $src = Resolve-KfiDisplaySource
    if (-not $src) {
        Add-Problem 'KFIDisplay was not found and no installer was given. Run again with -KfiDisplaySource <folder, .zip or .msi> (see README), or install it by hand (manual section 6.2).'
        return $null
    }
    $target = Join-Path $env:ProgramFiles 'KF\Menu Display'
    if ($src -match '\.msi$') {
        Invoke-Change "install $src" {
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$src`" /qn /norestart" -Wait -PassThru
            if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "msiexec failed (exit code $($p.ExitCode))" }
        } | Out-Null
    } elseif ($src -match '\.zip$') {
        Invoke-Change "unpack $src into $target" { New-Item -ItemType Directory -Force -Path $target | Out-Null; Expand-Archive -Path $src -DestinationPath $target -Force } | Out-Null
    } else {
        Invoke-Change "copy the program from $src into $target" { New-Item -ItemType Directory -Force -Path $target | Out-Null; Copy-Item -Path (Join-Path $src '*') -Destination $target -Recurse -Force } | Out-Null
    }
    if ($DryRun) { return (Join-Path $target 'KFIDisplay.exe') }
    $exe = Find-KfiExe
    if (-not $exe) { Add-Problem 'KFIDisplay.exe was not found after installing it.'; return $null }
    $exe
}

function New-Shortcut([string]$Path, [string]$Target) {
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($Path)
    $s.TargetPath = $Target; $s.WorkingDirectory = Split-Path $Target; $s.Description = 'KFDisplay menu board'
    $s.Save()
}

function Add-KfiShortcuts([string]$Exe) {
    $desktop = Join-Path $env:PUBLIC 'Desktop\KFDisplay.lnk'
    if (-not (Test-Path $desktop)) { Invoke-Change 'add a KFDisplay shortcut on the desktop' { New-Shortcut $desktop $Exe } | Out-Null }
    if (-not $NoAutostart) {
        $startup = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\StartUp\KFDisplay.lnk'
        if (-not (Test-Path $startup)) { Invoke-Change 'start KFIDisplay when anyone signs in to Windows' { New-Shortcut $startup $Exe } | Out-Null }
    }
}

# Creates the database, tables and both SQL logins through KFIDisplay's own setup code (one place owns the schema),
# then writes both .env files. Returns the sync key (new or existing) for the summary.
function Initialize-DatabaseAndEnv([string]$KfiExe) {
    Write-Log 'Step: database, SQL logins and .env files' 'STEP'
    $syncDir = Join-Path $SourceRoot 'kfdisplay-sync'
    $kitchenDir = Join-Path $SourceRoot 'KitchenDisplay'
    $syncEnv = Join-Path $syncDir '.env'
    $kitchenEnv = Join-Path $kitchenDir '.env'
    $syncKey = Get-EnvValue $syncEnv 'SYNC_KEY'

    if ($DryRun) {
        Write-Log "[dry run] would: create database $DatabaseName and logins $SyncLogin and $KitchenLogin through KFIDisplay, then write the two .env files that do not exist yet"
        return $syncKey
    }
    if (-not $KfiExe -or -not (Test-Path $KfiExe)) { Add-Problem 'Cannot create the database without KFIDisplay.exe.'; return $syncKey }

    $pwdFolder = Join-Path ([IO.Path]::GetTempPath()) ('kfd-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $pwdFolder | Out-Null
    try {
        $asm = [Reflection.Assembly]::LoadFrom($KfiExe)
        $type = $asm.GetType('KFIDisplay.DatabaseSetup', $true)
        $conn = "Data Source=.\$SqlInstance;Initial Catalog=$DatabaseName;Integrated Security=True"
        $r = $type.GetMethod('EnsureReady').Invoke($null, @([string]$conn, [string]$SyncLogin, [string]$pwdFolder, [string]$KitchenLogin))
        if (-not $r.Connected) { Add-Problem ('Cannot reach SQL Server: ' + ($r.Errors -join '; ')); return $syncKey }
        foreach ($e in $r.Errors) { Add-Problem "Database setup: $e" }
        if ($r.DatabaseCreated) { Write-Log "Created database $DatabaseName with $($r.TablesCreated.Count) tables" }
        elseif ($r.TablesCreated.Count -gt 0) { Write-Log ('Added missing tables: ' + ($r.TablesCreated -join ', ')) }
        else { Write-Log "Database $DatabaseName is already set up" }

        $passwords = @{}
        for ($i = 0; $i -lt $r.NewLogins.Count; $i++) {
            $text = Get-Content -Raw -Path $r.PasswordFiles[$i]
            if ($text -match '(?m)^(?:KFDISPLAY_PASSWORD|DB_PASSWORD)=(.+)$') { $passwords[$r.NewLogins[$i]] = $Matches[1].Trim() }
            Write-Log "Created SQL login $($r.NewLogins[$i])"
        }

        $legacy = Test-LegacyTls (Get-SqlInstanceId)
        $tls = if ($legacy) { 'true' } else { 'false' }
        $dbFields = @{ KFDISPLAY_DATABASE = $DatabaseName; KFDISPLAY_PORT = '1433'; KFDISPLAY_LEGACY_TLS = $tls }

        if (Test-Path $syncEnv) { Write-Log "$syncEnv already exists, leaving it as it is" }
        elseif ($passwords.ContainsKey($SyncLogin)) {
            $syncKey = New-SyncKey
            $vals = @{ SYNC_KEY = $syncKey; KFDISPLAY_USER = $SyncLogin; KFDISPLAY_PASSWORD = $passwords[$SyncLogin] } + $dbFields
            Save-TextFile $syncEnv (Set-EnvValues (Get-Content -Raw (Join-Path $syncDir '.env.example')) $vals)
            Write-Log "Wrote $syncEnv"
        } else { Add-Problem "$syncEnv is missing and the $SyncLogin login already existed, so its password is unknown. Create the .env by hand (manual section 3.7)." }

        if (Test-Path $kitchenEnv) { Write-Log "$kitchenEnv already exists, leaving it as it is" }
        elseif ($passwords.ContainsKey($KitchenLogin)) {
            $vals = @{ DB_DATABASE = $DatabaseName; DB_PORT = '1433'; DB_LEGACY_TLS = $tls; DB_USER = $KitchenLogin; DB_PASSWORD = $passwords[$KitchenLogin] }
            Save-TextFile $kitchenEnv (Set-EnvValues (Get-Content -Raw (Join-Path $kitchenDir '.env.example')) $vals)
            Write-Log "Wrote $kitchenEnv"
        } else { Add-Problem "$kitchenEnv is missing and the $KitchenLogin login already existed, so its password is unknown. Create the .env by hand (manual section 3.8)." }

        if ($r.NewLogins.Count -gt 0 -and ((Test-Path $syncEnv) -eq $false -or (Test-Path $kitchenEnv) -eq $false)) {
            Write-Log 'A new login was created but an .env could not be written. Its password is only in the temporary folder, which is deleted next.' 'WARN'
        }
    } catch {
        Add-Problem ('Database setup failed: ' + $_.Exception.Message)
    } finally {
        Remove-Item -Path $pwdFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
    $syncKey
}

function Install-WindowsSetup {
    Write-Log 'Step: firewall rules and start-at-boot tasks' 'STEP'
    $rules = @(@{ Name = 'KFDisplay sync'; Port = 8787 }, @{ Name = 'Kitchen Display'; Port = 8790 })
    foreach ($r in $rules) {
        if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) { Write-Log "Firewall rule already there: $($r.Name)"; continue }
        $port = $r.Port; $name = $r.Name
        Invoke-Change "add firewall rule $name (TCP $port, Private and Domain networks)" {
            New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -Profile Domain, Private | Out-Null
        } | Out-Null
    }
    $tasks = @(
        @{ Name = 'KFDisplay sync'; Script = (Join-Path $SourceRoot 'kfdisplay-sync\start-sync.cmd') },
        @{ Name = 'Kitchen Display'; Script = (Join-Path $SourceRoot 'KitchenDisplay\start-kitchen.cmd') }
    )
    foreach ($t in $tasks) {
        if (-not (Test-Path $t.Script) -and -not $DryRun) { Write-Log "Skipped task $($t.Name): $($t.Script) not found" 'WARN'; continue }
        $existing = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
        if ($existing) {
            if ($existing.Settings.ExecutionTimeLimit -ne 'PT0S') {
                $name = $t.Name
                Invoke-Change "remove the 72 hour time limit from task $name" { $e = Get-ScheduledTask -TaskName $name; $e.Settings.ExecutionTimeLimit = 'PT0S'; Set-ScheduledTask -InputObject $e | Out-Null } | Out-Null
            } else { Write-Log "Task already there: $($t.Name)" }
            continue
        }
        $name = $t.Name; $script = $t.Script
        Invoke-Change "add scheduled task $name (starts at boot as SYSTEM)" {
            $action = New-ScheduledTaskAction -Execute $script
            $trigger = New-ScheduledTaskTrigger -AtStartup
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
            Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
        } | Out-Null
    }
    # Tell KFIDisplay this was done, so it does not ask again (same marker its own setup writes).
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $AppDataDir | Out-Null; Set-Content -Path (Join-Path $AppDataDir 'setup-services.done') -Value '1' -Encoding ascii }
}

function Start-Services([string]$SyncKey) {
    Write-Log 'Step: start the services' 'STEP'
    if ($DryRun) { Write-Log '[dry run] would: start both services and check they answer'; return }
    foreach ($s in @(@{ Task = 'KFDisplay sync'; Port = 8787 }, @{ Task = 'Kitchen Display'; Port = 8790 })) {
        if (Test-PortListening $s.Port) { Write-Log "$($s.Task) is already running (port $($s.Port))"; continue }
        if (Get-ScheduledTask -TaskName $s.Task -ErrorAction SilentlyContinue) { Start-ScheduledTask -TaskName $s.Task }
        if (Wait-Port $s.Port 45) { Write-Log "$($s.Task) is running (port $($s.Port))" }
        else { Add-Problem "$($s.Task) did not start. Look at its logs folder (C:\Source\...\logs) for the reason; usually a wrong password in .env." }
    }
    try {
        $h = Invoke-RestMethod -Uri 'http://localhost:8790/api/health' -TimeoutSec 10
        if ($h.ok) { Write-Log "Kitchen Display server answers and is connected to database $($h.database)" }
    } catch { Write-Log ('Kitchen Display server did not answer the health check: ' + $_.Exception.Message) 'WARN' }
    if ($SyncKey) {
        try {
            $h = Invoke-RestMethod -Uri 'http://localhost:8787/v1/health' -Headers @{ Authorization = "Bearer $SyncKey" } -TimeoutSec 10
            if ($h.ok) { Write-Log "Sync service answers and is connected to database $($h.database)" }
        } catch { Write-Log ('Sync service did not answer the health check: ' + $_.Exception.Message) 'WARN' }
    }
}

function Write-Summary([string]$SyncKey) {
    $addrs = @(Get-PcAddresses)
    $lines = @('', '===================== TRUCK PC SETUP SUMMARY =====================')
    if ($addrs.Count -eq 0) { $lines += 'PC address for the tablets : run ipconfig and use the IPv4 Address' }
    elseif ($addrs.Count -eq 1) { $lines += ('PC address for the tablets : ' + $addrs[0].Address + '   (' + $addrs[0].Adapter + ')') }
    else {
        $lines += 'PC addresses (use the one on the same Wi-Fi or router as the tablets):'
        foreach ($a in $addrs) { $lines += ('    ' + $a.Address.PadRight(16) + $a.Adapter) }
    }
    $lines += 'Register tablet            : Settings > KFDisplay sync > KFDisplay PC address = that address, Sync key = the key below'
    $lines += 'Kitchen tablet             : PC name or address = that address followed by :8790'
    $lines += ('Sync key                   : ' + $(if ($SyncKey) { $SyncKey } else { '(not known: see the .env in the kfdisplay-sync folder)' }))
    $lines += ''
    if ($script:Notes.Count -gt 0) { $lines += 'To do:'; foreach ($n in $script:Notes) { $lines += "  - $n" } }
    $lines += '  - Give the PC a fixed address in the router (a DHCP reservation) so these numbers never change.'
    $lines += '  - Install the register and kitchen apps on the tablets (manual sections 4 and 5).'
    if ($script:Problems.Count -gt 0) { $lines += ''; $lines += 'PROBLEMS TO FIX:'; foreach ($p in $script:Problems) { $lines += "  ! $p" } }
    else { $lines += ''; $lines += 'No problems found.' }
    $lines += '=================================================================='
    $lines | ForEach-Object { Write-Host $_ -ForegroundColor $(if ($_ -like '  !*' -or $_ -eq 'PROBLEMS TO FIX:') { 'Red' } else { 'White' }) }
    if (-not $DryRun -and $SyncKey) {
        try {
            New-Item -ItemType Directory -Force -Path $AppDataDir | Out-Null
            Save-TextFile (Join-Path $AppDataDir 'tablet-setup.txt') (($lines -join "`r`n") + "`r`n`r`nThis file holds the sync key. Delete it after the tablets are set up.`r`n")
            Write-Host ('Saved to ' + (Join-Path $AppDataDir 'tablet-setup.txt') + ' (it holds the sync key; delete it after the tablets are set up).') -ForegroundColor Gray
        } catch { }
    }
}

# ---------------------------------------------------------------- main

function Invoke-Main {
    if (-not $DryRun -and -not (Test-Admin)) {
        if ($NoElevate) { Write-Host 'Not running as administrator (-NoElevate): steps that need it will fail.' -ForegroundColor Yellow }
        else {
        Write-Host 'Asking for administrator permission...' -ForegroundColor Cyan
        $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        foreach ($k in $PSBoundParameters.Keys) {
            $v = $PSBoundParameters[$k]
            if ($v -is [switch]) { if ($v.IsPresent) { $forward += "-$k" } } else { $forward += "-$k"; $forward += "`"$v`"" }
        }
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $forward -Verb RunAs -Wait -PassThru
        exit $p.ExitCode
        }
    }
    if (-not $DryRun) { try { New-Item -ItemType Directory -Force -Path $AppDataDir -ErrorAction Stop | Out-Null; $script:LogFile = Join-Path $AppDataDir 'install.log' } catch { } }
    Write-Log ("Truck PC setup starting" + $(if ($DryRun) { ' (dry run: nothing will be changed)' } else { '' }))

    $kfiExe = $null; $syncKey = $null
    try {
        if (-not $SkipPrerequisites) { Install-Prerequisites }
        if (-not $SkipSql) { Install-SqlServer }
        Install-Code
        if ($KfiDisplayExe -and (Test-Path $KfiDisplayExe)) { $kfiExe = $KfiDisplayExe; Write-Log "Using $kfiExe" }
        elseif (-not $SkipKfiDisplay) { $kfiExe = Install-KfiDisplay }
        if ($kfiExe) {
            $syncKey = Initialize-DatabaseAndEnv $kfiExe
            if ($NoShortcuts) { }
            elseif ($DryRun) { Write-Log '[dry run] would: add the desktop and startup shortcuts' }
            else { try { Add-KfiShortcuts $kfiExe } catch { Write-Log ('Could not add shortcuts: ' + $_.Exception.Message) 'WARN' } }
        }
        if (-not $SkipWindowsSetup) { Install-WindowsSetup }
        if (-not $NoStart) { Start-Services $syncKey }
    } catch {
        Add-Problem ('Stopped by an error: ' + $_.Exception.Message)
    }
    Write-Summary $syncKey
    if (-not $NoPause -and -not $DryRun) { Read-Host 'Press Enter to close' | Out-Null }
    if ($script:Problems.Count -gt 0) { exit 1 }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }
