[CmdletBinding()]
param(
    [string] $Version,
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$firmwareDirectory = $PSScriptRoot
$repositoryRoot = Split-Path -Parent $firmwareDirectory
$sketchDirectory = Join-Path $firmwareDirectory 'mower_mcu'
$sketchPath = Join-Path $sketchDirectory 'mower_mcu.ino'
$otaDirectory = Join-Path $firmwareDirectory 'ota'
$flutterFirmwareAssets = Join-Path $repositoryRoot 'assets\firmware'
$toolsDirectory = Join-Path $repositoryRoot '.tools'
$zephyrProject = Join-Path $toolsDirectory 'zephyrproject'
$mcubootDirectory = Join-Path $zephyrProject 'bootloader\mcuboot'
$mcubootApplication = Join-Path $mcubootDirectory 'boot\zephyr'
$python = Join-Path $toolsDirectory 'zephyr-venv\Scripts\python.exe'
$west = Join-Path $toolsDirectory 'zephyr-venv\Scripts\west.exe'
$imgtool = Join-Path $mcubootDirectory 'scripts\imgtool.py'
$zephyrSdk = Join-Path $toolsDirectory 'zephyr-sdk'
$handoffPatch = Join-Path $otaDirectory 'mcuboot\arduino-mbed-handoff.patch'
$mcubootSource = Join-Path $mcubootApplication 'main.c'
$mcubootOverlay = Join-Path $otaDirectory 'mcuboot\arduino_nano_33_ble.overlay'
$mcubootConfiguration = Join-Path $otaDirectory 'mcuboot\mcuboot.conf'
$relocateScript = Join-Path $otaDirectory 'arduino\relocate_linker.ps1'
$linkerFlags = Join-Path $otaDirectory 'arduino\ldflags.txt'

function Find-BuildTool {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [string[]] $FallbackPaths
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    foreach ($candidate in $FallbackPaths) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    throw "$Name is required but was not found on PATH or in a standard installation location."
}

$cmake = Find-BuildTool 'cmake.exe' @(
    (Join-Path $env:ProgramFiles 'CMake\bin\cmake.exe')
)
$ninja = Find-BuildTool 'ninja.exe' @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ninja.exe')
)
$dtcFallbacks = @(
    Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') `
        -Filter dtc.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName
)
$dtc = Find-BuildTool 'dtc.exe' $dtcFallbacks

$buildRoot = Join-Path $repositoryRoot 'build\ota-build'
$mcubootBuild = Join-Path $buildRoot 'mcuboot'
$arduinoBuild = Join-Path $buildRoot 'arduino'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $buildRoot 'output'
} elseif (-not [IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot $OutputDirectory
}

$requiredFiles = @(
    $sketchPath,
    $python,
    $west,
    $imgtool,
    $handoffPatch,
    $mcubootSource,
    $mcubootOverlay,
    $mcubootConfiguration,
    $relocateScript,
    $linkerFlags
)
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required OTA build file was not found: $requiredFile"
    }
}
if (-not (Test-Path -LiteralPath $zephyrSdk -PathType Container)) {
    throw "Zephyr SDK was not found: $zephyrSdk"
}
if ($null -eq (Get-Command arduino-cli -ErrorAction SilentlyContinue)) {
    throw 'arduino-cli is not available on PATH.'
}

$sketchText = Get-Content -LiteralPath $sketchPath -Raw
$versionMatch = [regex]::Match(
    $sketchText,
    'kFirmwareVersion\[\]\s*=\s*"(?<version>\d+\.\d+\.\d+)"'
)
if (-not $versionMatch.Success) {
    throw "Could not read kFirmwareVersion from $sketchPath"
}
$firmwareVersion = $versionMatch.Groups['version'].Value
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $firmwareVersion
} elseif ($Version -ne $firmwareVersion) {
    throw "Requested version $Version does not match kFirmwareVersion $firmwareVersion."
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)] [string] $Description,
        [Parameter(Mandatory = $true)] [scriptblock] $Command
    )

    Write-Host "`n==> $Description"
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

Write-Host "Building Mower EMU OTA artifacts for firmware $Version"

$mcubootText = Get-Content -LiteralPath $mcubootSource -Raw
if (-not $mcubootText.Contains('Arduino mbed startup expects')) {
    Invoke-Checked 'Applying the Arduino mbed MCUboot handoff patch' {
        & git -C $mcubootDirectory apply $handoffPatch
    }
}

New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$previousSdk = $env:ZEPHYR_SDK_INSTALL_DIR
$previousPath = $env:Path
$env:ZEPHYR_SDK_INSTALL_DIR = $zephyrSdk
$env:Path = "$(Split-Path -Parent $cmake);$(Split-Path -Parent $ninja);$(Split-Path -Parent $dtc);$previousPath"
$mcubootOverlayCmake = $mcubootOverlay -replace '\\', '/'
$mcubootConfigurationCmake = $mcubootConfiguration -replace '\\', '/'
$dtcCmake = $dtc -replace '\\', '/'
Push-Location $zephyrProject
try {
    Invoke-Checked 'Building MCUboot' {
        & $west build -p always -b arduino_nano_33_ble/nrf52840 `
            $mcubootApplication -d $mcubootBuild -- `
            "-DDTC_OVERLAY_FILE=$mcubootOverlayCmake" `
            "-DEXTRA_CONF_FILE=$mcubootConfigurationCmake" `
            "-DDTC=$dtcCmake"
    }
} finally {
    Pop-Location
    $env:ZEPHYR_SDK_INSTALL_DIR = $previousSdk
    $env:Path = $previousPath
}

