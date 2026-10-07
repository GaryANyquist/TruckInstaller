<#
  Tests for Install-TruckPC.ps1.
    .\tests\Test-TruckInstaller.ps1                 fast checks of the helper functions, plus a dry run
    .\tests\Test-TruckInstaller.ps1 -Integration    also runs the real install steps into a scratch folder against
                                                    this PC's SQL Server, using a throwaway database "KFDisplayTest"
                                                    and throwaway logins, which it removes afterwards.
  The integration test needs: internet (git clone, npm install), SQL Server on localhost,1433 with your Windows
  account as administrator, and a built KFIDisplay.exe (-KfiDisplayExe).
#>
param(
    [switch]$Integration,
    [string]$KfiDisplayExe = 'C:\Source\KFIDisplay\bin\Release\KFIDisplay.exe'
)
$ErrorActionPreference = 'Stop'
$installer = Join-Path (Split-Path $PSScriptRoot -Parent) 'Install-TruckPC.ps1'
$script:fails = 0
function Check([string]$Name, $Got, $Want) {
    $ok = ($Got -eq $Want)
    if ($ok) { Write-Host "ok   $Name -> $Got" } else { $script:fails++; Write-Host "FAIL $Name`n   got  $Got`n   want $Want" -ForegroundColor Red }
}
function CheckTrue([string]$Name, $Condition) { Check $Name ([bool]$Condition) $true }

$testKfiExe = $KfiDisplayExe   # the installer's own parameter of the same name would overwrite it
. $installer   # loads the functions only; nothing runs

# ---- helpers
$k1 = New-SyncKey; $k2 = New-SyncKey
Check 'sync key is 32 characters' $k1.Length 32
CheckTrue 'sync key is url-safe' ($k1 -match '^[A-Za-z0-9_-]{32}$')
CheckTrue 'two sync keys differ' ($k1 -ne $k2)

$tpl = "SYNC_KEY=`r`nSYNC_PORT=8787`r`n#KFDISPLAY_INSTANCE=SQLEXPRESS`r`nKFDISPLAY_PASSWORD=`r`nOTHER=keep`r`n"
$out = Set-EnvValues $tpl @{ SYNC_KEY = 'abc$1'; KFDISPLAY_PASSWORD = 'p$$w'; EXTRA = 'x' }
CheckTrue 'env: value with a dollar sign kept as typed' ($out -match '(?m)^SYNC_KEY=abc\$1\r?$')
CheckTrue 'env: two dollar signs kept as typed' ($out -match '(?m)^KFDISPLAY_PASSWORD=p\$\$w\r?$')
CheckTrue 'env: other lines untouched' ($out -match '(?m)^OTHER=keep\r?$' -and $out -match '(?m)^SYNC_PORT=8787\r?$')
CheckTrue 'env: a commented line is not filled in' ($out -match '(?m)^#KFDISPLAY_INSTANCE=SQLEXPRESS\r?$')
CheckTrue 'env: a new key is appended' ($out -match '(?m)^EXTRA=x\r?$')

$syncTpl = Get-Content -Raw 'C:\Source\kfdisplay-sync\.env.example'
$kitTpl = Get-Content -Raw 'C:\Source\KitchenDisplay\.env.example'
$s = Set-EnvValues $syncTpl @{ SYNC_KEY = 'K'; KFDISPLAY_USER = 'u'; KFDISPLAY_PASSWORD = 'P'; KFDISPLAY_PORT = '1433'; KFDISPLAY_LEGACY_TLS = 'false' }
foreach ($pair in 'SYNC_KEY=K', 'KFDISPLAY_USER=u', 'KFDISPLAY_PASSWORD=P', 'KFDISPLAY_PORT=1433', 'KFDISPLAY_LEGACY_TLS=false') {
    CheckTrue "sync .env.example filled: $pair" ($s -match ('(?m)^' + [regex]::Escape($pair) + '\r?$'))
}
CheckTrue 'sync .env.example: instance line still commented' ($s -match '(?m)^#KFDISPLAY_INSTANCE=')
$kt = Set-EnvValues $kitTpl @{ DB_USER = 'kd'; DB_PASSWORD = 'Q'; DB_PORT = '1433'; DB_LEGACY_TLS = 'false' }
foreach ($pair in 'DB_USER=kd', 'DB_PASSWORD=Q', 'DB_PORT=1433', 'DB_LEGACY_TLS=false', 'KDS_PORT=8790') {
    CheckTrue "kitchen .env.example filled: $pair" ($kt -match ('(?m)^' + [regex]::Escape($pair) + '\r?$'))
}

