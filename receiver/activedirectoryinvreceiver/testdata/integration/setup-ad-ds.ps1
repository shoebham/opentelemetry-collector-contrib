# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Installs and configures a full Windows Active Directory Domain Services forest
# for integration testing of the active_directory_inv receiver on GitHub Actions
# Windows runners. Uses full AD DS (not AD LDS / lightweight directory services).
#
# Install-ADDSForest normally requires a reboot. On hosted runners we cannot
# reboot mid-job, so we:
#   1. Pin a static IP (required for reliable DC promotion on DHCP runners)
#   2. Promote with -NoRebootOnCompletion
#   3. Force-start NTDS/ADWS/DNS/Netlogon/KDC and poll LDAP until ready
# This is sufficient for ADSI/LDAP integration tests in CI.

$ErrorActionPreference = "Stop"

$DomainName = if ($env:AD_DOMAIN_NAME) { $env:AD_DOMAIN_NAME } else { "oteltest.local" }
$DomainNetbiosName = if ($env:AD_NETBIOS_NAME) { $env:AD_NETBIOS_NAME } else { "OTELTEST" }
$SafeModePassword = if ($env:AD_SAFE_MODE_PASSWORD) { $env:AD_SAFE_MODE_PASSWORD } else { "P@ssw0rd123!SafeMode" }
$TestUserPassword = if ($env:AD_TEST_USER_PASSWORD) { $env:AD_TEST_USER_PASSWORD } else { "P@ssw0rd123!User" }
$MarkerFile = "C:\otel-ad-ds-ready.marker"
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
        } catch {
            # try next
        }
    }
    return $false
}

function Set-StaticIPForDC {
    Write-Step "Pinning static IPv4 on primary adapter (DHCP runners break DC DNS otherwise)"
    try {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.HardwareInterface } | Select-Object -First 1
        if (-not $adapter) {
            $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
        }
        if (-not $adapter) {
            Write-Log "WARNING: no active adapter found; skipping static IP"
            return
        }
        $ipcfg = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1
        if (-not $ipcfg) {
            Write-Log "WARNING: no usable IPv4 address; skipping static IP"
            return
        }
        $ip = $ipcfg.IPAddress
        $prefix = $ipcfg.PrefixLength
        $gw = (Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric | Select-Object -First 1).NextHop
        Write-Log "Adapter=$($adapter.Name) IP=$ip/$prefix GW=$gw"

        # Remove existing DHCP/dynamic config then re-add as static (same address).
        Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        if ($gw) {
            Remove-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -Confirm:$false -ErrorAction SilentlyContinue
        }
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -PrefixLength $prefix -ErrorAction SilentlyContinue | Out-Null
        if ($gw) {
            New-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -NextHop $gw -ErrorAction SilentlyContinue | Out-Null
        }
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($ip, "127.0.0.1") -ErrorAction SilentlyContinue
        Write-Log "Static IP applied; DNS set to $ip / 127.0.0.1"
    } catch {
        Write-Log "WARNING: Set-StaticIPForDC failed: $_"
    }
}

function Start-DirectoryServices {
    $services = @("NTDS", "ADWS", "DNS", "Netlogon", "Kdc", "W32Time")
    foreach ($svc in $services) {
        try {
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if (-not $s) { continue }
            if ($s.StartType -eq "Disabled") {
                Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue
            }
            if ($s.Status -ne "Running") {
                Start-Service -Name $svc -ErrorAction SilentlyContinue
            } else {
                # Nudge services that may be half-started post-promotion.
                Restart-Service -Name $svc -Force -ErrorAction SilentlyContinue
            }
            $s2 = Get-Service -Name $svc -ErrorAction SilentlyContinue
            Write-Log "Service $svc -> $($s2.Status)"
        } catch {
            Write-Log "Service $svc error: $_"
        }
    }
}

if (Test-Path $MarkerFile) {
    Write-Step "AD DS already configured (marker present); skipping install"
    Get-Content $MarkerFile
    exit 0
}

if (Test-ADReady) {
    Write-Step "LDAP RootDSE already reachable; writing marker and continuing"
    Set-Content -Path $MarkerFile -Value "pre-existing-ad"
    exit 0
}

