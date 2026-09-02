param(
  [string]$PortName = "COM8",
  [int]$BaudRate = 9600,
  [ValidateRange(0, 100)]
  [int]$LeftPwm = 8,
  [ValidateRange(0, 100)]
  [int]$RightPwm = 8,
  [ValidateRange(0, 100000)]
  [uint32]$Pulses = 0,
  [ValidateRange(1000, 60000)]
  [int]$SafetyLockMs = 58000,
  [ValidateRange(1, 10)]
  [int]$LockRepeat = 3,
  [ValidateRange(20, 1000)]
  [int]$LockIntervalMs = 200,
  [string]$ConfigPath = "",
  [string]$LogPath = "",
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Get-Crc16Ccitt {
  param([byte[]]$Data)

  [int]$crc = 0xFFFF
  foreach ($b in $Data) {
    $crc = $crc -bxor ([int]$b -shl 8)
    for ($i = 0; $i -lt 8; $i++) {
      if (($crc -band 0x8000) -ne 0) {
        $crc = (($crc -shl 1) -bxor 0x1021) -band 0xFFFF
      } else {
        $crc = ($crc -shl 1) -band 0xFFFF
      }
    }
  }
  return $crc
}

function New-ControlPacket {
  param(
    [byte]$TargetAddrHigh,
    [byte]$TargetAddrLow,
    [byte]$Channel,
    [byte]$LeftPwm,
    [byte]$RightPwm,
    [uint32]$Pulses,
    [bool]$Locked
  )

  [byte[]]$flags = if ($Locked) {
    @(0x07, 0x00, 0x00, 0x00)
  } else {
    @(0x00, 0x00, 0x00, 0x00)
  }

  [byte[]]$payload = @(
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00
  ) + $flags + @(
    $LeftPwm,
    $RightPwm,
    0x00, 0x00,
    [byte]($Pulses -band 0xFF),
    [byte](($Pulses -shr 8) -band 0xFF),
    [byte](($Pulses -shr 16) -band 0xFF),
    [byte](($Pulses -shr 24) -band 0xFF),
    0x00, 0x00, 0x00, 0x00
  )

  [byte[]]$frameNoCrc = @(
    0xAA, 0x55,
    0x1C, 0x00,
    0x11,
    0x01
  ) + $payload

  $crc = Get-Crc16Ccitt $frameNoCrc
  [byte[]]$agvFrame = $frameNoCrc + @(
    [byte]($crc -band 0xFF),
    [byte](($crc -shr 8) -band 0xFF),
    0x0D, 0x0A
  )

  return [byte[]](@($TargetAddrHigh, $TargetAddrLow, $Channel) + $agvFrame)
}

function ConvertTo-HexString {
  param([byte[]]$Data)
  return (($Data | ForEach-Object { $_.ToString("X2") }) -join " ")
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $PSScriptRoot "vehicles.psd1"
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
  throw "Vehicle configuration was not found: $ConfigPath"
}

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$vehicleEntries = @($config.Vehicles)
if ($vehicleEntries.Count -lt 2) {
  throw "At least two vehicles must be configured in $ConfigPath"
}

$vehicles = @()
$vehicleByKey = @{}
$addressKeys = @{}
foreach ($entry in $vehicleEntries) {
  $key = [string]$entry.Key
  $id = [string]$entry.Id
  $name = [string]$entry.Name
  $addrHighValue = [int]$entry.AddrHigh
  $addrLowValue = [int]$entry.AddrLow
  $channelValue = [int]$entry.Channel

  if ($key -notmatch '^[1-9]$') {
    throw "Vehicle key must be one digit from 1 to 9: $key"
  }
  if ([string]::IsNullOrWhiteSpace($id) -or
      [string]::IsNullOrWhiteSpace($name)) {
    throw "Every vehicle requires a non-empty Id and Name."
  }
  foreach ($value in @($addrHighValue, $addrLowValue, $channelValue)) {
    if (($value -lt 0) -or ($value -gt 255)) {
      throw "Vehicle address and channel values must fit in one byte."
    }
  }
  if ($vehicleByKey.ContainsKey($key)) {
    throw "Duplicate vehicle selection key: $key"
  }

  $addressKey = "{0:X2}:{1:X2}:{2:X2}" -f `
    $addrHighValue, $addrLowValue, $channelValue
  if ($addressKeys.ContainsKey($addressKey)) {
    throw "Duplicate directed LoRa target: $addressKey"
  }

  $vehicle = [PSCustomObject]@{
    Key = $key
    Id = $id
    Name = $name
    AddrHigh = [byte]$addrHighValue
    AddrLow = [byte]$addrLowValue
    Channel = [byte]$channelValue
    Target = $addressKey
    RunPacket = $null
    LockPacket = $null
  }
  $vehicle.RunPacket = New-ControlPacket `
    -TargetAddrHigh $vehicle.AddrHigh `
    -TargetAddrLow $vehicle.AddrLow `
    -Channel $vehicle.Channel `
    -LeftPwm ([byte]$LeftPwm) `
    -RightPwm ([byte]$RightPwm) `
    -Pulses $Pulses `
    -Locked $false
  $vehicle.LockPacket = New-ControlPacket `
    -TargetAddrHigh $vehicle.AddrHigh `
    -TargetAddrLow $vehicle.AddrLow `
    -Channel $vehicle.Channel `
    -LeftPwm 0 `
    -RightPwm 0 `
    -Pulses 0 `
    -Locked $true

  $vehicles += $vehicle
  $vehicleByKey[$key] = $vehicle
  $addressKeys[$addressKey] = $true
}

# One directed broadcast reaches every module on the same LoRa channel. This
# also keeps consecutive per-vehicle headers from being merged by the module's
# UART packetizer during group control.
$broadcastTargets = @()
foreach ($channelGroup in @($vehicles | Group-Object -Property Channel)) {
  [byte]$channel = $channelGroup.Group[0].Channel
  $target = "FF:FF:{0:X2}" -f $channel
  $broadcast = [PSCustomObject]@{
    Key = "0"
    Id = "broadcast_ch_{0:X2}" -f $channel
    Name = "All vehicles on channel 0x{0:X2}" -f $channel
    AddrHigh = [byte]0xFF
    AddrLow = [byte]0xFF
    Channel = $channel
    Target = $target
    RunPacket = $null
    LockPacket = $null
  }
  $broadcast.RunPacket = New-ControlPacket `
    -TargetAddrHigh $broadcast.AddrHigh `
    -TargetAddrLow $broadcast.AddrLow `
    -Channel $broadcast.Channel `
    -LeftPwm ([byte]$LeftPwm) `
    -RightPwm ([byte]$RightPwm) `
    -Pulses $Pulses `
    -Locked $false
  $broadcast.LockPacket = New-ControlPacket `
    -TargetAddrHigh $broadcast.AddrHigh `
    -TargetAddrLow $broadcast.AddrLow `
    -Channel $broadcast.Channel `
    -LeftPwm 0 `
    -RightPwm 0 `
    -Pulses 0 `
    -Locked $true
  $broadcastTargets += $broadcast
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $runtimeLogDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) "logs\runtime"
  New-Item -ItemType Directory -Path $runtimeLogDirectory -Force | Out-Null
  $LogPath = Join-Path $runtimeLogDirectory "multi_control_tx_$stamp.csv"
} else {
  $customLogDirectory = Split-Path $LogPath -Parent
  if (-not [string]::IsNullOrWhiteSpace($customLogDirectory)) {
    New-Item -ItemType Directory -Path $customLogDirectory -Force | Out-Null
  }
}

$sessionClock = [System.Diagnostics.Stopwatch]::StartNew()
$port = New-Object System.IO.Ports.SerialPort $PortName, $BaudRate, 'None', 8, 'One'
$port.WriteTimeout = 1000
$port.ReadTimeout = 100

function Write-TxLog {
  param(
    [PSCustomObject]$Vehicle,
    [string]$Event,
    [string]$Reason,
    [int]$Bytes,
    [DateTime]$TxStartUtc,
    [double]$TxStartMs,
    [double]$TxEndMs,
    [double]$WriteUs
  )

  $record = [PSCustomObject]@{
    tx_start_utc = $TxStartUtc.ToString("o")
    tx_start_ms = [Math]::Round($TxStartMs, 3)
    tx_end_ms = [Math]::Round($TxEndMs, 3)
    vehicle_id = $Vehicle.Id
    vehicle_name = $Vehicle.Name
    target = $Vehicle.Target
    event = $Event
    reason = $Reason
    bytes = $Bytes
    write_us = [Math]::Round($WriteUs, 1)
    uart_wire_ms = [Math]::Round(($Bytes * 10.0 * 1000.0) / $BaudRate, 3)
    left_pwm = if ($Event -eq "LOCK") { 0 } else { $LeftPwm }
    right_pwm = if ($Event -eq "LOCK") { 0 } else { $RightPwm }
    pulses = if ($Event -eq "LOCK") { 0 } else { $Pulses }
  }
  $record | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Append
}

function Send-Packet {
  param(
    [PSCustomObject]$Vehicle,
    [string]$Event,
    [string]$Reason,
    [byte[]]$Packet
  )

  $txStartUtc = [DateTime]::UtcNow
  $txStartMs = $sessionClock.Elapsed.TotalMilliseconds
  $writeClock = [System.Diagnostics.Stopwatch]::StartNew()
  $port.Write($Packet, 0, $Packet.Length)
  $writeClock.Stop()
  $txEndMs = $sessionClock.Elapsed.TotalMilliseconds
  Write-TxLog -Vehicle $Vehicle -Event $Event -Reason $Reason `
    -Bytes $Packet.Length -TxStartUtc $txStartUtc `
    -TxStartMs $txStartMs -TxEndMs $txEndMs `
    -WriteUs ($writeClock.Elapsed.TotalMilliseconds * 1000.0)
  Write-Host ("[{0,10:N3} ms] {1,-8} {2,-10} target={3} reason={4}" -f `
      $txStartMs, $Event, $Vehicle.Id, $Vehicle.Target, $Reason)
}

function Send-LockBurst {
  param(
    [PSCustomObject]$Vehicle,
    [string]$Reason
  )

  for ($round = 1; $round -le $LockRepeat; $round++) {
    Send-Packet -Vehicle $Vehicle -Event "LOCK" `
      -Reason "$Reason round $round" -Packet $Vehicle.LockPacket
    if ($round -lt $LockRepeat) {
      Start-Sleep -Milliseconds $LockIntervalMs
    }
  }
  Write-Host "Lock burst complete: $($Vehicle.Name), $Reason"
}

function Send-AllLockBurst {
  param([string]$Reason)

  for ($round = 1; $round -le $LockRepeat; $round++) {
    foreach ($broadcast in $broadcastTargets) {
      Send-Packet -Vehicle $broadcast -Event "LOCK" `
        -Reason "$Reason round $round" -Packet $broadcast.LockPacket
    }
    if ($round -lt $LockRepeat) {
      Start-Sleep -Milliseconds $LockIntervalMs
    }
  }
  Write-Host "Global lock burst complete: $Reason"
}

function Get-SelectionKey {
  param([string]$ConsoleKeyName)

  if ($ConsoleKeyName -match '^D([0-9])$') {
    return $Matches[1]
  }
  if ($ConsoleKeyName -match '^NumPad([0-9])$') {
    return $Matches[1]
  }
  return $null
}

function Get-ScopeLabel {
  param([string]$ScopeKey)

  if ($ScopeKey -eq "0") {
    return "ALL vehicles"
  }
  return $vehicleByKey[$ScopeKey].Name
}

function Send-ScopeRun {
  param(
    [string]$ScopeKey,
    [string]$Reason
  )

  $targets = if ($ScopeKey -eq "0") {
    @($broadcastTargets)
  } else {
    @($vehicleByKey[$ScopeKey])
  }

  foreach ($target in $targets) {
    Send-Packet -Vehicle $target -Event "RUN" `
      -Reason $Reason -Packet $target.RunPacket
  }
}

function Send-ScopeLock {
  param(
    [string]$ScopeKey,
    [string]$Reason
  )

  if ($ScopeKey -eq "0") {
    Send-AllLockBurst -Reason $Reason
  } else {
    Send-LockBurst -Vehicle $vehicleByKey[$ScopeKey] -Reason $Reason
  }
}

$selectedScopeKey = [string]$vehicles[0].Key
$activeScopeKey = $null
$armedScopeKey = $null
$safetyLockDueMs = -1.0
$finalLockRequired = $true

Write-Host "STM32 LoRa multi-vehicle control console"
Write-Host "Port=$PortName Baud=$BaudRate PWM=$LeftPwm/$RightPwm Pulses=$Pulses SafetyLock=${SafetyLockMs}ms"
Write-Host "Configured vehicles:"
foreach ($vehicle in $vehicles) {
  Write-Host "  [$($vehicle.Key)] $($vehicle.Name) id=$($vehicle.Id) target=$($vehicle.Target)"
  Write-Host "      RUN:  $(ConvertTo-HexString $vehicle.RunPacket)"
  Write-Host "      LOCK: $(ConvertTo-HexString $vehicle.LockPacket)"
}
Write-Host "  [0] ALL vehicles (LoRa broadcast)"
foreach ($broadcast in $broadcastTargets) {
  Write-Host "      target=$($broadcast.Target)"
  Write-Host "      RUN:  $(ConvertTo-HexString $broadcast.RunPacket)"
  Write-Host "      LOCK: $(ConvertTo-HexString $broadcast.LockPacket)"
}
Write-Host "Selected: $(Get-ScopeLabel $selectedScopeKey)"
Write-Host "Log: $LogPath"
Write-Host ""
Write-Host "Keys: 0=all, 1/2=single, A=arm, R=start, L=lock scope, Space=lock all, Q=quit"

if ($DryRun) {
  Write-Host "DryRun enabled. No serial data sent."
  exit 0
}

try {
  $port.Open()
  Write-Host "Serial port opened. Sending startup global lock burst."
  Send-AllLockBurst -Reason "startup"

  while ($true) {
    if ([Console]::KeyAvailable) {
      $key = [Console]::ReadKey($true)
      $selectionKey = Get-SelectionKey $key.Key.ToString()

      if (($null -ne $selectionKey) -and
          (($selectionKey -eq "0") -or
           $vehicleByKey.ContainsKey($selectionKey))) {
        if ($selectionKey -ne $selectedScopeKey) {
          if ($null -ne $activeScopeKey) {
            Send-ScopeLock -ScopeKey $activeScopeKey -Reason "target switch"
            $activeScopeKey = $null
            $safetyLockDueMs = -1.0
          }
          $armedScopeKey = $null
          $selectedScopeKey = $selectionKey
          Write-Host "Selected: $(Get-ScopeLabel $selectedScopeKey)"
        } else {
          Write-Host "Already selected: $(Get-ScopeLabel $selectedScopeKey)"
        }
        continue
      }

      switch ($key.Key) {
        'A' {
          if ($null -ne $activeScopeKey) {
            Write-Host "RUN blocked. Lock $(Get-ScopeLabel $activeScopeKey) before arming again."
          } else {
            $armedScopeKey = $selectedScopeKey
            Write-Host "ARMED: $(Get-ScopeLabel $armedScopeKey). Press R to start or L to cancel."
          }
        }
        'R' {
          if (($null -eq $armedScopeKey) -or
              ($armedScopeKey -ne $selectedScopeKey)) {
            Write-Host "RUN blocked. Select the target scope and press A first."
            continue
          }
          if ($null -ne $activeScopeKey) {
            Write-Host "RUN blocked. $(Get-ScopeLabel $activeScopeKey) is already active."
            continue
          }
          $runReason = if ($selectedScopeKey -eq "0") {
            "group start"
          } else {
            "single start"
          }
          Send-ScopeRun -ScopeKey $selectedScopeKey -Reason $runReason
          $armedScopeKey = $null
          $activeScopeKey = $selectedScopeKey
          $safetyLockDueMs = $sessionClock.Elapsed.TotalMilliseconds + $SafetyLockMs
          Write-Host "RUN active: $(Get-ScopeLabel $activeScopeKey). L=lock scope, Space=lock all."
        }
        'L' {
          $lockScopeKey = if ($null -ne $activeScopeKey) {
            $activeScopeKey
          } else {
            $selectedScopeKey
          }
          Send-ScopeLock -ScopeKey $lockScopeKey -Reason "manual"
          $activeScopeKey = $null
          $armedScopeKey = $null
          $safetyLockDueMs = -1.0
        }
        'Spacebar' {
          Send-AllLockBurst -Reason "emergency"
          $activeScopeKey = $null
          $armedScopeKey = $null
          $safetyLockDueMs = -1.0
        }
        'Q' {
          Send-AllLockBurst -Reason "exit"
          $finalLockRequired = $false
          $activeScopeKey = $null
          $armedScopeKey = $null
          $safetyLockDueMs = -1.0
          break
        }
        default {
          Write-Host "Unknown key. 0=all, 1/2=single, A=arm, R=start, L=lock scope, Space=lock all, Q=quit"
        }
      }

      if ($key.Key -eq 'Q') {
        break
      }
    }

    if (($null -ne $activeScopeKey) -and
        ($sessionClock.Elapsed.TotalMilliseconds -ge $safetyLockDueMs)) {
      $expiredScopeLabel = Get-ScopeLabel $activeScopeKey
      Send-ScopeLock -ScopeKey $activeScopeKey -Reason "PC safety timeout"
      Write-Host "Safety lock sent: $expiredScopeLabel"
      $activeScopeKey = $null
      $armedScopeKey = $null
      $safetyLockDueMs = -1.0
    }

    Start-Sleep -Milliseconds 5
  }
} finally {
  if ($port.IsOpen) {
    if ($finalLockRequired) {
      try {
        Send-AllLockBurst -Reason "abnormal cleanup"
      } catch {
        Write-Warning "Final global lock burst failed: $($_.Exception.Message)"
      }
    }
    $port.Close()
  }
  $port.Dispose()
  Write-Host "Serial port closed."
}