$prelinkProperty = 'recipe.hooks.linking.prelink.1.pattern=powershell -NoProfile -ExecutionPolicy Bypass -File {build.source.path}/../ota/arduino/relocate_linker.ps1 {build.variant.path}/{build.ldscript} {build.path}/{build.ldscript}'
$linkerProperty = 'compiler.mbed.ldflags={build.source.path}/../ota/arduino/ldflags.txt'
Invoke-Checked 'Building the relocated Arduino application' {
    & arduino-cli compile --fqbn arduino:mbed_nano:nano33ble `
        --build-path $arduinoBuild `
        --build-property $prelinkProperty `
        --build-property $linkerProperty `
        $sketchDirectory
}

$mcubootBinary = Join-Path $mcubootBuild 'zephyr\zephyr.bin'
$arduinoBinary = Join-Path $arduinoBuild 'mower_mcu.ino.bin'
$updateBinary = Join-Path $OutputDirectory 'mower-update.bin'
$samBaBinary = Join-Path $OutputDirectory 'mower-sam-ba.bin'
$manifestPath = Join-Path $OutputDirectory 'mower-ota-manifest.json'

Invoke-Checked 'Creating the MCUboot BLE update image' {
    & $python $imgtool sign `
        --header-size 0x200 `
        --align 4 `
        --slot-size 0x6e000 `
        --version $Version `
        --pad-header `
        $arduinoBinary $updateBinary
}
Invoke-Checked 'Verifying the MCUboot BLE update image' {
    & $python $imgtool verify $updateBinary
}

$stage2 = [IO.File]::ReadAllBytes($mcubootBinary)
$update = [IO.File]::ReadAllBytes($updateBinary)
$stage2RegionSize = 0x10000
$slotSize = 0x6e000
if ($stage2.Length -gt $stage2RegionSize) {
    throw "MCUboot is $($stage2.Length) bytes and exceeds its 64 KiB region."
}
if ($update.Length -gt $slotSize) {
    throw "The update image is $($update.Length) bytes and exceeds its 440 KiB slot."
}

$combined = [byte[]]::new($stage2RegionSize + $update.Length)
for ($index = $stage2.Length; $index -lt $stage2RegionSize; $index++) {
    $combined[$index] = 0xFF
}
[Array]::Copy($stage2, 0, $combined, 0, $stage2.Length)
[Array]::Copy($update, 0, $combined, $stage2RegionSize, $update.Length)
[IO.File]::WriteAllBytes($samBaBinary, $combined)

for ($index = 0; $index -lt $stage2.Length; $index++) {
    if ($combined[$index] -ne $stage2[$index]) {
        throw "SAM-BA image differs from MCUboot at relative offset 0x$($index.ToString('x'))."
    }
}
for ($index = $stage2.Length; $index -lt $stage2RegionSize; $index++) {
    if ($combined[$index] -ne 0xFF) {
        throw "SAM-BA image padding is not erased at relative offset 0x$($index.ToString('x'))."
    }
}
for ($index = 0; $index -lt $update.Length; $index++) {
    if ($combined[$stage2RegionSize + $index] -ne $update[$index]) {
        $offset = $stage2RegionSize + $index
        throw "SAM-BA image differs from the update at relative offset 0x$($offset.ToString('x'))."
    }
}

$updateHash = (Get-FileHash -LiteralPath $updateBinary -Algorithm SHA256).Hash.ToLowerInvariant()
$samBaHash = (Get-FileHash -LiteralPath $samBaBinary -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest = [ordered]@{
    firmwareVersion = $Version
    board = 'arduino-nano-33-ble-sense-rev2'
    flashLayout = 'mower-ota-v1'
    createdUtc = [DateTime]::UtcNow.ToString('o')
    update = [ordered]@{
        file = 'mower-update.bin'
        size = $update.Length
        sha256 = $updateHash
        destination = 'secondary-slot-0x8e000'
    }
    samBa = [ordered]@{
        file = 'mower-sam-ba.bin'
        size = $combined.Length
        sha256 = $samBaHash
        destination = 'sam-ba-upload-at-0x10000'
    }
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

New-Item -ItemType Directory -Force -Path $flutterFirmwareAssets | Out-Null
Copy-Item -LiteralPath $updateBinary `
    -Destination (Join-Path $flutterFirmwareAssets 'mower-update.bin') -Force
Copy-Item -LiteralPath $manifestPath `
    -Destination (Join-Path $flutterFirmwareAssets 'mower-ota-manifest.json') -Force

Write-Host "`nOTA artifacts created in $OutputDirectory"
Write-Host "  mower-update.bin : $($update.Length) bytes  SHA-256 $updateHash"
Write-Host "  mower-sam-ba.bin : $($combined.Length) bytes  SHA-256 $samBaHash"
Write-Host '  mower-ota-manifest.json'
Write-Host "Flutter firmware assets updated in $flutterFirmwareAssets"
