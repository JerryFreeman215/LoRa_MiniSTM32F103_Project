param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path $PSScriptRoot -Parent
$plugins = "C:\ST\STM32CubeIDE_2.1.0\STM32CubeIDE\plugins"

$gcc = Get-ChildItem $plugins -Filter arm-none-eabi-gcc.exe -Recurse |
    Sort-Object FullName -Descending | Select-Object -First 1
$cmake = Get-ChildItem $plugins -Filter cmake.exe -Recurse |
    Sort-Object FullName -Descending | Select-Object -First 1
$ninja = Get-Command ninja.exe -ErrorAction SilentlyContinue

if (-not $gcc) { throw "arm-none-eabi-gcc.exe was not found under $plugins" }
if (-not $cmake) { throw "cmake.exe was not found under $plugins" }
if (-not $ninja) { throw "ninja.exe is not available in PATH" }

$env:PATH = "$($gcc.Directory.FullName);$($cmake.Directory.FullName);$env:PATH"

Push-Location $projectRoot
try {
    & $cmake.FullName --fresh --preset $Configuration
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

    & $cmake.FullName --build --preset $Configuration
    if ($LASTEXITCODE -ne 0) { throw "Build failed" }
}
finally {
    Pop-Location
}

$output = Join-Path $projectRoot "build\$Configuration\MiniSTM32F103_Gateway.elf"
if (-not (Test-Path $output)) { throw "Expected output not found: $output" }
Write-Host "Build complete: $output"
