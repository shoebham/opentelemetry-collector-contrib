# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Installs full Windows Active Directory Domain Services (AD DS, not AD LDS) for
# integration testing of the active_directory_inv receiver on GitHub Actions
# Windows hosted runners.
#
# Hosted runners cannot reboot mid-job, and the NTDS service will not start
# until reboot after Install-ADDSForest. To still exercise real AD DS data via
# ADSI/LDAP without reboot we:
#   1. Install AD-Domain-Services + promote a forest (creates C:\Windows\NTDS\ntds.dit)
#   2. Mount that database with dsamain.exe (AD DS diagnostic tool) on LDAP port 389
#   3. Point ADSI at LDAP://127.0.0.1/... by exporting AD_LDAP_SERVER=127.0.0.1
#   4. Seed users/groups through the mounted LDAP view
#
# This is still full AD DS (real ntds.dit from forest promotion), not AD LDS.

$ErrorActionPreference = "Continue"

$DomainName = if ($env:AD_DOMAIN_NAME) { $env:AD_DOMAIN_NAME } else { "oteltest.local" }
$DomainNetbiosName = if ($env:AD_NETBIOS_NAME) { $env:AD_NETBIOS_NAME } else { "OTELTEST" }
$SafeModePassword = if ($env:AD_SAFE_MODE_PASSWORD) { $env:AD_SAFE_MODE_PASSWORD } else { "P@ssw0rd123!SafeMode" }
$TestUserPassword = if ($env:AD_TEST_USER_PASSWORD) { $env:AD_TEST_USER_PASSWORD } else { "P@ssw0rd123!User" }
$LdapPort = if ($env:AD_LDAP_PORT) { [int]$env:AD_LDAP_PORT } else { 389 }
$MarkerFile = "C:\otel-ad-ds-ready.marker"
$Phase1Marker = "C:\otel-ad-phase1.marker"
$SetupLog = "C:\otel-ad-ds-setup.log"
$NtdsPath = "C:\Windows\NTDS\ntds.dit"
$DsaMainPidFile = "C:\otel-dsamain.pid"

function Write-Step($msg) {
    $line = "==== $msg ===="
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $SetupLog -Value "$(Get-Date -Format o) $line" -ErrorAction SilentlyContinue
}

function Write-Log($msg) {
    Write-Host $msg
    Add-Content -Path $SetupLog -Value "$(Get-Date -Format o) $msg" -ErrorAction SilentlyContinue
}

# GitHub Actions often looks "stuck" during Install-WindowsFeature / Install-ADDSForest
# because those cmdlets emit little/no stdout for 10-25 minutes. Keep a heartbeat so
# humans/agents do not cancel a healthy run.
function Start-Heartbeat {
    param([string]$Label, [int]$IntervalSec = 30)
    $script:HeartbeatJob = Start-Job -ScriptBlock {
        param($lbl, $sec)
        $n = 0
        while ($true) {
            $n++
            $elapsed = $n * $sec
            Write-Output "[heartbeat] $lbl still running... elapsed~${elapsed}s (normal; do not cancel)"
            Start-Sleep -Seconds $sec
        }
    } -ArgumentList $Label, $IntervalSec
}

function Stop-Heartbeat {
    if ($script:HeartbeatJob) {
        Stop-Job $script:HeartbeatJob -ErrorAction SilentlyContinue
        Receive-Job $script:HeartbeatJob -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        Remove-Job $script:HeartbeatJob -Force -ErrorAction SilentlyContinue
        $script:HeartbeatJob = $null
    }
}

function Receive-Heartbeat {
    if ($script:HeartbeatJob) {
        Receive-Job $script:HeartbeatJob -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
    }
}

function Get-LdapPaths {
    $server = if ($env:AD_LDAP_SERVER) { $env:AD_LDAP_SERVER } else { "127.0.0.1" }
    return @(
        "LDAP://$server/RootDSE",
        "LDAP://RootDSE",
        "LDAP://localhost/RootDSE"
    )
}

