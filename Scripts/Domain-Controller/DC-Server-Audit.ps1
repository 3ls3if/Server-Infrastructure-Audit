#requires -Version 5.1
<#
.SYNOPSIS
  Read-only Server Infrastructure Audit - Domain Controller
.RUN
  Run in elevated Windows PowerShell 5.1 on the Domain Controller.
.OUTPUT
  C:\Server_Audit\<COMPUTERNAME>_<timestamp>\ with JSON, CSV, TXT and ZIP evidence.
#>

$ErrorActionPreference = "Continue"
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$root = "C:\Server_Audit"
$out = Join-Path $root "$env:COMPUTERNAME`_$stamp"
New-Item -Path $out -ItemType Directory -Force | Out-Null
Start-Transcript -Path (Join-Path $out "Execution_Log.txt") -Force | Out-Null

function Save-Json {
    param([string]$Name, $Data)
    try { $Data | ConvertTo-Json -Depth 8 | Out-File (Join-Path $out "$Name.json") -Encoding UTF8 }
    catch { "Export error: $($_.Exception.Message)" | Out-File (Join-Path $out "$Name`_ERROR.txt") }
}
function Save-Csv {
    param([string]$Name, $Data)
    try { @($Data) | Export-Csv (Join-Path $out "$Name.csv") -NoTypeInformation -Encoding UTF8 }
    catch { "Export error: $($_.Exception.Message)" | Out-File (Join-Path $out "$Name`_ERROR.txt") }
}
function Run-Text {
    param([string]$Name, [scriptblock]$Command)
    try { & $Command 2>&1 | Out-String -Width 300 | Out-File (Join-Path $out "$Name.txt") }
    catch { "Collection error: $($_.Exception.Message)" | Out-File (Join-Path $out "$Name.txt") }
}
function Get-Optional {
    param([scriptblock]$Command)
    try { & $Command } catch { [pscustomobject]@{ CollectionError = $_.Exception.Message } }
}

Write-Host "Starting Domain Controller audit on $env:COMPUTERNAME" -ForegroundColor Cyan

# 1. OS and hardware
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$sys = [pscustomobject]@{
    ComputerName=$env:COMPUTERNAME; Domain=$cs.Domain; DomainRole=$cs.DomainRole
    Manufacturer=$cs.Manufacturer; Model=$cs.Model; OS=$os.Caption; Version=$os.Version
    Build=$os.BuildNumber; InstallDate=$os.InstallDate; LastBoot=$os.LastBootUpTime
    SerialNumber=(Get-CimInstance Win32_BIOS).SerialNumber
    CPU=(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,MaxClockSpeed)
    TotalRAM_GB=[math]::Round($cs.TotalPhysicalMemory/1GB,2)
}
Save-Json "01_System_Inventory" $sys

$disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object DeviceID,VolumeName,FileSystem,
    @{N="SizeGB";E={[math]::Round($_.Size/1GB,2)}},
    @{N="FreeGB";E={[math]::Round($_.FreeSpace/1GB,2)}},
    @{N="FreePercent";E={if($_.Size){[math]::Round($_.FreeSpace/$_.Size*100,2)}}}
Save-Csv "02_Logical_Disks" $disks

$net = Get-NetIPConfiguration | Select-Object InterfaceAlias,InterfaceDescription,IPv4Address,IPv4DefaultGateway,DNSServer
Save-Json "03_Network_Configuration" $net

