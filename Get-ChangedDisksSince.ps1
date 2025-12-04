
<#
.SYNOPSIS
  Ermittelt Azure Managed Disks mit Aenderungen seit einem Stichtag:
  - Neue / geloeschte / geaenderte Disks (Activity Logs, ~90 Tage Historie)
  - Attach/Detach von Disks an VMs (aus VM write Events)
  - Optional: Neu erstellte Disks via Azure Resource Graph (ARG) mit properties['timeCreated'] (falls vorhanden)
  - Saubere Pagination und CSV Exporte

.PARAMETER TenantId
  Ziel Tenant GUID.

.PARAMETER StartDate
  Stichtag; Ereignisse >= StartDate werden erfasst.

.PARAMETER IncludeSubscriptions / ExcludeSubscriptions
  Optional: Subscription-Namen oder -IDs zum Ein-/Ausschliessen.

.PARAMETER CsvPath
  Optional: CSV Ausgabepfad fuer Disk Changes. Wenn leer, wird C:\Temp\Disk_Changes_since_yyyyMMdd.csv verwendet.
  Die Attach/Detach CSV wird nebenbei als C:\Temp\Disk_AttachDetach_since_yyyyMMdd.csv geschrieben, oder analog zum Ordner von CsvPath.

.NOTES
  Erfordert: Az.Accounts, Az.Resources; optional Az.ResourceGraph.
  Activity Logs decken typischerweise nur ~90 Tage ab.
#>

param(
  [string]   $TenantId = '0e560cfc-3cc9-4cb9-ab5b-acaf8aaeed4d',
  [datetime] $StartDate = [datetime]'2025-10-27',
  [string[]] $IncludeSubscriptions = @(),
  [string[]] $ExcludeSubscriptions = @(),
  [string]   $CsvPath = ''
)

# ---------------------------
# Helpers
function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err ($msg) { Write-Host "[ERR ] $msg" -ForegroundColor Red }

function Test-ArgAvailable {
  try {
    $mod = Get-Module -ListAvailable -Name Az.ResourceGraph
    if (-not $mod) { return $false }
    Import-Module Az.ResourceGraph -ErrorAction Stop
    return $true
  }
  catch { return $false }
}

function Invoke-ArgQuery {
  param(
    [Parameter(Mandatory)] [string] $Query,
    [Parameter(Mandatory)] [string[]] $SubscriptionIds
  )
  $all = @()
  try {
    $resp = Search-AzGraph -Query $Query -Subscription $SubscriptionIds -First 1000
    if ($resp -and $resp.Data) { $all += $resp.Data }
    $token = $resp.SkipToken
    while ($token) {
      $resp = Search-AzGraph -Query $Query -Subscription $SubscriptionIds -First 1000 -SkipToken $token
      if ($resp -and $resp.Data) { $all += $resp.Data }
      $token = $resp.SkipToken
    }
  }
  catch {
    Write-Warn ("ARG query error: {0}" -f $_.Exception.Message)
  }
  return $all
}

function Ensure-Dir($path) {
  if (-not (Test-Path $path)) { New-Item -Path $path -ItemType Directory -Force | Out-Null }
}

# Extract JSON-like payload from ActivityLog, if present
function Get-ActivityJson {
  param([object]$op)
  try { if ($op.Properties) { return ($op.Properties | ConvertTo-Json -Depth 12) } } catch {}
  try { if ($op.StatusMessage) { return [string]$op.StatusMessage } } catch {}
  return $null
}

# Try to parse a simple field from JSON text (best-effort)
function Try-Parse-Field {
  param([string]$json, [string]$fieldName)
  if ([string]::IsNullOrWhiteSpace($json)) { return $null }
  $pattern = '"{0}"\s*:\s*(\d+|"(?:[^"\\]|\\.)*")' -f [regex]::Escape($fieldName)
  $m = [regex]::Match($json, $pattern)
  if ($m.Success) {
    $val = $m.Groups[1].Value
    if ($val -match '^\d+$') { return [int]$val }
    return ($val -replace '^"|"$','')
  }
  return $null
}

# Extract managedDisk.id occurrences from VM JSON payload
function Extract-DiskIdsFromVmJson {
  param([string]$json)
  $ids = New-Object System.Collections.Generic.HashSet[string]
  if ([string]::IsNullOrWhiteSpace($json)) { return $ids }
  $pattern = '"managedDisk"\s*:\s*\{[^}]*"id"\s*:\s*"([^"]+)"'
  foreach ($m in [regex]::Matches($json, $pattern)) { $null = $ids.Add($m.Groups[1].Value) }
  return $ids
}