function Test-ADReady {
    foreach ($path in (Get-LdapPaths)) {
        try {
            $root = New-Object System.DirectoryServices.DirectoryEntry($path)
            $nc = $root.Properties["defaultNamingContext"].Value
            if ($nc) {
                Write-Log "LDAP ready via $path defaultNamingContext=$nc"
                return $true
            }
        } catch {}
    }
    return $false
}

function Set-StaticIPForDC {
    Write-Step "Pinning static IPv4 on primary adapter (reduces DCPromo network errors on GHA)"
    try {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.HardwareInterface } | Select-Object -First 1
        if (-not $adapter) {
            $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
        }
        if (-not $adapter) { Write-Log "No up adapter found"; return }
        $ipcfg = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1
        if (-not $ipcfg) { Write-Log "No usable IPv4 on adapter"; return }
        $ip = $ipcfg.IPAddress
        $prefix = $ipcfg.PrefixLength
        $gw = (Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric | Select-Object -First 1).NextHop
        Write-Log "Adapter=$($adapter.Name) ifIndex=$($adapter.ifIndex) IP=$ip/$prefix GW=$gw"
        # Remove existing IPv4 on interface then re-add as static (same address keeps connectivity)
        Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $ip } |
            ForEach-Object {
                try { Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -Confirm:$false -ErrorAction SilentlyContinue } catch {}
            }
        try {
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gw -ErrorAction Stop | Out-Null
        } catch {
            try {
                New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -PrefixLength $prefix -ErrorAction Stop | Out-Null
            } catch {
                Write-Log "New-NetIPAddress note: $_"
            }
            if ($gw) {
                New-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -NextHop $gw -ErrorAction SilentlyContinue | Out-Null
            }
        }
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($ip, "127.0.0.1") -ErrorAction SilentlyContinue
        # Disable IPv6 on primary adapter — DCPromo often warns/fails when IPv6 is enabled without static v6
        try {
            Disable-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
            Write-Log "Disabled IPv6 binding on $($adapter.Name)"
        } catch {
            Write-Log "IPv6 disable note: $_"
        }
        $verify = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $ip } | Select-Object -First 1
        Write-Log "Static IP verify: Address=$($verify.IPAddress) PrefixOrigin=$($verify.PrefixOrigin) AddressState=$($verify.AddressState)"
    } catch {
        Write-Log "WARNING: Set-StaticIPForDC: $_"
    }
}

function Install-ADDSForestOnce {
    Write-Step "Installing AD DS forest: $DomainName - creates ntds.dit with NoRebootOnCompletion"
    Write-Log "NOTE: Install-ADDSForest often takes 10-20 min with little output; heartbeats prove progress."
    $winPsScriptPath = "$env:TEMP\otel-install-addsforest.ps1"
    $lines = @(
        "`$ErrorActionPreference = 'Stop'"
        "Import-Module ADDSDeployment -Force"
        "`$securePw = ConvertTo-SecureString '$SafeModePassword' -AsPlainText -Force"
        "try {"
        "    `$r = Install-ADDSForest ``"
        "        -DomainName '$DomainName' ``"
        "        -DomainNetbiosName '$DomainNetbiosName' ``"
        "        -SafeModeAdministratorPassword `$securePw ``"
        "        -InstallDns:`$true ``"
        "        -NoRebootOnCompletion:`$true ``"
        "        -Force:`$true ``"
        "        -CreateDnsDelegation:`$false ``"
        "        -DatabasePath 'C:\Windows\NTDS' ``"
        "        -LogPath 'C:\Windows\NTDS' ``"
        "        -SysvolPath 'C:\Windows\SYSVOL'"
        "    `$r | Format-List | Out-String | Write-Output"
        "    if (`$r.Status -and (`$r.Status.ToString() -ne 'Success')) {"
        "        Write-Output `"INSTALL_STATUS_ERROR: `$(`$r | Format-List | Out-String)`""
        "        exit 2"
        "    }"
        "    exit 0"
        "} catch {"
        "    Write-Output `"INSTALL_ERROR: `$_`""
        "    exit 1"
        "}"
    )
    Set-Content -Path $winPsScriptPath -Value $lines -Encoding UTF8
    Start-Heartbeat -Label "Install-ADDSForest" -IntervalSec 30
    $ok = $false
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$winPsScriptPath`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        while (-not $proc.HasExited) {
            Receive-Heartbeat
            Start-Sleep -Seconds 5
        }
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        if ($stdout) { Write-Log $stdout }
        if ($stderr) { Write-Log "stderr: $stderr" }
        Write-Log "Install-ADDSForest child exit=$($proc.ExitCode)"
        $combined = "$stdout`n$stderr"
        if ($proc.ExitCode -eq 0 -and $combined -notmatch "INSTALL_ERROR|INSTALL_STATUS_ERROR|Status\s*:\s*Error") {
            $ok = $true
        }
    } finally {
        Stop-Heartbeat
    }
    return $ok
}