# 2. AD domain and forest
if (Get-Module -ListAvailable ActiveDirectory) {
    Import-Module ActiveDirectory
    $domain = Get-ADDomain
    $forest = Get-ADForest
    Save-Json "04_AD_Domain_Forest" ([pscustomobject]@{
        Domain=$domain; ForestName=$forest.Name; ForestMode=$forest.ForestMode
        ForestRootDomain=$forest.RootDomain; Domains=$forest.Domains
        GlobalCatalogs=$forest.GlobalCatalogs; Sites=$forest.Sites
    })
    Save-Csv "05_Domain_Controllers" (Get-ADDomainController -Filter * | Select-Object HostName,IPv4Address,Site,IsGlobalCatalog,IsReadOnly,OperatingSystem)

    $users = Get-ADUser -Filter * -Properties Enabled,LastLogonDate,PasswordLastSet,PasswordNeverExpires,PasswordNotRequired,LockedOut,whenCreated,whenChanged,AdminCount |
        Select-Object SamAccountName,Enabled,LastLogonDate,PasswordLastSet,PasswordNeverExpires,PasswordNotRequired,LockedOut,whenCreated,whenChanged,AdminCount
    Save-Csv "06_AD_Users" $users
    Save-Csv "07_Disabled_Users" ($users | Where-Object {-not $_.Enabled})
    Save-Csv "08_Stale_Users_90_Days" ($users | Where-Object {$_.Enabled -and $_.LastLogonDate -and $_.LastLogonDate -lt (Get-Date).AddDays(-90)})
    Save-Csv "09_Password_Never_Expires" ($users | Where-Object {$_.Enabled -and $_.PasswordNeverExpires})
    Save-Csv "10_Locked_Users" ($users | Where-Object {$_.LockedOut})

    $groups = @("Domain Admins","Enterprise Admins","Schema Admins","Administrators","Account Operators","Server Operators","Backup Operators","DnsAdmins")
    $priv = foreach($g in $groups) {
        try {
            Get-ADGroupMember -Identity $g -Recursive | Select-Object @{N="Group";E={$g}},Name,SamAccountName,ObjectClass,DistinguishedName
        } catch { [pscustomobject]@{Group=$g;CollectionError=$_.Exception.Message} }
    }
    Save-Csv "11_Privileged_Group_Members" $priv
    Save-Json "12_Default_Domain_Password_Policy" (Get-ADDefaultDomainPasswordPolicy)
    Save-Csv "13_AD_Sites" (Get-ADReplicationSite -Filter * | Select-Object Name,Description)
    Save-Csv "14_AD_Subnets" (Get-ADReplicationSubnet -Filter * | Select-Object Name,Site,Location)
    Save-Csv "15_AD_Trusts" (Get-ADTrust -Filter * | Select-Object Source,Target,Direction,TrustType,ForestTransitive)

    $gpos = Get-GPO -All | Select-Object DisplayName,Id,Owner,GpoStatus,CreationTime,ModificationTime,Description
    Save-Csv "16_Group_Policies" $gpos
    Run-Text "17_GPO_Reports_Summary" { Get-GPO -All | ForEach-Object { "`n### $($_.DisplayName)"; Get-GPOReport -Guid $_.Id -ReportType XML | Out-String } }

    Save-Csv "18_AD_Replication_Failures" (Get-ADReplicationFailure -Target * -ErrorAction SilentlyContinue |
        Select-Object Server,Partner,FailureCount,FirstFailureTime,LastError)
    Save-Csv "19_AD_Replication_Partners" (Get-ADReplicationPartnerMetadata -Target * -ErrorAction SilentlyContinue |
        Select-Object Server,Partner,Partition,LastReplicationSuccess,LastReplicationAttempt,ConsecutiveReplicationFailures,LastReplicationResult)
    Save-Csv "20_FSMO_Roles" ([pscustomobject]@{
        SchemaMaster=$forest.SchemaMaster; DomainNamingMaster=$forest.DomainNamingMaster
        PDCEmulator=$domain.PDCEmulator; RIDMaster=$domain.RIDMaster; InfrastructureMaster=$domain.InfrastructureMaster
    })
} else {
    "ActiveDirectory PowerShell module not installed; AD collection skipped." | Out-File (Join-Path $out "AD_MODULE_MISSING.txt")
}

# 3. DNS
if (Get-Module -ListAvailable DnsServer) {
    Import-Module DnsServer
    Save-Csv "21_DNS_Zones" (Get-DnsServerZone | Select-Object ZoneName,ZoneType,IsDsIntegrated,IsReverseLookupZone,ReplicationScope,DynamicUpdate)
    Save-Json "22_DNS_Forwarders" (Get-DnsServerForwarder)
    Save-Csv "23_DNS_Conditional_Forwarders" (Get-DnsServerZone | Where-Object ZoneType -eq "Forwarder" | Select-Object ZoneName,MasterServers)
} else { "DnsServer module unavailable." | Out-File (Join-Path $out "DNS_MODULE_MISSING.txt") }

# 4. Security posture and services
Save-Json "24_Firewall_Profiles" (Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction,NotifyOnListen)
Save-Json "25_Defender_Status" (Get-Optional { Get-MpComputerStatus | Select-Object AMServiceEnabled,AntivirusEnabled,AntispywareEnabled,RealTimeProtectionEnabled,BehaviorMonitorEnabled,IoavProtectionEnabled,AntivirusSignatureLastUpdated,AntivirusSignatureAge })
Save-Csv "26_Local_Admins" (Get-Optional { Get-LocalGroupMember -Group Administrators | Select-Object Name,ObjectClass,PrincipalSource })
Save-Csv "27_Auto_Service_Not_Running" (Get-CimInstance Win32_Service | Where-Object {$_.StartMode -eq "Auto" -and $_.State -ne "Running"} | Select-Object Name,DisplayName,State,StartMode,StartName)
Run-Text "28_Audit_Policy" { auditpol.exe /get /category:* }
Run-Text "29_DCDIAG" { dcdiag.exe /v }
Run-Text "30_REPLMON_SUMMARY" { repadmin.exe /replsummary }
Run-Text "31_REPLSHOWREPL" { repadmin.exe /showrepl * /csv }

# 5. Patching and event logs
Save-Csv "32_Installed_Hotfixes" (Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object HotFixID,Description,InstalledBy,InstalledOn)
$since=(Get-Date).AddDays(-14)
foreach($log in @("System","Application","Directory Service","DNS Server")) {
    $safe=$log -replace '[^A-Za-z0-9]','_'
    $events=Get-WinEvent -FilterHashtable @{LogName=$log;Level=1,2;StartTime=$since} -MaxEvents 300 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message
    Save-Csv "33_Events_$safe" $events
}
Run-Text "34_NetAccounts" { net accounts /domain }

@"
Server Infrastructure Audit - Domain Controller
Computer: $env:COMPUTERNAME
Domain: $($cs.Domain)
Collected: $(Get-Date -Format o)
Collection method: Local, read-only PowerShell
Note: Findings require review; collection output is not itself a pass/fail certification.
"@ | Out-File (Join-Path $out "README.txt") -Encoding UTF8

Stop-Transcript | Out-Null
$zip=Join-Path $root "$env:COMPUTERNAME`_$stamp.zip"
Compress-Archive -Path (Join-Path $out "*") -DestinationPath $zip -Force
Write-Host "Audit collection complete: $zip" -ForegroundColor Green