# Parse Azure ResourceId parts
function Parse-ResourceId {
  param([string]$rid)
  $result = [ordered]@{
    SubscriptionId = $null
    ResourceGroup  = $null
    Provider       = $null
    Type           = $null
    Name           = $null
  }
  if ([string]::IsNullOrWhiteSpace($rid)) { return $result }
  $parts = $rid -split '/'
  if ($parts.Length -ge 3) { $result.SubscriptionId = $parts[2] }
  if ($parts.Length -ge 5) { $result.ResourceGroup  = $parts[4] }
  if ($parts.Length -ge 7) { $result.Provider       = "$($parts[6])/$($parts[7])" }
  if ($parts.Length -ge 9) { $result.Type           = $parts[7] ; $result.Name = $parts[8] }
  return $result
}

# ---------------------------
# 0) Setup Output paths
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
  $CsvPath = "C:\Temp\Disk_Changes_since_$($StartDate.ToString('yyyyMMdd')).csv"
}
$csvDir = Split-Path -Path $CsvPath -Parent
Ensure-Dir -path $csvDir
$attachCsv = Join-Path $csvDir ("Disk_AttachDetach_since_{0}.csv" -f $StartDate.ToString('yyyyMMdd'))

Write-Info ("TenantId: {0}" -f $TenantId)
Write-Info ("StartDate: {0}" -f $StartDate.ToString('u'))
Write-Info ("CSV (Disk Changes): {0}" -f $CsvPath)
Write-Info ("CSV (Attach/Detach): {0}" -f $attachCsv)

# ---------------------------
# 1) Login in Tenant
try {
  Connect-AzAccount -TenantId $TenantId -WarningAction SilentlyContinue | Out-Null
  Write-Info "Login successful."
}
catch {
  Write-Err ("Login failed: {0}" -f $_.Exception.Message)
  exit 1
}

# ---------------------------
# 2) Get subscriptions and apply filters
try {
  $subsObj = Get-AzSubscription -TenantId $TenantId
}
catch {
  Write-Err ("Cannot read subscriptions: {0}" -f $_.Exception.Message)
  exit 1
}

if ($IncludeSubscriptions.Count -gt 0) {
  $subsObj = $subsObj | Where-Object { ($IncludeSubscriptions -contains $_.Id) -or ($IncludeSubscriptions -contains $_.Name) }
}
if ($ExcludeSubscriptions.Count -gt 0) {
  $subsObj = $subsObj | Where-Object { -not ($ExcludeSubscriptions -contains $_.Id -or $ExcludeSubscriptions -contains $_.Name) }
}

if (-not $subsObj -or $subsObj.Count -eq 0) {
  Write-Warn "No subscriptions remain after filtering. Exiting."
  exit 0
}

$subIds = $subsObj | Select-Object -ExpandProperty Id
Write-Info ("Processing {0} subscription(s)." -f $subIds.Count)

# ---------------------------
# 3) Optional ARG: newly created disks since StartDate
$argAvailable = Test-ArgAvailable
$newDisksArg = @()
if ($argAvailable) {
  $startIso = $StartDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
  $qNewDisks = @"
resources
| where type =~ 'microsoft.compute/disks'
| extend timeCreated = todatetime(properties['timeCreated'])
| where isnotempty(timeCreated) and timeCreated >= datetime($startIso)
| project
    name,
    subscriptionId,
    resourceGroup,
    location,
    timeCreated,
    diskSizeGB = tolong(properties['diskSizeGB']),
    sku        = tostring(sku.name),
    osType     = tostring(properties['osType']),
    managedBy  = tostring(properties['managedBy']),
    encryption = tostring(properties['encryption']['type'])
"@
  Write-Info ("ARG: loading new disks since {0} ..." -f $startIso)
  $newDisksArg = Invoke-ArgQuery -Query $qNewDisks -SubscriptionIds $subIds
  Write-Info ("ARG new disks count: {0}" -f $newDisksArg.Count)
} else {
  Write-Warn "Az.ResourceGraph not available; new disks will be detected only via Activity Logs."
}

# ---------------------------
# 4) Activity Logs: disk changes and VM attach/detach events
$diskChanges   = New-Object System.Collections.Generic.List[object]
$attachChanges = New-Object System.Collections.Generic.List[object]
$vmEventsByVm  = @{} # key: "{subId}|{rg}|{vmName}" -> List of events with disk id sets

