param(
  [string]$PortName = "COM8",
  [int]$BaudRate = 9600,
  [ValidateRange(0, 100)]
  [int]$LeftPwm = 8,
  [ValidateRange(0, 100)]
  [int]$RightPwm = 8,
  [ValidateRange(0, 100000)]
  [uint32]$Pulses = 40,
  [ValidateRange(1, 10000)]
  [int]$Count = 1,
  [ValidateRange(20, 60000)]
  [int]$IntervalMs = 200,
  [byte]$TargetAddrHigh = 0x00,
  [byte]$TargetAddrLow = 0x01,
  [byte]$Channel = 0x17,
  [bool]$LockAfter = $true,
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
    @(0x07, 0x00, 0x00, 0x00) # chassis_lock + motor0_break + motor1_break
  } else {
    @(0x00, 0x00, 0x00, 0x00) # unlock + brake release
  }

  [byte[]]$payload = @(
    0x00, 0x00, 0x00, 0x00, # angle_left = 0.0f
    0x00, 0x00, 0x00, 0x00, # angle_right = 0.0f
    0x00, 0x00, 0x00, 0x00  # angle_camera = 0.0f
  ) + $flags + @(
    $LeftPwm,
    $RightPwm,
    0x00, 0x00, # reserved
    [byte]($Pulses -band 0xFF),
    [byte](($Pulses -shr 8) -band 0xFF),
    [byte](($Pulses -shr 16) -band 0xFF),
    [byte](($Pulses -shr 24) -band 0xFF),
    0x00, 0x00, 0x00, 0x00 # led_ctrl off
  )

  [byte[]]$frameNoCrc = @(
    0xAA, 0x55,
    0x1C, 0x00, # payload length = 28
    0x11,       # CONTROL_CMD
    0x01        # version
  ) + $payload

  $crc = Get-Crc16Ccitt $frameNoCrc
  [byte[]]$agvFrame = $frameNoCrc + @(
    [byte]($crc -band 0xFF),
    [byte](($crc -shr 8) -band 0xFF),
    0x0D, 0x0A
  )

  [byte[]]$loraHeader = @($TargetAddrHigh, $TargetAddrLow, $Channel)
  return $loraHeader + $agvFrame
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

Write-Host "RUN packet bytes: $($runPacket.Length)"
Write-Host "RUN packet hex:   $(ConvertTo-HexString $runPacket)"
Write-Host "Port=$PortName Baud=$BaudRate Count=$Count IntervalMs=$IntervalMs PWM=$LeftPwm/$RightPwm Pulses=$Pulses LockAfter=$LockAfter"

if ($DryRun) {
  Write-Host "DryRun enabled. No serial data sent."
  exit 0
}

$port = New-Object System.IO.Ports.SerialPort $PortName, $BaudRate, 'None', 8, 'One'
$port.WriteTimeout = 1000
$port.Open()

try {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  for ($i = 1; $i -le $Count; $i++) {
    $port.Write($runPacket, 0, $runPacket.Length)
    Write-Host "Sent RUN frame $i / $Count"
    if ($i -lt $Count) {
      Start-Sleep -Milliseconds $IntervalMs
    }
  }

  if ($LockAfter) {
    Start-Sleep -Milliseconds 300
    $port.Write($lockPacket, 0, $lockPacket.Length)
    Write-Host "Sent LOCK frame after run test"
  }

  $sw.Stop()
  $elapsed = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
  Write-Host ("Done. RunFrames={0}, Elapsed={1:N3}s, ApproxRate={2:N2} fps" -f $Count, $elapsed, ($Count / $elapsed))
} finally {
  $port.Close()
}