$tmp = Join-Path $env:TEMP ('truckinst-' + [Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp | Out-Null
Save-TextFile "$tmp\.env" $s
Check 'Get-EnvValue reads a value' (Get-EnvValue "$tmp\.env" 'SYNC_KEY') 'K'
Check 'Get-EnvValue is null for a missing key' (Get-EnvValue "$tmp\.env" 'NOPE') $null
Check 'Get-EnvValue is null for a missing file' (Get-EnvValue "$tmp\nofile" 'SYNC_KEY') $null
CheckTrue 'saved .env has no byte order mark' ([IO.File]::ReadAllBytes("$tmp\.env")[0] -eq [byte][char]'#')
Remove-Item $tmp -Recurse -Force

CheckTrue 'SQL 2012 needs legacy TLS' (Test-LegacyTls 'MSSQL11.SQLEXPRESS')
CheckTrue 'SQL 2014 needs legacy TLS' (Test-LegacyTls 'MSSQL12.SQLEXPRESS')
CheckTrue 'SQL 2016 does not' (-not (Test-LegacyTls 'MSSQL13.SQLEXPRESS'))
CheckTrue 'SQL 2022 does not' (-not (Test-LegacyTls 'MSSQL16.SQLEXPRESS'))
CheckTrue 'unknown instance does not' (-not (Test-LegacyTls ''))

CheckTrue 'this PC has an address for the tablets' (@(Get-PcAddresses).Count -ge 1)
CheckTrue 'addresses come with an adapter name' (@(Get-PcAddresses)[0].Adapter -and (@(Get-PcAddresses)[0].Address -match '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'))
CheckTrue 'port 1433 is listening on this PC' (Test-PortListening 1433)
CheckTrue 'a random high port is not' (-not (Test-PortListening 59999))
CheckTrue 'admin check answers' ((Test-Admin) -in @($true, $false))

# ---- a dry run of the whole script changes nothing and reports no problems
Write-Host "`n--- dry run"
$before = @{
    Rules = (netsh advfirewall firewall show rule name=all dir=in | Measure-Object -Line).Lines
    Docs  = (Get-ChildItem C:\KFDisplay -ErrorAction SilentlyContinue | Measure-Object).Count
}
$dry = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -DryRun -NoPause 2>&1 | Out-String
CheckTrue 'dry run says it is a dry run' ($dry -match 'dry run')
CheckTrue 'dry run reaches the summary' ($dry -match 'TRUCK PC SETUP SUMMARY')
CheckTrue 'dry run lists the PC addresses' ($dry -match 'PC address')
CheckTrue 'dry run reports no errors' ($dry -notmatch '\[ERROR\]')
Check 'dry run added no firewall rules' ((netsh advfirewall firewall show rule name=all dir=in | Measure-Object -Line).Lines) $before.Rules
Check 'dry run wrote nothing to C:\KFDisplay' ((Get-ChildItem C:\KFDisplay -ErrorAction SilentlyContinue | Measure-Object).Count) $before.Docs

# ---- integration: the real steps, into a scratch folder, with throwaway database and logins
if ($Integration) {
    Write-Host "`n--- integration (scratch folder, throwaway database KFDisplayTest)"
    $root = Join-Path $env:TEMP ('truckinst-int-' + [Guid]::NewGuid().ToString('N'))
    $common = @('-SourceRoot', "$root\src", '-ImagesDir', "$root\images", '-AppDataDir', "$root\app",
        '-DatabaseName', 'KFDisplayTest', '-SyncLogin', 'kfd_t_sync', '-KitchenLogin', 'kfd_t_kitchen',
        '-KfiDisplayExe', $testKfiExe, '-SkipPrerequisites', '-SkipSql', '-SkipWindowsSetup', '-NoStart',
        '-NoShortcuts', '-NoAutostart', '-NoPause', '-NoElevate')
    function Sql([string]$q, [string]$db = 'master') {
        $c = New-Object System.Data.SqlClient.SqlConnection("Data Source=localhost,1433;Initial Catalog=$db;Integrated Security=True")
        $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = $q; $v = $cmd.ExecuteScalar(); $c.Close(); $v
    }
    try {
        $run1 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer @common 2>&1 | Out-String
        CheckTrue 'run 1: no errors' ($run1 -notmatch '\[ERROR\]')
        CheckTrue 'run 1: created the database' ($run1 -match 'Created database KFDisplayTest with 13 tables')
        CheckTrue 'run 1: created both logins' ($run1 -match 'Created SQL login kfd_t_sync' -and $run1 -match 'Created SQL login kfd_t_kitchen')
        foreach ($n in 'kfdisplay-sync', 'KitchenDisplay', 'KFIDisplay') { CheckTrue "cloned $n" (Test-Path "$root\src\$n\.git") }
        CheckTrue 'npm packages installed (sync)' (Test-Path "$root\src\kfdisplay-sync\node_modules")
        CheckTrue 'npm packages installed (kitchen)' (Test-Path "$root\src\KitchenDisplay\node_modules")
        CheckTrue 'slash.gif copied' (Test-Path "$root\images\slash.gif")
        CheckTrue 'password files are gone' (-not (Get-ChildItem $env:TEMP -Filter 'kfd-install-*' -Directory -ErrorAction SilentlyContinue))
        Check 'database has 13 tables' (Sql 'SELECT COUNT(*) FROM sys.tables' 'KFDisplayTest') 13

        $syncEnv = "$root\src\kfdisplay-sync\.env"; $kitEnv = "$root\src\KitchenDisplay\.env"
        CheckTrue 'sync .env written' (Test-Path $syncEnv)
        CheckTrue 'kitchen .env written' (Test-Path $kitEnv)
        $syncKey = Get-EnvValue $syncEnv 'SYNC_KEY'
        Check 'sync key is 32 characters' $syncKey.Length 32
        Check 'sync .env user' (Get-EnvValue $syncEnv 'KFDISPLAY_USER') 'kfd_t_sync'
        Check 'sync .env database' (Get-EnvValue $syncEnv 'KFDISPLAY_DATABASE') 'KFDisplayTest'
        Check 'kitchen .env user' (Get-EnvValue $kitEnv 'DB_USER') 'kfd_t_kitchen'
        Check 'kitchen .env database' (Get-EnvValue $kitEnv 'DB_DATABASE') 'KFDisplayTest'
        $tls = if (Test-LegacyTls (Get-SqlInstanceId)) { 'true' } else { 'false' }
        Check 'legacy TLS chosen from the SQL version' (Get-EnvValue $syncEnv 'KFDISPLAY_LEGACY_TLS') $tls

        # the generated passwords really work
        $pw = Get-EnvValue $kitEnv 'DB_PASSWORD'
        $c = New-Object System.Data.SqlClient.SqlConnection("Data Source=localhost,1433;Initial Catalog=KFDisplayTest;User ID=kfd_t_kitchen;Password=$pw")
        $c.Open(); $c.Close(); Write-Host 'ok   the kitchen login can sign in with the generated password'

        # the generated .env files really start the services (on spare ports, so the real ones are not disturbed)
        $env:KDS_PORT = '18790'; $env:SYNC_PORT = '18787'
        $kitProc = Start-Process node -ArgumentList 'src\main.js' -WorkingDirectory "$root\src\KitchenDisplay" -PassThru -WindowStyle Hidden -RedirectStandardOutput "$root\kit.out" -RedirectStandardError "$root\kit.err"
        $syncProc = Start-Process node -ArgumentList 'src\main.js' -WorkingDirectory "$root\src\kfdisplay-sync" -PassThru -WindowStyle Hidden -RedirectStandardOutput "$root\sync.out" -RedirectStandardError "$root\sync.err"
        Remove-Item Env:KDS_PORT, Env:SYNC_PORT
        try {
            CheckTrue 'kitchen server started on a spare port' (Wait-Port 18790 30)
            $h = Invoke-RestMethod http://localhost:18790/api/health
            Check 'kitchen server is connected to the test database' $h.database 'KFDisplayTest'
            $t = Invoke-RestMethod 'http://localhost:18790/api/tickets?view=active'
            Check 'kitchen server reads the new database (no tickets yet)' @($t.tickets).Count 0
            if ($syncProc) {
                CheckTrue 'sync service started on a spare port' (Wait-Port 18787 30)
                $h2 = Invoke-RestMethod http://localhost:18787/v1/health -Headers @{ Authorization = "Bearer $syncKey" }
                Check 'sync service is connected to the test database' $h2.database 'KFDisplayTest'
            }
        } finally {
            foreach ($p in @($kitProc, $syncProc)) { if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
        }

        # running it again changes nothing and does not touch the .env files
        $h1 = (Get-FileHash $syncEnv).Hash + (Get-FileHash $kitEnv).Hash
        $run2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer @common 2>&1 | Out-String
        CheckTrue 'run 2: no errors' ($run2 -notmatch '\[ERROR\]')
        CheckTrue 'run 2: database already set up' ($run2 -match 'already set up')
        CheckTrue 'run 2: .env files left alone' ($run2 -match 'already exists, leaving it as it is')
        Check 'run 2: .env files byte for byte the same' ((Get-FileHash $syncEnv).Hash + (Get-FileHash $kitEnv).Hash) $h1
    } finally {
        try { Sql "IF DB_ID('KFDisplayTest') IS NOT NULL BEGIN ALTER DATABASE KFDisplayTest SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE KFDisplayTest END" | Out-Null } catch { Write-Host "cleanup: $_" -ForegroundColor Yellow }
        foreach ($l in 'kfd_t_sync', 'kfd_t_kitchen') { try { Sql "IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name='$l') DROP LOGIN $l" | Out-Null } catch { Write-Host "cleanup: $_" -ForegroundColor Yellow } }
        Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host 'cleaned up the scratch folder, test database and test logins'
    }
}

Write-Host ''
if ($script:fails -eq 0) { Write-Host 'All installer checks passed.' -ForegroundColor Green; exit 0 }
Write-Host "$script:fails FAILED" -ForegroundColor Red; exit 1
