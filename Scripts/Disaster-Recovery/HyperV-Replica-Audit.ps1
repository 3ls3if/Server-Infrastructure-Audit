#requires -Version 5.1
<#
.SYNOPSIS
  Read-only Server Infrastructure Audit - Hyper-V Replica Host (Host-214-Replica)
.RUN
  Run in elevated Windows PowerShell 5.1 locally on the replica server.
#>
$ErrorActionPreference="Continue"
$stamp=Get-Date -Format "yyyyMMdd_HHmmss"; $root="C:\Server_Audit"
$out=Join-Path $root "$env:COMPUTERNAME`_$stamp"
New-Item -Path $out -ItemType Directory -Force|Out-Null
Start-Transcript -Path (Join-Path $out "Execution_Log.txt") -Force|Out-Null

function Save-Json {param($Name,$Data) try{$Data|ConvertTo-Json -Depth 10|Out-File (Join-Path $out "$Name.json") -Encoding UTF8}catch{"$($_.Exception.Message)"|Out-File (Join-Path $out "$Name`_ERROR.txt")}}
function Save-Csv {param($Name,$Data) try{@($Data)|Export-Csv (Join-Path $out "$Name.csv") -NoTypeInformation -Encoding UTF8}catch{"$($_.Exception.Message)"|Out-File (Join-Path $out "$Name`_ERROR.txt")}}
function Run-Text {param($Name,[scriptblock]$Command) try{& $Command 2>&1|Out-String -Width 300|Out-File (Join-Path $out "$Name.txt")}catch{"$($_.Exception.Message)"|Out-File (Join-Path $out "$Name.txt")}}

