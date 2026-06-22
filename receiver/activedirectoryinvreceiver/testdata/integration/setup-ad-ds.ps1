# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0
#
# Installs and configures a full Windows Active Directory Domain Services forest
# for integration testing of the active_directory_inv receiver on GitHub Actions
# Windows runners. Uses full AD DS (not AD LDS / lightweight directory services).

$ErrorActionPreference = "Stop"

$DomainName = if ($env:AD_DOMAIN_NAME) { $env:AD_DOMAIN_NAME } else { "oteltest.local" }
$DomainNetbiosName = if ($env:AD_NETBIOS_NAME) { $env:AD_NETBIOS_NAME } else { "OTELTEST" }
$SafeModePassword = if ($env:AD_SAFE_MODE_PASSWORD) { $env:AD_SAFE_MODE_PASSWORD } else { "P@ssw0rd123!SafeMode" }
$TestUserPassword = if ($env:AD_TEST_USER_PASSWORD) { $env:AD_TEST_USER_PASSWORD } else { "P@ssw0rd123!User" }
$MarkerFile = "C:\otel-ad-ds-ready.marker"

function Write-Step($msg) {
    Write-Host "==== $msg ====" -ForegroundColor Cyan
}

function Test-ADReady {
    try {
        $root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://RootDSE")
        $null = $root.Properties["defaultNamingContext"].Value
        return $true
    } catch {
        return $false
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

Write-Step "Installing AD-Domain-Services Windows feature (full AD DS, not AD LDS)"
$feature = Get-WindowsFeature -Name AD-Domain-Services
if (-not $feature.Installed) {
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
}

Write-Step "Installing AD DS forest: $DomainName (NoRebootOnCompletion for CI)"
Import-Module ADDSDeployment -ErrorAction Stop
$securePw = ConvertTo-SecureString $SafeModePassword -AsPlainText -Force

$installParams = @{
    DomainName                    = $DomainName
    DomainNetbiosName             = $DomainNetbiosName
    SafeModeAdministratorPassword = $securePw
    InstallDns                    = $true
    NoRebootOnCompletion          = $true
    Force                         = $true
    CreateDnsDelegation           = $false
    DatabasePath                  = "C:\Windows\NTDS"
    LogPath                       = "C:\Windows\NTDS"
    SysvolPath                    = "C:\Windows\SYSVOL"
}

try {
    Install-ADDSForest @installParams
} catch {
    # Install-ADDSForest may report a non-terminating error if a reboot is pending; verify LDAP instead.
    Write-Warning "Install-ADDSForest returned: $_"
}

Write-Step "Waiting for directory services"
$maxAttempts = 60
for ($i = 1; $i -le $maxAttempts; $i++) {
    $services = @("NTDS", "ADWS", "DNS", "Netlogon", "Kdc")
    foreach ($svc in $services) {
        try {
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($s -and $s.Status -ne "Running") {
                Start-Service -Name $svc -ErrorAction SilentlyContinue
            }
        } catch {}
    }

    if (Test-ADReady) {
        Write-Host "LDAP RootDSE reachable after attempt $i"
        break
    }
    Start-Sleep -Seconds 5
}

if (-not (Test-ADReady)) {
    Write-Error "Active Directory did not become ready within timeout"
    exit 1
}

# Point DNS at local DC for name resolution
try {
    Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
        Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses @("127.0.0.1") -ErrorAction SilentlyContinue
    }
} catch {}

Write-Step "Seeding integration test users and groups"
# Use DirectoryServices directly so we do not depend on ADWS / RSAT cmdlets post-install.
$domainParts = $DomainName.Split(".")
$baseDn = ($domainParts | ForEach-Object { "DC=$_" }) -join ","
$usersDn = "CN=Users,$baseDn"

function New-ADSIUser {
    param(
        [string]$Name,
        [string]$SamAccountName,
        [string]$Mail,
        [string]$Department,
        [string]$ManagerDn,
        [string]$Password
    )
    $users = [ADSI]"LDAP://$usersDn"
    $existing = $null
    try {
        $existing = [ADSI]"LDAP://CN=$Name,$usersDn"
        if ($existing.Path) {
            Write-Host "User $Name already exists"
            return $existing
        }
    } catch {}

    $user = $users.Create("user", "CN=$Name")
    $user.Put("sAMAccountName", $SamAccountName)
    $user.Put("userPrincipalName", "$SamAccountName@$DomainName")
    $user.Put("displayName", $Name)
    if ($Mail) { $user.Put("mail", $Mail) }
    if ($Department) { $user.Put("department", $Department) }
    if ($ManagerDn) { $user.Put("manager", $ManagerDn) }
    $user.SetInfo()

    # Set password and enable account
    $user.Invoke("SetPassword", $Password)
    $user.Put("userAccountControl", 512) # NORMAL_ACCOUNT
    $user.SetInfo()
    return $user
}

function New-ADSIGroup {
    param([string]$Name)
    $users = [ADSI]"LDAP://$usersDn"
    try {
        $g = [ADSI]"LDAP://CN=$Name,$usersDn"
        if ($g.Path) {
            Write-Host "Group $Name already exists"
            return $g
        }
    } catch {}
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
    Write-Host "Group membership may already exist: $_"
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
