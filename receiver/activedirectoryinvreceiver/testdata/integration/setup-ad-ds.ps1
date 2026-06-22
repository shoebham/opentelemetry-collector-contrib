# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Installs and configures a full Windows Active Directory Domain Services forest
# for integration testing of the active_directory_inv receiver on GitHub Actions
# Windows runners. Uses full AD DS (not AD LDS / lightweight directory services).
#
# Phase handling (hosted runners cannot reboot mid-job reliably):
#   - If LDAP is already up (e.g. prior promotion in this session), seed users and exit.
#   - Otherwise install AD-Domain-Services, promote with -NoRebootOnCompletion, try to
#     bring NTDS/ADWS/DNS/Netlogon/KDC online without reboot, seed users.
#   - If a reboot is still required, write C:\otel-ad-phase1.marker and exit 42 so the
#     workflow can reboot the runner and re-enter this script (phase 2).
#
# Phase 2 (post-reboot on the same runner, if supported) or same-session success path
# finishes user seeding and writes C:\otel-ad-ds-ready.marker.

$ErrorActionPreference = "Continue"

$DomainName = if ($env:AD_DOMAIN_NAME) { $env:AD_DOMAIN_NAME } else { "oteltest.local" }
$DomainNetbiosName = if ($env:AD_NETBIOS_NAME) { $env:AD_NETBIOS_NAME } else { "OTELTEST" }
$SafeModePassword = if ($env:AD_SAFE_MODE_PASSWORD) { $env:AD_SAFE_MODE_PASSWORD } else { "P@ssw0rd123!SafeMode" }
$TestUserPassword = if ($env:AD_TEST_USER_PASSWORD) { $env:AD_TEST_USER_PASSWORD } else { "P@ssw0rd123!User" }
$MarkerFile = "C:\otel-ad-ds-ready.marker"
$Phase1Marker = "C:\otel-ad-phase1.marker"
$SetupLog = "C:\otel-ad-ds-setup.log"

function Write-Step($msg) {
    $line = "==== $msg ===="
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $SetupLog -Value "$(Get-Date -Format o) $line" -ErrorAction SilentlyContinue
}

function Write-Log($msg) {
    Write-Host $msg
    Add-Content -Path $SetupLog -Value "$(Get-Date -Format o) $msg" -ErrorAction SilentlyContinue
}

function Test-ADReady {
    foreach ($path in @(
        "LDAP://RootDSE",
        "LDAP://127.0.0.1/RootDSE",
        "LDAP://localhost/RootDSE"
    )) {
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
        if (-not $adapter) {
            Write-Log "WARNING: no active adapter; skipping static IP"
            return
        }
        $ipcfg = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1
        if (-not $ipcfg) {
            Write-Log "WARNING: no usable IPv4; skipping static IP"
            return
        }
        $ip = $ipcfg.IPAddress
        $prefix = $ipcfg.PrefixLength
        $gw = (Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric | Select-Object -First 1).NextHop
        Write-Log "Adapter=$($adapter.Name) IP=$ip/$prefix GW=$gw"

        $existingStatic = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -eq "Manual" -and $_.IPAddress -eq $ip }
        if ($existingStatic) {
            Write-Log "Already static at $ip"
        } else {
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
        Write-Log "DNS set to $ip / 127.0.0.1"
    } catch {
        Write-Log "WARNING: Set-StaticIPForDC failed: $_"
    }
}

function Start-DirectoryServices {
    # Do NOT Restart-Service NTDS when reboot is pending — it can hang indefinitely.
    $services = @("NTDS", "ADWS", "DNS", "Netlogon", "Kdc", "W32Time")
    foreach ($svc in $services) {
        try {
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if (-not $s) { continue }
            if ($s.StartType -eq "Disabled") {
                Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue
            }
            if ($s.Status -ne "Running") {
                # Use sc.exe with a short timeout feel; Start-Service can block a long time.
                $null = & sc.exe start $svc 2>&1
                Start-Sleep -Seconds 2
            }
            $s2 = Get-Service -Name $svc -ErrorAction SilentlyContinue
            Write-Log "Service $svc -> $($s2.Status)"
        } catch {
            Write-Log "Service $svc error: $_"
        }
    }
}

function Install-ADDSForestOnce {
    Write-Step "Installing AD DS forest: $DomainName (NoRebootOnCompletion)"
    $winPsScript = @"
`$ErrorActionPreference = 'Continue'
Import-Module ADDSDeployment -Force
`$securePw = ConvertTo-SecureString '$SafeModePassword' -AsPlainText -Force
try {
    `$r = Install-ADDSForest ``
        -DomainName '$DomainName' ``
        -DomainNetbiosName '$DomainNetbiosName' ``
        -SafeModeAdministratorPassword `$securePw ``
        -InstallDns:`$true ``
        -NoRebootOnCompletion:`$true ``
        -Force:`$true ``
        -CreateDnsDelegation:`$false ``
        -DatabasePath 'C:\Windows\NTDS' ``
        -LogPath 'C:\Windows\NTDS' ``
        -SysvolPath 'C:\Windows\SYSVOL'
    `$r | Format-List | Out-String | Write-Output
} catch {
    Write-Output "INSTALL_ERROR: `$_"
}
"@
    $winPsScriptPath = "$env:TEMP\otel-install-addsforest.ps1"
    Set-Content -Path $winPsScriptPath -Value $winPsScript -Encoding UTF8
    $out = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $winPsScriptPath 2>&1
    Write-Log ($out | Out-String)
}