$endDate = Get-Date

foreach ($sub in $subsObj) {
  try { Set-AzContext -SubscriptionId $sub.Id -Tenant $TenantId | Out-Null }
  catch { Write-Warn ("Set-AzContext failed for {0}: {1}" -f $sub.Name, $_.Exception.Message); continue }

  Write-Info ("Reading Activity Logs (Disks) in subscription: {0} ..." -f $sub.Name)
  try {
    $logDisks = Get-AzActivityLog -StartTime $StartDate -EndTime $endDate -WarningAction SilentlyContinue |
      Where-Object { $_.ResultType -eq 'Success' -and $_.EventTimestamp -ge $StartDate -and $_.ResourceType -eq 'Microsoft.Compute/disks' }
    
    foreach ($op in $logDisks) {
      $ridInfo = Parse-ResourceId $op.ResourceId
      $json    = Get-ActivityJson $op

      $sizeReq = Try-Parse-Field -json $json -fieldName 'diskSizeGB'
      $skuReq  = Try-Parse-Field -json $json -fieldName 'name'
      $encReq  = Try-Parse-Field -json $json -fieldName 'encryptionType'

      $changeType = 'Updated'
      $opNameVal  = [string]$op.OperationNameValue
      if ($opNameVal -match '/delete$') { $changeType = 'Deleted' }
      elseif ($opNameVal -match '/write$') { $changeType = 'Updated' }
      elseif ($opNameVal -match '/create$') { $changeType = 'Created' }

      $diskChanges.Add([PSCustomObject]@{
        ChangeType      = $changeType
        DiskName        = $ridInfo.Name
        SubscriptionId  = $ridInfo.SubscriptionId
        ResourceGroup   = $ridInfo.ResourceGroup
        Location        = $op.ResourceGroupName
        EventTime       = $op.EventTimestamp
        Operation       = $op.OperationNameValue
        Caller          = $op.Caller
        RequestedSizeGB = $sizeReq
        RequestedSku    = $skuReq
        RequestedEnc    = $encReq
        Source          = 'ActivityLog'
        ResourceId      = $op.ResourceId
        CorrelationId   = $op.CorrelationId
      })
    }
  }
  catch {
    Write-Warn ("Reading disk Activity Logs failed: {0}" -f $_.Exception.Message)
  }

  Write-Info ("Reading Activity Logs (VM writes) for attach/detach: {0} ..." -f $sub.Name)
  try {
    $logVms = Get-AzActivityLog -StartTime $StartDate -EndTime $endDate -WarningAction SilentlyContinue |
      Where-Object { $_.ResultType -eq 'Success' -and $_.EventTimestamp -ge $StartDate -and $_.ResourceType -eq 'Microsoft.Compute/virtualMachines' -and $_.OperationNameValue -like 'Microsoft.Compute/virtualMachines/write' }

    foreach ($op in $logVms) {
      $ridInfo = Parse-ResourceId $op.ResourceId
      $json    = Get-ActivityJson $op
      $diskIds = Extract-DiskIdsFromVmJson -json $json

      $key = ("{0}|{1}|{2}" -f $ridInfo.SubscriptionId, $ridInfo.ResourceGroup, $ridInfo.Name)
      if (-not $vmEventsByVm.ContainsKey($key)) {
        $vmEventsByVm[$key] = New-Object System.Collections.Generic.List[object]
      }
      $vmEventsByVm[$key].Add([PSCustomObject]@{
        Time    = $op.EventTimestamp
        DiskIds = $diskIds
        Vm      = $ridInfo.Name
        SubId   = $ridInfo.SubscriptionId
        Rg      = $ridInfo.ResourceGroup
        Json    = $json
        CorrId  = $op.CorrelationId
      })
    }
  }
  catch {
    Write-Warn ("Reading VM Activity Logs failed: {0}" -f $_.Exception.Message)
  }
}