Set-StaticIPForDC

Write-Step "Installing AD-Domain-Services Windows feature (full AD DS, not AD LDS)"
$feature = Get-WindowsFeature -Name AD-Domain-Services
if (-not $feature.Installed) {
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
}

Write-Step "Installing AD DS forest: $DomainName (NoRebootOnCompletion for CI)"
# ADDSDeployment is a Windows PowerShell module; load via Windows PS when possible.
$winPsScript = @"
`$ErrorActionPreference = 'Continue'
Import-Module ADDSDeployment -Force
`$securePw = ConvertTo-SecureString '$SafeModePassword' -AsPlainText -Force
Install-ADDSForest ``
    -DomainName '$DomainName' ``
    -DomainNetbiosName '$DomainNetbiosName' ``
    -SafeModeAdministratorPassword `$securePw ``
    -InstallDns:`$true ``
    -NoRebootOnCompletion:`$true ``
    -Force:`$true ``
    -CreateDnsDelegation:`$false ``
    -DatabasePath 'C:\Windows\NTDS' ``
    -LogPath 'C:\Windows\NTDS' ``
    -SysvolPath 'C:\Windows\SYSVOL' | Format-List | Out-String
"@

$winPsScriptPath = "$env:TEMP\otel-install-addsforest.ps1"
Set-Content -Path $winPsScriptPath -Value $winPsScript -Encoding UTF8
try {
    $out = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $winPsScriptPath 2>&1
    Write-Log ($out | Out-String)
} catch {
    Write-Log "Install-ADDSForest via Windows PowerShell failed: $_"
    # Fallback: try in current session
    try {
        Import-Module ADDSDeployment -SkipEditionCheck -Force -ErrorAction SilentlyContinue
        Import-Module ADDSDeployment -Force -ErrorAction SilentlyContinue
        $securePw = ConvertTo-SecureString $SafeModePassword -AsPlainText -Force
        Install-ADDSForest `
            -DomainName $DomainName `
            -DomainNetbiosName $DomainNetbiosName `
            -SafeModeAdministratorPassword $securePw `
            -InstallDns:$true `
            -NoRebootOnCompletion:$true `
            -Force:$true `
            -CreateDnsDelegation:$false `
            -DatabasePath "C:\Windows\NTDS" `
            -LogPath "C:\Windows\NTDS" `
            -SysvolPath "C:\Windows\SYSVOL"
    } catch {
        Write-Log "Fallback Install-ADDSForest error: $_"
    }
}

Write-Step "Waiting for directory services (post-promotion, no reboot)"
$maxAttempts = 90
$ready = $false
for ($i = 1; $i -le $maxAttempts; $i++) {
    Start-DirectoryServices
    if (Test-ADReady) {
        Write-Log "LDAP RootDSE reachable after attempt $i"
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

if (-not $ready) {
    Write-Step "LDAP still not ready; dumping diagnostics then failing"
    Get-Service NTDS, ADWS, DNS, Netlogon, Kdc -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String | Write-Log
    if (Test-Path "C:\Windows\debug\dcpromo.log") {
        Write-Log "---- tail dcpromo.log ----"
        Get-Content "C:\Windows\debug\dcpromo.log" -Tail 40 | ForEach-Object { Write-Log $_ }
    }
    Write-Error "Active Directory did not become ready within timeout (reboot normally required; service force-start insufficient on this runner)"
    exit 1
}

# Point DNS at local DC for name resolution
try {
    Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
        Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses @("127.0.0.1") -ErrorAction SilentlyContinue
    }
} catch {}

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
    $user.Put("userAccountControl", 512) # NORMAL_ACCOUNT
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
    $group.Put("groupType", -2147483646) # Global security group
    $group.SetInfo()
    return $group
}

$manager = New-ADSIUser -Name "Otel Manager" -SamAccountName "otelmanager" `
    -Mail "otelmanager@$DomainName" -Department "Engineering" -Password $TestUserPassword

$managerDn = "CN=Otel Manager,$usersDn"

$user = New-ADSIUser -Name "Otel TestUser" -SamAccountName "oteltestuser" `
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
exit 0
