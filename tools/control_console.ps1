param(
  [string]$PortName = "COM8",
  [int]$BaudRate = 9600,
  [ValidateRange(0, 100)]
  [int]$LeftPwm = 8,
  [ValidateRange(0, 100)]
  [int]$RightPwm = 8,
  [ValidateRange(0, 100000)]
  [uint32]$Pulses = 5,
  [ValidateRange(100, 10000)]
  [int]$AutoLockMs = 500,
  [ValidateRange(1, 10)]
  [int]$LockRepeat = 3,
  [ValidateRange(20, 1000)]
  [int]$LockIntervalMs = 200,
  [byte]$TargetAddrHigh = 0x00,
  [byte]$TargetAddrLow = 0x01,
  [byte]$Channel = 0x17,
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

$runPacket = New-ControlPacket `
  -TargetAddrHigh $TargetAddrHigh `
  -TargetAddrLow $TargetAddrLow `
  -Channel $Channel `
  -LeftPwm ([byte]$LeftPwm) `
  -RightPwm ([byte]$RightPwm) `
  -Pulses $Pulses `
  -Locked $false

$lockPacket = New-ControlPacket `
  -TargetAddrHigh $TargetAddrHigh `
  -TargetAddrLow $TargetAddrLow `
  -Channel $Channel `
  -LeftPwm 0 `
  -RightPwm 0 `
  -Pulses 0 `
  -Locked $true

if ([string]::IsNullOrWhiteSpace($LogPath)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $LogPath = Join-Path $PSScriptRoot "control_tx_$stamp.csv"
}

$sessionClock = [System.Diagnostics.Stopwatch]::StartNew()
$port = New-Object System.IO.Ports.SerialPort $PortName, $BaudRate, 'None', 8, 'One'
$port.WriteTimeout = 1000
$port.ReadTimeout = 100
$armed = $false
$autoLockDueMs = -1.0

function Write-TxLog {
  param(
    [string]$Event,
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
    event = $Event
    bytes = $Bytes
    write_us = [Math]::Round($WriteUs, 1)
    uart_wire_ms = [Math]::Round(($Bytes * 10.0 * 1000.0) / $BaudRate, 3)
    left_pwm = $LeftPwm
    right_pwm = $RightPwm
    pulses = $Pulses
  }
  $record | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Append
}

function Send-Packet {
  param(
    [string]$Event,
    [byte[]]$Packet
  )

  $txStartUtc = [DateTime]::UtcNow
  $txStartMs = $sessionClock.Elapsed.TotalMilliseconds
  $writeClock = [System.Diagnostics.Stopwatch]::StartNew()
  $port.Write($Packet, 0, $Packet.Length)
  $writeClock.Stop()
  $txEndMs = $sessionClock.Elapsed.TotalMilliseconds
  Write-TxLog -Event $Event -Bytes $Packet.Length -TxStartUtc $txStartUtc `
    -TxStartMs $txStartMs -TxEndMs $txEndMs `
    -WriteUs ($writeClock.Elapsed.TotalMilliseconds * 1000.0)
  Write-Host ("[{0,10:N3} ms] {1,-8} bytes={2} write={3:N1} us" -f `
      $txStartMs, $Event, $Packet.Length,
      ($writeClock.Elapsed.TotalMilliseconds * 1000.0))
}

function Send-LockBurst {
  param([string]$Reason)

  for ($i = 1; $i -le $LockRepeat; $i++) {
    Send-Packet -Event "LOCK" -Packet $lockPacket
    if ($i -lt $LockRepeat) {
      Start-Sleep -Milliseconds $LockIntervalMs
    }
  }
  Write-Host "Lock burst complete: $Reason"
}

Write-Host "STM32 LoRa vehicle control console"
Write-Host "Port=$PortName Baud=$BaudRate Target=$($TargetAddrHigh.ToString('X2')):$($TargetAddrLow.ToString('X2')) Channel=0x$($Channel.ToString('X2'))"
Write-Host "RUN: PWM=$LeftPwm/$RightPwm Pulses=$Pulses AutoLock=${AutoLockMs}ms"
Write-Host "RUN packet:  $(ConvertTo-HexString $runPacket)"
Write-Host "LOCK packet: $(ConvertTo-HexString $lockPacket)"
Write-Host "Log: $LogPath"
Write-Host ""
Write-Host "Keys: A=arm one RUN, R=send RUN, L/Space=lock now, Q=lock and quit"

if ($DryRun) {
  Write-Host "DryRun enabled. No serial data sent."
  exit 0
}

try {
  $port.Open()
  Write-Host "Serial port opened. Sending startup lock burst."
  Send-LockBurst -Reason "startup"

  while ($true) {
    if (($autoLockDueMs -ge 0.0) -and
        ($sessionClock.Elapsed.TotalMilliseconds -ge $autoLockDueMs)) {
      Send-LockBurst -Reason "automatic timeout"
      $autoLockDueMs = -1.0
      $armed = $false
    }

    if (-not [Console]::KeyAvailable) {
      Start-Sleep -Milliseconds 5
      continue
    }

    $key = [Console]::ReadKey($true)
    switch ($key.Key) {
      'A' {
        $armed = $true
        Write-Host "ARMED for one RUN command. Press R to send or L to cancel."
      }
      'R' {
        if (-not $armed) {
          Write-Host "RUN blocked. Press A first."
          continue
        }
        Send-Packet -Event "RUN" -Packet $runPacket
        $armed = $false
        $autoLockDueMs = $sessionClock.Elapsed.TotalMilliseconds + $AutoLockMs
        Write-Host "RUN sent. Automatic lock scheduled in $AutoLockMs ms."
      }
      'L' {
        Send-LockBurst -Reason "manual"
        $autoLockDueMs = -1.0
        $armed = $false
      }
      'Spacebar' {
        Send-LockBurst -Reason "manual"
        $autoLockDueMs = -1.0
        $armed = $false
      }
      'Q' {
        Send-LockBurst -Reason "exit"
        break
      }
      default {
        Write-Host "Unknown key. A=arm, R=run, L/Space=lock, Q=quit"
      }
    }

    if ($key.Key -eq 'Q') {
      break
    }
  }
} finally {
  if ($port.IsOpen) {
    try {
      Send-LockBurst -Reason "final cleanup"
    } catch {
      Write-Warning "Final lock burst failed: $($_.Exception.Message)"
    }
    $port.Close()
  }
  $port.Dispose()
  Write-Host "Serial port closed."
}
