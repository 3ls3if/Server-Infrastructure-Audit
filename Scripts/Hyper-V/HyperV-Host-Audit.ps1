#requires -Version 5.1
<#
.SYNOPSIS
  Read-only Server Infrastructure Audit - Hyper-V Host (Host-211/212/213)
.RUN
  Run in elevated Windows PowerShell 5.1 locally on each Hyper-V host.
#>
$ErrorActionPreference="Continue"
$stamp=Get-Date -Format "yyyyMMdd_HHmmss"; $root="C:\Server_Audit"
$out=Join-Path $root "$env:COMPUTERNAME`_$stamp"
New-Item -Path $out -ItemType Directory -Force | Out-Null
Start-Transcript -Path (Join-Path $out "Execution_Log.txt") -Force | Out-Null

function Save-Json { param($Name,$Data) try{$Data|ConvertTo-Json -Depth 10|Out-File (Join-Path $out "$Name.json") -Encoding UTF8}catch{"$($_.Exception.Message)"|Out-File (Join-Path $out "$Name`_ERROR.txt")} }
function Save-Csv { param($Name,$Data) try{@($Data)|Export-Csv (Join-Path $out "$Name.csv") -NoTypeInformation -Encoding UTF8}catch{"$($_.Exception.Message)"|Out-File (Join-Path $out "$Name`_ERROR.txt")} }
function Run-Text { param($Name,[scriptblock]$Command) try{& $Command 2>&1|Out-String -Width 300|Out-File (Join-Path $out "$Name.txt")}catch{"$($_.Exception.Message)"|Out-File (Join-Path $out "$Name.txt")} }

Write-Host "Starting Hyper-V host audit on $env:COMPUTERNAME" -ForegroundColor Cyan

$os=Get-CimInstance Win32_OperatingSystem; $cs=Get-CimInstance Win32_ComputerSystem
Save-Json "01_System_Inventory" ([pscustomobject]@{
    ComputerName=$env:COMPUTERNAME;Domain=$cs.Domain;Manufacturer=$cs.Manufacturer;Model=$cs.Model
    OS=$os.Caption;Version=$os.Version;Build=$os.BuildNumber;LastBoot=$os.LastBootUpTime
    SerialNumber=(Get-CimInstance Win32_BIOS).SerialNumber
    CPU=(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)
    TotalRAM_GB=[math]::Round($cs.TotalPhysicalMemory/1GB,2)
})
Save-Csv "02_Logical_Disks" (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object DeviceID,VolumeName,FileSystem,@{N="SizeGB";E={[math]::Round($_.Size/1GB,2)}},@{N="FreeGB";E={[math]::Round($_.FreeSpace/1GB,2)}},@{N="FreePercent";E={if($_.Size){[math]::Round($_.FreeSpace/$_.Size*100,2)}}})
Save-Csv "03_Physical_Disks" (Get-PhysicalDisk -ErrorAction SilentlyContinue | Select-Object FriendlyName,SerialNumber,MediaType,BusType,HealthStatus,OperationalStatus,@{N="SizeGB";E={[math]::Round($_.Size/1GB,2)}})
Save-Csv "04_Volumes" (Get-Volume -ErrorAction SilentlyContinue | Select-Object DriveLetter,FileSystemLabel,FileSystem,HealthStatus,OperationalStatus,@{N="SizeGB";E={[math]::Round($_.Size/1GB,2)}},@{N="FreeGB";E={[math]::Round($_.SizeRemaining/1GB,2)}})
Save-Json "05_Network_Adapters" (Get-NetAdapter | Select-Object Name,InterfaceDescription,Status,LinkSpeed,MacAddress,DriverInformation)
Save-Json "06_IP_Configuration" (Get-NetIPConfiguration | Select-Object InterfaceAlias,IPv4Address,IPv4DefaultGateway,DNSServer)
Save-Json "07_Firewall_Profiles" (Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction)
Save-Json "08_Defender_Status" (try{Get-MpComputerStatus|Select-Object AMServiceEnabled,AntivirusEnabled,RealTimeProtectionEnabled,AntivirusSignatureLastUpdated,AntivirusSignatureAge}catch{"Defender status unavailable"})
Save-Csv "09_Installed_Hotfixes" (Get-HotFix|Sort-Object InstalledOn -Descending|Select-Object HotFixID,Description,InstalledOn,InstalledBy)
Save-Csv "10_Auto_Service_Not_Running" (Get-CimInstance Win32_Service|Where-Object{$_.StartMode -eq "Auto" -and $_.State -ne "Running"}|Select-Object Name,DisplayName,State,StartMode,StartName)
Run-Text "11_Audit_Policy" {auditpol.exe /get /category:*}
Run-Text "12_SystemInfo" {systeminfo.exe}