Write-Host "Starting Hyper-V Replica audit on $env:COMPUTERNAME" -ForegroundColor Cyan
$os=Get-CimInstance Win32_OperatingSystem;$cs=Get-CimInstance Win32_ComputerSystem
Save-Json "01_System_Inventory" ([pscustomobject]@{
    ComputerName=$env:COMPUTERNAME;Domain=$cs.Domain;OS=$os.Caption;Version=$os.Version;Build=$os.BuildNumber
    LastBoot=$os.LastBootUpTime;Manufacturer=$cs.Manufacturer;Model=$cs.Model
    CPU=(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)
    TotalRAM_GB=[math]::Round($cs.TotalPhysicalMemory/1GB,2)
})
Save-Csv "02_Storage" (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3"|Select-Object DeviceID,VolumeName,FileSystem,@{N="SizeGB";E={[math]::Round($_.Size/1GB,2)}},@{N="FreeGB";E={[math]::Round($_.FreeSpace/1GB,2)}},@{N="FreePercent";E={if($_.Size){[math]::Round($_.FreeSpace/$_.Size*100,2)}}})
Save-Csv "03_Physical_Disks" (Get-PhysicalDisk -ErrorAction SilentlyContinue|Select-Object FriendlyName,MediaType,HealthStatus,OperationalStatus,@{N="SizeGB";E={[math]::Round($_.Size/1GB,2)}})
Save-Json "04_Network" (Get-NetIPConfiguration|Select-Object InterfaceAlias,IPv4Address,IPv4DefaultGateway,DNSServer)
Save-Json "05_Firewall" (Get-NetFirewallProfile|Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction)
Save-Json "06_Defender" (try{Get-MpComputerStatus|Select-Object AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,AntivirusSignatureAge}catch{"Defender status unavailable"})
Save-Csv "07_Hotfixes" (Get-HotFix|Sort-Object InstalledOn -Descending|Select-Object HotFixID,Description,InstalledOn,InstalledBy)

# Replica server configuration and authorization settings
if(Get-Command Get-VMReplicationServer -ErrorAction SilentlyContinue) {
    Save-Json "08_Replica_Server_Configuration" (Get-VMReplicationServer|Select-Object ComputerName,ReplicationEnabled,AllowedAuthenticationType,KerberosAuthenticationPort,CertificateAuthenticationPort,ReplicationAllowedFromAnyServer,DefaultStorageLocation,MaximumStorageSize,MinimumFreeDiskSpace)
    Save-Csv "09_Replica_Authorization_Entries" (Get-VMReplicationAuthorizationEntry -ErrorAction SilentlyContinue|Select-Object AllowedPrimaryServer,ReplicaStorageLocation,TrustGroup)
} else {"Hyper-V Replica cmdlets unavailable. Check Hyper-V role and management tools."|Out-File (Join-Path $out "HYPERV_REPLICA_CMDLETS_MISSING.txt")}

if(Get-Command Get-VM -ErrorAction SilentlyContinue) {
    Save-Csv "10_VM_Inventory" (Get-VM|Select-Object Name,State,Status,Generation,Version,ProcessorCount,MemoryAssigned,MemoryStartup,DynamicMemoryEnabled,Uptime,Path,ConfigurationLocation)
    Save-Csv "11_Inbound_Replication_Status" (Get-VMReplication -ErrorAction SilentlyContinue|Select-Object VMName,Mode,State,Health,PrimaryServer,ReplicaServer,LastReplicationTime,LastReplicationResult,FrequencySec,ReplicationFrequencySec,ReplicationMode,AuthType)
    Save-Csv "12_Replication_Health" (Get-VMReplication -ErrorAction SilentlyContinue|Select-Object VMName,State,Health,LastReplicationTime,LastReplicationResult,PendingReplicationSize,AverageReplicationSize,ReplicationHealth)
    Save-Csv "13_Replica_VM_Disks" (Get-VMHardDiskDrive -VMName * -ErrorAction SilentlyContinue|Select-Object VMName,ControllerType,ControllerNumber,ControllerLocation,Path)
    Save-Csv "14_Replica_Checkpoints" (Get-VMCheckpoint -VMName * -ErrorAction SilentlyContinue|Select-Object VMName,Name,CheckpointType,CreationTime)
    Save-Csv "15_Virtual_Switches" (Get-VMSwitch -ErrorAction SilentlyContinue|Select-Object Name,SwitchType,NetAdapterInterfaceDescription,AllowManagementOS)
} else {"Hyper-V cmdlets unavailable."|Out-File (Join-Path $out "HYPERV_MODULE_MISSING.txt")}

# Check free space at default replica location, if reported
try {
    $replicaConfig=Get-VMReplicationServer
    $loc=$replicaConfig.DefaultStorageLocation
    if($loc -and (Test-Path $loc)) {
        $drive=[IO.Path]::GetPathRoot($loc)
        $vol=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($drive.TrimEnd('\'))'"
        Save-Json "16_Replica_Storage_Location" ([pscustomobject]@{DefaultStorageLocation=$loc;Drive=$drive;TotalGB=[math]::Round($vol.Size/1GB,2);FreeGB=[math]::Round($vol.FreeSpace/1GB,2);FreePercent=[math]::Round($vol.FreeSpace/$vol.Size*100,2)})
    }
} catch {"Unable to inspect default replica storage location: $($_.Exception.Message)"|Out-File (Join-Path $out "16_Replica_Storage_Location_ERROR.txt")}

Run-Text "17_Replica_Server_Settings_Command" {Get-VMReplicationServer|Format-List *}
Run-Text "18_Replication_Broker_And_Listeners" {Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue|Where-Object{$_.LocalPort -in 80,443,135,445,3343,8080,8081}|Select-Object LocalAddress,LocalPort,OwningProcess}
$since=(Get-Date).AddDays(-14)
foreach($log in @("System","Application","Microsoft-Windows-Hyper-V-VMMS-Admin","Microsoft-Windows-Hyper-V-Worker-Admin","Microsoft-Windows-Hyper-V-Replica-Admin","Microsoft-Windows-Hyper-V-Replica-Operational")) {
    $safe=$log -replace '[^A-Za-z0-9]','_'
    $events=Get-WinEvent -FilterHashtable @{LogName=$log;Level=1,2,3;StartTime=$since} -MaxEvents 500 -ErrorAction SilentlyContinue|Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message
    Save-Csv "19_Events_$safe" $events
}
@"
Server Infrastructure Audit - Hyper-V Replica
Computer: $env:COMPUTERNAME
Domain: $($cs.Domain)
Collected: $(Get-Date -Format o)
Collection method: Local, read-only PowerShell
Important: Replica health must be checked alongside the primary host and actual recovery/ failover testing.
"@|Out-File (Join-Path $out "README.txt") -Encoding UTF8

Stop-Transcript|Out-Null
$zip=Join-Path $root "$env:COMPUTERNAME`_$stamp.zip"
Compress-Archive -Path (Join-Path $out "*") -DestinationPath $zip -Force
Write-Host "Audit collection complete: $zip" -ForegroundColor Green