# Derive attach/detach changes from VM event sequences
foreach ($key in $vmEventsByVm.Keys) {
  $seq = $vmEventsByVm[$key] | Sort-Object Time
  for ($i = 1; $i -lt $seq.Count; $i++) {
    $prev = $seq[$i-1]
    $curr = $seq[$i]

    $prevIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($id in $prev.DiskIds) { $null = $prevIds.Add($id) }

    $currIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($id in $curr.DiskIds) { $null = $currIds.Add($id) }

    # Attached: present in current, missing in previous
    foreach ($id in $currIds) {
      if (-not $prevIds.Contains($id)) {
        $attachChanges.Add([PSCustomObject]@{
          ChangeType     = 'Attached'
          VmName         = $curr.Vm
          SubscriptionId = $curr.SubId
          ResourceGroup  = $curr.Rg
          DiskId         = $id
          EventTime      = $curr.Time
          Source         = 'ActivityLog(VM write)'
          CorrelationId  = $curr.CorrId
        })
      }
    }
    # Detached: present in previous, missing in current
    foreach ($id in $prevIds) {
      if (-not $currIds.Contains($id)) {
        $attachChanges.Add([PSCustomObject]@{
          ChangeType     = 'Detached'
          VmName         = $prev.Vm
          SubscriptionId = $prev.SubId
          ResourceGroup  = $prev.Rg
          DiskId         = $id
          EventTime      = $curr.Time
          Source         = 'ActivityLog(VM write)'
          CorrelationId  = $curr.CorrId
        })
      }
    }
  }
}

# Optional ARG enrichment: disk metadata lookup for Location and current size/sku
if ($argAvailable) {
  Write-Info "ARG enrichment: loading disk metadata ..."
  $qDiskMeta = @"
resources
| where type =~ 'microsoft.compute/disks'
| project diskName = name, subscriptionId, resourceGroup, location, managedBy = tostring(properties['managedBy']), diskSizeGB = tolong(properties['diskSizeGB']), sku = tostring(sku.name)
"@
  $diskMeta = Invoke-ArgQuery -Query $qDiskMeta -SubscriptionIds $subIds
  $indexDisk = @{}
  foreach ($m in $diskMeta) {
    $key = ("{0}|{1}|{2}" -f $m.subscriptionId.ToLower(), $m.resourceGroup.ToLower(), $m.diskName.ToLower())
    $indexDisk[$key] = $m
  }

  foreach ($row in $diskChanges) {
    $key = ("{0}|{1}|{2}" -f $row.SubscriptionId.ToLower(), $row.ResourceGroup.ToLower(), $row.DiskName.ToLower())
    if ($indexDisk.ContainsKey($key)) {
      $meta = $indexDisk[$key]
      $row.Location = $meta.location
      if (-not $row.PSObject.Properties.Match('CurrentSizeGB')) {
        $row | Add-Member -NotePropertyName CurrentSizeGB -NotePropertyValue $meta.diskSizeGB -Force
      }
      if (-not $row.PSObject.Properties.Match('CurrentSku')) {
        $row | Add-Member -NotePropertyName CurrentSku -NotePropertyValue $meta.sku -Force
      }
      if (-not $row.PSObject.Properties.Match('ManagedBy')) {
        $row | Add-Member -NotePropertyName ManagedBy -NotePropertyValue $meta.managedBy -Force
      }
    }
  }
}

# Integrate ARG new disks (if not already present from Activity Logs)
foreach ($d in $newDisksArg) {
  $exists = $diskChanges | Where-Object {
    $_.ChangeType -eq 'Created' -and
    $_.SubscriptionId -eq $d.subscriptionId -and
    $_.ResourceGroup  -eq $d.resourceGroup  -and
    $_.DiskName       -eq $d.name
  }
  if (-not $exists) {
    $diskChanges.Add([PSCustomObject]@{
      ChangeType      = 'Created'
      DiskName        = $d.name
      SubscriptionId  = $d.subscriptionId
      ResourceGroup   = $d.resourceGroup
      Location        = $d.location
      EventTime       = $d.timeCreated
      Operation       = 'ARG: timeCreated'
      Caller          = $null
      RequestedSizeGB = $d.diskSizeGB
      RequestedSku    = $d.sku
      RequestedEnc    = $d.encryption
      Source          = 'ARG'
      ResourceId      = $null
      CorrelationId   = $null
      ManagedBy       = $d.managedBy
    })
  }
}

# ---------------------------
# 5) Export CSVs
$diskChanges   | Sort-Object EventTime | Export-Csv -Path $CsvPath   -NoTypeInformation -Encoding UTF8
$attachChanges | Sort-Object EventTime | Export-Csv -Path $attachCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Info ("Done. Disk changes: {0} entries" -f $diskChanges.Count)
Write-Info ("Done. Attach/Detach: {0} entries" -f $attachChanges.Count)
Write-Info ("Export: {0}" -f $CsvPath)
Write-Info ("Export: {0}" -f $attachCsv)
