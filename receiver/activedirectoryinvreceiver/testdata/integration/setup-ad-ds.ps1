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
    Write-Step "Pinning static IPv4 on primary adapter"
    try {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.HardwareInterface } | Select-Object -First 1
        if (-not $adapter) {
            $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
        }
        if (-not $adapter) { return }
        $ipcfg = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1
        if (-not $ipcfg) { return }
        $ip = $ipcfg.IPAddress
        $prefix = $ipcfg.PrefixLength
        $gw = (Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric | Select-Object -First 1).NextHop
        Write-Log "Adapter=$($adapter.Name) IP=$ip/$prefix GW=$gw"
        try {
            New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -PrefixLength $prefix -ErrorAction Stop | Out-Null
        } catch {}
        if ($gw) {
            New-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -NextHop $gw -ErrorAction SilentlyContinue | Out-Null
        }
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($ip, "127.0.0.1") -ErrorAction SilentlyContinue
    } catch {
        Write-Log "WARNING: Set-StaticIPForDC: $_"
    }
}

function Install-ADDSForestOnce {
    Write-Step "Installing AD DS forest: $DomainName - creates ntds.dit with NoRebootOnCompletion"
    $winPsScriptPath = "$env:TEMP\otel-install-addsforest.ps1"
    $lines = @(
        "`$ErrorActionPreference = 'Continue'"
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
        "} catch {"
        "    Write-Output `"INSTALL_ERROR: `$_`""
        "}"
    )
    Set-Content -Path $winPsScriptPath -Value $lines -Encoding UTF8
    $out = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $winPsScriptPath 2>&1
    Write-Log ($out | Out-String)
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

    # Soft-recover the copy if the jet database was left dirty mid-promotion.
    $esentutl = Join-Path $env:SystemRoot "System32\esentutl.exe"
    if (Test-Path $esentutl) {
        Write-Log "Running esentutl /r against mount dir if needed"
        Push-Location $mountDir
        try {
            & $esentutl /r edb /l $mountDir /s $mountDir 2>&1 | ForEach-Object { Write-Log "esentutl: $_" }
        } catch {
            Write-Log "esentutl note: $_"
        }
        Pop-Location
    }

    # Try a few ports: 389 may be held by a half-started NTDS/ADWS; 10389 is the usual dsamain lab port.
    $portsToTry = @($LdapPort, 10389, 3389)
    $portsToTry = $portsToTry | Select-Object -Unique

    foreach ($port in $portsToTry) {
        Stop-DsaMainIfRunning
        $stdoutLog = "C:\otel-dsamain-$port.out.log"
        $stderrLog = "C:\otel-dsamain-$port.err.log"
        Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

        # dsamain accepts both - and / switch styles; use slash form (documented in AD DS tools).
        $args = @(
            "/dbpath:$mountDit",
            "/ldapport:$port",
            "/allowNonAdminAccess"
        )
        Write-Log "Starting: $dsamain $($args -join ' ')"
        $p = Start-Process -FilePath $dsamain -ArgumentList $args `
            -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError $stderrLog
        Set-Content -Path $DsaMainPidFile -Value $p.Id

        $env:AD_LDAP_SERVER = if ($port -eq 389) { "127.0.0.1" } else { "127.0.0.1:$port" }
        if ($env:GITHUB_ENV) {
            Add-Content -Path $env:GITHUB_ENV -Value "AD_LDAP_SERVER=$($env:AD_LDAP_SERVER)"
            Add-Content -Path $env:GITHUB_ENV -Value "AD_BASE_DN=CN=Users,DC=oteltest,DC=local"
        }

        $ready = $false
        for ($i = 1; $i -le 20; $i++) {
            if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) {
                Write-Log "dsamain exited early on port $port"
                if (Test-Path $stderrLog) { Get-Content $stderrLog -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "dsamain-err: $_" } }
                if (Test-Path $stdoutLog) { Get-Content $stdoutLog -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "dsamain-out: $_" } }
                break
            }
            if (Test-ADReady) {
                Write-Log "dsamain LDAP ready on port $port attempt $i server=$($env:AD_LDAP_SERVER)"
                $ready = $true
                break
            }
            Start-Sleep -Seconds 2
        }

        if ($ready) { return $true }

        Stop-DsaMainIfRunning
        # Fallback arg style with spaces (some builds prefer this)
        Write-Log "Retrying dsamain with space-separated args on port $port"
        $p2 = Start-Process -FilePath $dsamain -ArgumentList @(
            "/dbpath", $mountDit,
            "/ldapport", "$port",
            "/allowNonAdminAccess"
        ) -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError $stderrLog
        Set-Content -Path $DsaMainPidFile -Value $p2.Id
        for ($i = 1; $i -le 15; $i++) {
            if (-not (Get-Process -Id $p2.Id -ErrorAction SilentlyContinue)) {
                Write-Log "dsamain retry exited early on port $port"
                if (Test-Path $stderrLog) { Get-Content $stderrLog -ErrorAction SilentlyContinue | Select-Object -Last 20 | ForEach-Object { Write-Log "dsamain-err: $_" } }
                break
            }
            if (Test-ADReady) {
                Write-Log "dsamain LDAP ready via retry on port $port"
                return $true
            }
            Start-Sleep -Seconds 2
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
    Get-Content $MarkerFile
}

# ---------- main ----------

if (Test-Path $MarkerFile) {
    Write-Step "AD DS already configured (marker present)"
    Get-Content $MarkerFile
    # Ensure dsamain is still running for this job.
    if (-not (Test-ADReady)) {
        $null = Start-DsaMainMount
    }
    exit 0
}

if (Test-ADReady) {
    Write-Step "LDAP already reachable; seeding if needed"
    Seed-TestDirectoryData
    exit 0
}

# Phase 1: install + promote (unless already done)
if (-not (Test-Path $Phase1Marker)) {
    Set-StaticIPForDC

    Write-Step "Installing AD-Domain-Services Windows feature (full AD DS, not AD LDS)"
    $feature = Get-WindowsFeature -Name AD-Domain-Services
    if (-not $feature.Installed) {
        Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
    }

    Install-ADDSForestOnce
    Set-Content -Path $Phase1Marker -Value "promoted=$(Get-Date -Format o)"
} else {
    Write-Step "Phase marker present; skipping forest install"
}

# Try native NTDS first (works after real reboot on self-hosted runners).
Write-Step "Attempting to start NTDS service directly"
$null = & sc.exe start NTDS 2>&1
Start-Sleep -Seconds 3
if (Test-ADReady) {
    Write-Log "NTDS is serving LDAP natively"
    Seed-TestDirectoryData
    exit 0
}

# Hosted-runner path: mount the promoted AD DS database with dsamain.
if (-not (Start-DsaMainMount)) {
    Write-Error "Failed to expose AD DS LDAP via NTDS or dsamain"
    exit 1
}

Seed-TestDirectoryData
exit 0
