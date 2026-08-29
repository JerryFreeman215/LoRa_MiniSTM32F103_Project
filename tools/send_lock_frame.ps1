param(
  [string]$PortName = "COM8",
  [int]$BaudRate = 9600,
  [byte]$TargetAddrHigh = 0x00,
  [byte]$TargetAddrLow = 0x01,
  [byte]$Channel = 0x17,
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

function New-LockPacket {
  param(
    [byte]$TargetAddrHigh,
    [byte]$TargetAddrLow,
    [byte]$Channel
  )

  [byte[]]$payload = @(
    0x00, 0x00, 0x00, 0x00, # angle_left = 0.0f
    0x00, 0x00, 0x00, 0x00, # angle_right = 0.0f
    0x00, 0x00, 0x00, 0x00, # angle_camera = 0.0f
    0x07, 0x00, 0x00, 0x00, # chassis_lock + motor0_break + motor1_break
    0x00,                   # left pwm
    0x00,                   # right pwm
    0x00, 0x00,             # reserved
    0x00, 0x00, 0x00, 0x00, # pulses
    0x00, 0x00, 0x00, 0x00  # led_ctrl off
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

$packet = New-LockPacket `
  -TargetAddrHigh $TargetAddrHigh `
  -TargetAddrLow $TargetAddrLow `
  -Channel $Channel

Write-Host "LOCK packet bytes: $($packet.Length)"
Write-Host "LOCK packet hex:   $(ConvertTo-HexString $packet)"
Write-Host "Port=$PortName Baud=$BaudRate"

if ($DryRun) {
  Write-Host "DryRun enabled. No serial data sent."
  exit 0
}

$port = New-Object System.IO.Ports.SerialPort $PortName, $BaudRate, 'None', 8, 'One'
$port.WriteTimeout = 1000
$port.Open()

try {
  $port.Write($packet, 0, $packet.Length)
  Start-Sleep -Milliseconds 300
  Write-Host "Sent LOCK frame"
} finally {
  $port.Close()
}