function Install-ADDSForestWithRetry {
    param([int]$MaxAttempts = 3)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Log "Install-ADDSForest attempt $attempt of $MaxAttempts"
        # Clean partial promote artifacts between attempts
        if ($attempt -gt 1) {
            Write-Log "Cleaning partial forest state before retry"
            try {
                $null = & sc.exe stop NTDS 2>&1
                $null = & sc.exe stop ADWS 2>&1
                $null = & sc.exe stop DNS 2>&1
                Start-Sleep -Seconds 3
            } catch {}
            foreach ($p in @("C:\Windows\NTDS", "C:\Windows\SYSVOL")) {
                if (Test-Path $p) {
                    try { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
            Set-StaticIPForDC
            Start-Sleep -Seconds 5
        }
        if (Install-ADDSForestOnce) {
            if (Test-Path $NtdsPath) {
                Write-Log "Install-ADDSForest succeeded; ntds.dit present size=$((Get-Item $NtdsPath).Length)"
                return $true
            }
            Write-Log "Install reported success but ntds.dit missing; will retry if attempts remain"
        } else {
            Write-Log "Install-ADDSForest attempt $attempt failed"
        }
    }
    return $false
}

function Stop-DsaMainIfRunning {
    if (Test-Path $DsaMainPidFile) {
        $oldPid = Get-Content $DsaMainPidFile -ErrorAction SilentlyContinue
        if ($oldPid) {
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $DsaMainPidFile -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name dsamain -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Start-DsaMainMount {
    Write-Step "Mounting AD DS database with dsamain - works without NTDS reboot"
    if (-not (Test-Path $NtdsPath)) {
        Write-Error "ntds.dit not found at $NtdsPath; forest promotion may have failed"
        return $false
    }

    # NTDS must be fully stopped; incomplete promotion often leaves locks on the live dit.
    $null = & sc.exe stop NTDS 2>&1
    $null = & sc.exe stop ADWS 2>&1
    Start-Sleep -Seconds 3

    Stop-DsaMainIfRunning

    $dsamain = Join-Path $env:SystemRoot "System32\dsamain.exe"
    if (-not (Test-Path $dsamain)) {
        $found = Get-ChildItem -Path "$env:SystemRoot\System32","$env:SystemRoot\SysWOW64" -Filter dsamain.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $dsamain = $found.FullName }
    }
    if (-not (Test-Path $dsamain)) {
        Write-Log "dsamain.exe not found; cannot mount ntds.dit without reboot"
        return $false
    }

    # Copy the promoted database + logs so dsamain does not fight live NTDS paths.
    $mountDir = "C:\otel-ntds-mount"
    if (Test-Path $mountDir) { Remove-Item $mountDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $mountDir -Force | Out-Null
    Copy-Item -Path $NtdsPath -Destination (Join-Path $mountDir "ntds.dit") -Force
    Get-ChildItem "C:\Windows\NTDS" -Filter "edb*.log" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName -Destination $mountDir -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem "C:\Windows\NTDS" -Filter "edb.chk" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName -Destination $mountDir -Force -ErrorAction SilentlyContinue
    }
    $mountDit = Join-Path $mountDir "ntds.dit"
    Write-Log "Copied ntds.dit to $mountDit size=$((Get-Item $mountDit).Length)"

    # DIT must be consistent (ESE logs replayed) before dsamain will accept it.
    $esentutl = Join-Path $env:SystemRoot "System32\esentutl.exe"
    if (Test-Path $esentutl) {
        Write-Log "Recovering ESE database with esentutl /r and /p if needed"
        Push-Location $mountDir
        try {
            & $esentutl /r edb /l $mountDir /s $mountDir 2>&1 | ForEach-Object { Write-Log "esentutl-r: $_" }
        } catch { Write-Log "esentutl /r note: $_" }
        try {
            # /p repairs if still dirty; non-interactive via echo y if prompted is unreliable, so /p only if /mh shows dirty
            $mh = & $esentutl /mh $mountDit 2>&1 | Out-String
            Write-Log "esentutl /mh: $($mh.Substring(0, [Math]::Min(500, $mh.Length)))"
            if ($mh -match "State:\s*Dirty|Dirty Shutdown") {
                Write-Log "Database dirty; running esentutl /p"
                echo Y | & $esentutl /p $mountDit 2>&1 | ForEach-Object { Write-Log "esentutl-p: $_" }
            }
        } catch { Write-Log "esentutl /mh|/p note: $_" }
        Pop-Location
    }

    $logPath = Join-Path $mountDir "logs"
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null

    # dsamain help requires: -dbpath, -ldapPort (capital P), optional -logpath, -allowNonAdminAccess, -allowUpgrade
    # Wrong arg style prints help and exits — that was our previous failure mode.
    $portsToTry = @(10389, $LdapPort, 31389) | Select-Object -Unique

    foreach ($port in $portsToTry) {
        Stop-DsaMainIfRunning
        $stdoutLog = "C:\otel-dsamain-$port.out.log"
        $stderrLog = "C:\otel-dsamain-$port.err.log"
        Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

        $argList = @(
            "-dbpath", $mountDit,
            "-logpath", $logPath,
            "-ldapPort", "$port",
            "-allowNonAdminAccess",
            "-allowUpgrade"
        )
        Write-Log "Starting: $dsamain $($argList -join ' ')"
        $p = Start-Process -FilePath $dsamain -ArgumentList $argList `
            -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError $stderrLog
        Set-Content -Path $DsaMainPidFile -Value $p.Id

        $env:AD_LDAP_SERVER = if ($port -eq 389) { "127.0.0.1" } else { "127.0.0.1:$port" }
        if ($env:GITHUB_ENV) {
            # Overwrite-friendly: append; later steps read latest env file value is first-wins in GHA, so set once outside loop ideally.
            # Re-set each successful port attempt only after ready check below.
        }

        $ready = $false
        for ($i = 1; $i -le 30; $i++) {
            if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) {
                Write-Log "dsamain exited early on port $port"
                if (Test-Path $stderrLog) { Get-Content $stderrLog -ErrorAction SilentlyContinue | Select-Object -Last 30 | ForEach-Object { Write-Log "dsamain-err: $_" } }
                if (Test-Path $stdoutLog) { Get-Content $stdoutLog -ErrorAction SilentlyContinue | Select-Object -Last 30 | ForEach-Object { Write-Log "dsamain-out: $_" } }
                break
            }
            if (Test-ADReady) {
                Write-Log "dsamain LDAP ready on port $port attempt $i server=$($env:AD_LDAP_SERVER)"
                $ready = $true
                break
            }
            Start-Sleep -Seconds 2
        }

        if ($ready) {
            if ($env:GITHUB_ENV) {
                Add-Content -Path $env:GITHUB_ENV -Value "AD_LDAP_SERVER=$($env:AD_LDAP_SERVER)"
                Add-Content -Path $env:GITHUB_ENV -Value "AD_BASE_DN=CN=Users,DC=oteltest,DC=local"
            }
            return $true
        }
        Stop-DsaMainIfRunning
    }

    Write-Log "All dsamain attempts failed"
    return $false
}

function Seed-TestDirectoryData {
    Write-Step "Seeding integration test users and groups via LDAP/ADSI"
    $server = if ($env:AD_LDAP_SERVER) { $env:AD_LDAP_SERVER } else { "127.0.0.1" }
    $domainParts = $DomainName.Split(".")
    $baseDn = ($domainParts | ForEach-Object { "DC=$_" }) -join ","
    $usersDn = "CN=Users,$baseDn"
    $ldapUsers = "LDAP://$server/$usersDn"

    function Get-OrNullADSI([string]$ldapPath) {
        try {
            $obj = [ADSI]$ldapPath
            if ($obj.Path) { return $obj }
        } catch {}
        return $null
    }

    function New-ADSIUser {
        param(
            [string]$Name,
            [string]$SamAccountName,
            [string]$Mail,
            [string]$Department,
            [string]$ManagerDn,
            [string]$Password
        )
        $userPath = "LDAP://$server/CN=$Name,$usersDn"
        $existing = Get-OrNullADSI $userPath
        if ($existing) {
            Write-Log "User $Name already exists"
            return $existing
        }
        $users = [ADSI]$ldapUsers
        $user = $users.Create("user", "CN=$Name")
        $user.Put("sAMAccountName", $SamAccountName)
        $user.Put("userPrincipalName", "$SamAccountName@$DomainName")
        $user.Put("displayName", $Name)
        if ($Mail) { $user.Put("mail", $Mail) }
        if ($Department) { $user.Put("department", $Department) }
        if ($ManagerDn) { $user.Put("manager", $ManagerDn) }
        $user.SetInfo()
        try {
            $user.Invoke("SetPassword", $Password)
            $user.Put("userAccountControl", 512)
            $user.SetInfo()
        } catch {
            Write-Log "SetPassword/UAC note for $Name - dsamain may be read-only for some ops: $_"
        }
        return $user
    }

    function New-ADSIGroup {
        param([string]$Name)
        $groupPath = "LDAP://$server/CN=$Name,$usersDn"
        $existing = Get-OrNullADSI $groupPath
        if ($existing) {
            Write-Log "Group $Name already exists"
            return $existing
        }
        $users = [ADSI]$ldapUsers
        $group = $users.Create("group", "CN=$Name")
        $group.Put("sAMAccountName", $Name)
        $group.Put("groupType", -2147483646)
        $group.SetInfo()
        return $group
    }

    # If write fails (dsamain snapshot mode is often read-only), fall back to
    # asserting against built-in objects that always exist in a promoted forest
    # (e.g. Administrator, Guest, Domain Users). Integration tests tolerate that
    # by checking for any non-empty inventory with name attributes.
    try {
        $null = New-ADSIUser -Name "Otel Manager" -SamAccountName "otelmanager" `
            -Mail "otelmanager@$DomainName" -Department "Engineering" -Password $TestUserPassword
        $managerDn = "CN=Otel Manager,$usersDn"
        $null = New-ADSIUser -Name "Otel TestUser" -SamAccountName "oteltestuser" `
            -Mail "oteltestuser@$DomainName" -Department "Platform" -ManagerDn $managerDn -Password $TestUserPassword
        $group = New-ADSIGroup -Name "Otel TestGroup"
        try {
            $group.Add("LDAP://$server/CN=Otel TestUser,$usersDn")
            $group.SetInfo()
        } catch {
            Write-Log "Group membership note: $_"
        }
        Write-Log "Seeded Otel Manager / Otel TestUser / Otel TestGroup"
    } catch {
        Write-Log "WARNING: could not seed custom users - dsamain may be read-only: $_"
        Write-Log "Integration tests will validate against built-in forest objects such as Administrator"
        if ($env:GITHUB_ENV) {
            Add-Content -Path $env:GITHUB_ENV -Value "AD_SEEDED_USERS=false"
        }
        $env:AD_SEEDED_USERS = "false"
    }

    Set-Content -Path $MarkerFile -Value @"
domain=$DomainName
base_dn=$usersDn
ldap_server=$server
mode=dsamain-mount
ntds_dit=$NtdsPath
"@
    Write-Step "AD DS integration environment ready"
    Get-Content $MarkerFile | ForEach-Object { Write-Host $_ }
    Write-Host "setup-ad-ds.ps1: seeding/marker done, returning to caller"
}

# Ensure caller always gets a clear terminal line before we exit the script body.
function Finish-SetupSuccess {
    Write-Host "setup-ad-ds.ps1: SUCCESS exit 0"
    exit 0
}

# ---------- main ----------

Write-Host ""
Write-Host "############################################################"
Write-Host "# AD DS integration setup (full forest, not AD LDS)       #"
Write-Host "# Expected wall time: 15-30 minutes on GHA windows-2025   #"
Write-Host "# Long silence during feature/forest install is NORMAL.   #"
Write-Host "# Heartbeats print every ~30s — do NOT cancel the run.    #"
Write-Host "############################################################"
Write-Host ""

if (Test-Path $MarkerFile) {
    Write-Step "AD DS already configured (marker present)"
    Get-Content $MarkerFile | ForEach-Object { Write-Host $_ }
    # Ensure dsamain is still running for this job.
    if (-not (Test-ADReady)) {
        $null = Start-DsaMainMount
    }
    Finish-SetupSuccess
}

if (Test-ADReady) {
    Write-Step "LDAP already reachable; seeding if needed"
    Seed-TestDirectoryData
    Finish-SetupSuccess
}

# Phase 1: install + promote (unless already done)
if (-not (Test-Path $Phase1Marker)) {
    Set-StaticIPForDC

    Write-Step "Installing AD-Domain-Services Windows feature (full AD DS, not AD LDS)"
    Write-Log "NOTE: Install-WindowsFeature often takes 5-15 min; heartbeats prove progress."
    $feature = Get-WindowsFeature -Name AD-Domain-Services
    if (-not $feature.Installed) {
        Start-Heartbeat -Label "Install-WindowsFeature AD-Domain-Services" -IntervalSec 30
        try {
            $featJob = Start-Job -ScriptBlock {
                Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-String
            }
            while ($featJob.State -eq 'Running') {
                Receive-Heartbeat
                Start-Sleep -Seconds 5
            }
            $featOut = Receive-Job $featJob
            Remove-Job $featJob -Force -ErrorAction SilentlyContinue
            if ($featOut) { Write-Log ($featOut | Out-String) }
            Write-Log "Install-WindowsFeature finished"
        } finally {
            Stop-Heartbeat
        }
    } else {
        Write-Log "AD-Domain-Services already installed"
    }

    if (-not (Install-ADDSForestWithRetry -MaxAttempts 3)) {
        Write-Error "Install-ADDSForest failed after retries; refusing to write phase marker"
        exit 1
    }
    if (-not (Test-Path $NtdsPath)) {
        Write-Error "ntds.dit missing after successful promote claim; aborting"
        exit 1
    }
    Set-Content -Path $Phase1Marker -Value "promoted=$(Get-Date -Format o)"
    Write-Log "Phase 1 marker written; proceeding to NTDS/dsamain"
} else {
    Write-Step "Phase marker present; skipping forest install"
    if (-not (Test-Path $NtdsPath)) {
        Write-Log "Phase marker present but ntds.dit missing; clearing marker and re-promoting"
        Remove-Item $Phase1Marker -Force -ErrorAction SilentlyContinue
        Set-StaticIPForDC
        if (-not (Install-ADDSForestWithRetry -MaxAttempts 3)) {
            Write-Error "Re-promote failed"
            exit 1
        }
        Set-Content -Path $Phase1Marker -Value "promoted=$(Get-Date -Format o)"
    }
}

# Try native NTDS first (works after real reboot on self-hosted runners).
Write-Step "Attempting to start NTDS service directly"
$null = & sc.exe start NTDS 2>&1
Start-Sleep -Seconds 3
if (Test-ADReady) {
    Write-Log "NTDS is serving LDAP natively"
    Seed-TestDirectoryData
    Finish-SetupSuccess
}

# Hosted-runner path: mount the promoted AD DS database with dsamain.
if (-not (Start-DsaMainMount)) {
    Write-Error "Failed to expose AD DS LDAP via NTDS or dsamain"
    exit 1
}

Seed-TestDirectoryData
Finish-SetupSuccess
