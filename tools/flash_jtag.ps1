param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",
    [ValidateRange(100, 4000)]
    [int]$AdapterSpeedKHz = 1000
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path $PSScriptRoot -Parent
$plugins = "C:\ST\STM32CubeIDE_2.1.0\STM32CubeIDE\plugins"
$elf = Join-Path $projectRoot "build\$Configuration\MiniSTM32F103_Gateway.elf"

if (-not (Test-Path $elf)) {
    throw "Firmware is missing. Run tools\build.ps1 first: $elf"
}

$openocd = Get-ChildItem $plugins -Filter openocd.exe -Recurse |
    Sort-Object FullName -Descending | Select-Object -First 1
$target = Get-ChildItem $plugins -Filter stm32f1x.cfg -Recurse |
    Where-Object { $_.Directory.Name -eq "target" } |
    Sort-Object FullName -Descending | Select-Object -First 1

if (-not $openocd) { throw "openocd.exe was not found under $plugins" }
if (-not $target) { throw "OpenOCD stm32f1x.cfg was not found under $plugins" }

$scripts = $target.Directory.Parent.FullName
$boardConfig = Join-Path $projectRoot "openocd\mini_stm32f103_jtag.cfg"
$elfForTcl = (Resolve-Path $elf).Path.Replace("\", "/")

& $openocd.FullName `
    -s $scripts `
    -f $boardConfig `
    -c "adapter speed $AdapterSpeedKHz" `
    -c "program {$elfForTcl} verify reset exit"

if ($LASTEXITCODE -ne 0) { throw "OpenOCD programming failed" }
Write-Host "Programming and verification completed successfully."