if(Get-Command Get-VM -ErrorAction SilentlyContinue) {
    $vms=Get-VM
    Save-Json "13_HyperV_Host_Config" (Get-VMHost|Select-Object ComputerName,VirtualMachinePath,VirtualHardDiskPath,LogicalProcessorCount,MemoryCapacity,MaximumStorageMigrations,MaximumVirtualMachineMigrations,UseAnyNetworkForMigration)
    Save-Csv "14_VM_Inventory" ($vms|Select-Object Name,State,Status,Generation,Version,ProcessorCount,MemoryAssigned,MemoryStartup,MemoryMinimum,MemoryMaximum,DynamicMemoryEnabled,Uptime,Path,ConfigurationLocation,AutomaticStartAction,AutomaticStopAction,CheckpointType)
    Save-Csv "15_VM_Processor_Settings" (Get-VMProcessor -VMName *|Select-Object VMName,Count,Reserve,Maximum,RelativeWeight,CompatibilityForMigrationEnabled,ExposeVirtualizationExtensions)
    Save-Csv "16_VM_Memory_Settings" (Get-VMMemory -VMName *|Select-Object VMName,DynamicMemoryEnabled,Startup,Minimum,Maximum,Buffer,Priority)
    Save-Csv "17_VM_Network_Adapters" (Get-VMNetworkAdapter -VMName *|Select-Object VMName,Name,SwitchName,Status,MacAddress,DynamicMacAddressEnabled,IPAddresses,MacAddressSpoofing, DhcpGuard,RouterGuard)
    Save-Csv "18_Virtual_Switches" (Get-VMSwitch|Select-Object Name,SwitchType,NetAdapterInterfaceDescription,AllowManagementOS,EmbeddedTeamingEnabled,IovEnabled)
    Save-Csv "19_VM_Hard_Disk_Drives" (Get-VMHardDiskDrive -VMName *|Select-Object VMName,ControllerType,ControllerNumber,ControllerLocation,Path,MinimumIOPS,MaximumIOPS)
    $vhdInfo=foreach($disk in (Get-VMHardDiskDrive -VMName * -ErrorAction SilentlyContinue)){try{$v=Get-VHD -Path $disk.Path -ErrorAction Stop;[pscustomobject]@{VMName=$disk.VMName;Path=$v.Path;VhdFormat=$v.VhdFormat;VhdType=$v.VhdType;SizeGB=[math]::Round($v.Size/1GB,2);FileSizeGB=[math]::Round($v.FileSize/1GB,2);MinimumSizeGB=[math]::Round($v.MinimumSize/1GB,2);Attached=$v.Attached}}catch{[pscustomobject]@{VMName=$disk.VMName;Path=$disk.Path;Error=$_.Exception.Message}}}
    Save-Csv "20_VHD_Information" $vhdInfo
    Save-Csv "21_VM_Checkpoints" (Get-VMCheckpoint -VMName * -ErrorAction SilentlyContinue|Select-Object VMName,Name,CheckpointType,CreationTime,ParentSnapshotName)
    Save-Csv "22_VM_Replication_Status" (Get-VMReplication -ErrorAction SilentlyContinue|Select-Object VMName,Mode,State,Health,PrimaryServer,ReplicaServer,LastReplicationTime,LastReplicationResult,FrequencySec,ReplicationFrequencySec)
    Save-Csv "23_VM_Integration_Services" (Get-VMIntegrationService -VMName * -ErrorAction SilentlyContinue|Select-Object VMName,Name,Enabled,PrimaryStatusDescription,SecondaryStatusDescription)
} else {
    "Hyper-V PowerShell cmdlets not available. Verify Hyper-V role and management tools." | Out-File (Join-Path $out "HYPERV_MODULE_MISSING.txt")
}

if(Get-Command Get-Cluster -ErrorAction SilentlyContinue) {
    Save-Json "24_Failover_Cluster" ([pscustomobject]@{
        Cluster=Get-Cluster|Select-Object Name,Domain,QuorumType
        Nodes=Get-ClusterNode|Select-Object Name,State,NodeWeight,DynamicWeight
        Groups=Get-ClusterGroup|Select-Object Name,State,OwnerNode
        Networks=Get-ClusterNetwork|Select-Object Name,Address,AddressMask,Role,State
    })
} else {"Failover Clustering cmdlets unavailable or cluster feature not installed."|Out-File (Join-Path $out "CLUSTER_NOT_DETECTED.txt")}

# Relevant event channels, last 7 days
$since=(Get-Date).AddDays(-7)
foreach($log in @("System","Application","Microsoft-Windows-Hyper-V-VMMS-Admin","Microsoft-Windows-Hyper-V-Worker-Admin")) {
    $safe=$log -replace '[^A-Za-z0-9]','_'
    $events=Get-WinEvent -FilterHashtable @{LogName=$log;Level=1,2,3;StartTime=$since} -MaxEvents 500 -ErrorAction SilentlyContinue|Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message
    Save-Csv "25_Events_$safe" $events
}
Run-Text "26_HyperV_Operational_Events" {wevtutil.exe qe Microsoft-Windows-Hyper-V-VMMS-Admin /c:100 /rd:true /f:text}
@"
Server Infrastructure Audit - Hyper-V Host
Computer: $env:COMPUTERNAME
Domain: $($cs.Domain)
Collected: $(Get-Date -Format o)
Collection method: Local, read-only PowerShell
Review VM state, storage headroom, checkpoints, replication, cluster and event findings.
"@|Out-File (Join-Path $out "README.txt") -Encoding UTF8

Stop-Transcript|Out-Null
$zip=Join-Path $root "$env:COMPUTERNAME`_$stamp.zip"
Compress-Archive -Path (Join-Path $out "*") -DestinationPath $zip -Force
Write-Host "Audit collection complete: $zip" -ForegroundColor Green