function Seed-TestDirectoryData {
    Write-Step "Seeding integration test users and groups"
    $domainParts = $DomainName.Split(".")
    $baseDn = ($domainParts | ForEach-Object { "DC=$_" }) -join ","
    $usersDn = "CN=Users,$baseDn"

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
        $existing = Get-OrNullADSI "LDAP://CN=$Name,$usersDn"
        if ($existing) {
            Write-Log "User $Name already exists"
            return $existing
        }
        $users = [ADSI]"LDAP://$usersDn"
        $user = $users.Create("user", "CN=$Name")
        $user.Put("sAMAccountName", $SamAccountName)
        $user.Put("userPrincipalName", "$SamAccountName@$DomainName")
        $user.Put("displayName", $Name)
        if ($Mail) { $user.Put("mail", $Mail) }
        if ($Department) { $user.Put("department", $Department) }
        if ($ManagerDn) { $user.Put("manager", $ManagerDn) }
        $user.SetInfo()
        $user.Invoke("SetPassword", $Password)
        $user.Put("userAccountControl", 512)
        $user.SetInfo()
        return $user
    }

    function New-ADSIGroup {
        param([string]$Name)
        $existing = Get-OrNullADSI "LDAP://CN=$Name,$usersDn"
        if ($existing) {
            Write-Log "Group $Name already exists"
            return $existing
        }
        $users = [ADSI]"LDAP://$usersDn"
        $group = $users.Create("group", "CN=$Name")
        $group.Put("sAMAccountName", $Name)
        $group.Put("groupType", -2147483646)
        $group.SetInfo()
        return $group
    }

    $null = New-ADSIUser -Name "Otel Manager" -SamAccountName "otelmanager" `
        -Mail "otelmanager@$DomainName" -Department "Engineering" -Password $TestUserPassword
    $managerDn = "CN=Otel Manager,$usersDn"
    $null = New-ADSIUser -Name "Otel TestUser" -SamAccountName "oteltestuser" `
        -Mail "oteltestuser@$DomainName" -Department "Platform" -ManagerDn $managerDn -Password $TestUserPassword
    $group = New-ADSIGroup -Name "Otel TestGroup"
    try {
        $group.Add("LDAP://CN=Otel TestUser,$usersDn")
        $group.SetInfo()
    } catch {
        Write-Log "Group membership may already exist: $_"
    }

    Set-Content -Path $MarkerFile -Value @"
domain=$DomainName
base_dn=$usersDn
manager_dn=$managerDn
user_dn=CN=Otel TestUser,$usersDn
group_dn=CN=Otel TestGroup,$usersDn
"@
    Write-Step "AD DS integration environment ready"
    Get-Content $MarkerFile
}

# ---------- main ----------

if (Test-Path $MarkerFile) {
    Write-Step "AD DS already fully configured (marker present)"
    Get-Content $MarkerFile
    exit 0
}

if (Test-ADReady) {
    Write-Step "LDAP already reachable; seeding if needed"
    Seed-TestDirectoryData
    exit 0
}

# Phase 2 entry: promotion happened earlier; only start services + seed.
if (Test-Path $Phase1Marker) {
    Write-Step "Phase 2: post-promotion / post-reboot continuation"
    Start-DirectoryServices
    $maxAttempts = 60
    for ($i = 1; $i -le $maxAttempts; $i++) {
        Start-DirectoryServices
        if (Test-ADReady) { break }
        Start-Sleep -Seconds 5
    }
    if (-not (Test-ADReady)) {
        Write-Error "Phase 2: LDAP still not ready"
        exit 1
    }
    Seed-TestDirectoryData
    exit 0
}

# Phase 1: install + promote
Set-StaticIPForDC

Write-Step "Installing AD-Domain-Services Windows feature (full AD DS, not AD LDS)"
$feature = Get-WindowsFeature -Name AD-Domain-Services
if (-not $feature.Installed) {
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
}

Install-ADDSForestOnce

Set-Content -Path $Phase1Marker -Value "promoted=$(Get-Date -Format o)"

Write-Step "Waiting for directory services without reboot"
$maxAttempts = 36  # ~3 minutes; avoid hanging the job for 7+ minutes
$ready = $false
for ($i = 1; $i -le $maxAttempts; $i++) {
    Start-DirectoryServices
    if (Test-ADReady) {
        Write-Log "LDAP ready after attempt $i"
        $ready = $true
        break
    }
    if (($i % 6) -eq 0) {
        Write-Log "Still waiting for LDAP (attempt $i/$maxAttempts)..."
        Get-Service NTDS, ADWS, DNS, Netlogon, Kdc -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Log "  $($_.Name)=$($_.Status)" }
    }
    Start-Sleep -Seconds 5
}

if ($ready) {
    Seed-TestDirectoryData
    exit 0
}

# Signal caller that a reboot is required to finish DC promotion.
Write-Step "LDAP not ready without reboot; signaling exit 42 (reboot required)"
Get-Service NTDS, ADWS, DNS, Netlogon, Kdc -ErrorAction SilentlyContinue |
    Format-Table -AutoSize | Out-String | Write-Log
exit 42
