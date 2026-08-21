[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Port')]
    [ValidatePattern('^COM\d+$')]
    [string]$Port,

    [Parameter(Mandatory = $true, ParameterSetName = 'Auto')]
    [switch]$Auto,

    [string]$ImagePath,

    [ValidateRange(5, 60)]
    [int]$BootloaderTimeoutSeconds = 20,

    [ValidateRange(5, 120)]
    [int]$ApplicationTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ImagePath)) {
    $ImagePath = Join-Path $PSScriptRoot '..\build\ota-build\output\mower-sam-ba.bin'
}

function Get-ComPorts {
    return @([System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
}

function Find-MowerEmuPort {
    $candidates = @(Get-CimInstance Win32_PnPEntity | ForEach-Object {
        if ($_.PNPDeviceID -match 'VID_2341&PID_805A' -and
            $_.Name -match '\((COM\d+)\)') {
            $Matches[1]
        }
    } | Sort-Object -Unique)
    if ($candidates.Count -eq 0) {
        throw 'No connected Arduino Nano 33 BLE application ports were found.'
    }

    $emuMatches = @()
    foreach ($candidate in $candidates) {
        $serial = [System.IO.Ports.SerialPort]::new($candidate, 115200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
        try {
            $serial.NewLine = "`n"
            $serial.ReadTimeout = 200
            $serial.DtrEnable = $true
            $serial.Open()
            Start-Sleep -Milliseconds 100
            $serial.DiscardInBuffer()
            $serial.WriteLine('MOWER_EMU?')
            $deadline = [DateTime]::UtcNow.AddSeconds(2)
            $received = ''
            while ([DateTime]::UtcNow -lt $deadline) {
                $received += $serial.ReadExisting()
                if ($received -match '(?m)^MOWER_EMU/1 FW=([^ ]+) ID=([0-9A-F]{16})\r?$') {
                    $emuMatches += [pscustomobject]@{
                        Port = $candidate
                        Firmware = $Matches[1]
                        DeviceId = $Matches[2]
                    }
                    break
                }
                Start-Sleep -Milliseconds 50
            }
        } catch {
            Write-Verbose "Skipping $candidate`: $($_.Exception.Message)"
        } finally {
            if ($serial.IsOpen) {
                $serial.Close()
            }
            $serial.Dispose()
        }
    }

    if ($emuMatches.Count -eq 0) {
        throw "No Nano 33 BLE port answered MOWER_EMU?. Candidates: $($candidates -join ', ')"
    }
    if ($emuMatches.Count -gt 1) {
        $descriptions = @($emuMatches | ForEach-Object { "$($_.Port) ID=$($_.DeviceId)" })
        throw "Multiple Mower EMUs were found; use -Port explicitly. Matches: $($descriptions -join ', ')"
    }

    Write-Host "Detected Mower EMU firmware $($emuMatches[0].Firmware), ID $($emuMatches[0].DeviceId), on $($emuMatches[0].Port)."
    return [string]$emuMatches[0].Port
}

function Wait-ForPortSetChange {
    param(
        [string[]]$Before,
        [string]$OriginalPort,
        [int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $sawOriginalDisappear = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        $current = Get-ComPorts
        if ($OriginalPort -notin $current) {
            $sawOriginalDisappear = $true
        }

        $newPorts = @($current | Where-Object { $_ -notin $Before })
        if ($newPorts.Count -gt 0) {
            return $newPorts
        }

        if ($sawOriginalDisappear -and $OriginalPort -in $current) {
            return @($OriginalPort)
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out waiting for $OriginalPort to change into a SAM-BA port."
}

$resolvedImage = (Resolve-Path -LiteralPath $ImagePath).Path
if ([System.IO.Path]::GetFileName($resolvedImage) -ne 'mower-sam-ba.bin') {
    throw 'Recovery upload only accepts an artifact named mower-sam-ba.bin.'
}

$manifestPath = Join-Path (Split-Path -Parent $resolvedImage) 'mower-ota-manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $actualSize = (Get-Item -LiteralPath $resolvedImage).Length
    $actualHash = (Get-FileHash -LiteralPath $resolvedImage -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSize -ne [long]$manifest.samBa.size -or
        $actualHash -ne [string]$manifest.samBa.sha256) {
        throw 'mower-sam-ba.bin does not match mower-ota-manifest.json.'
    }
}

$bossac = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Arduino15\packages\arduino\tools\bossac') `
    -Recurse -Filter bossac.exe | Sort-Object FullName -Descending | Select-Object -First 1
if ($null -eq $bossac) {
    throw 'bossac.exe was not found in the installed Arduino tools.'
}

if ($Auto) {
    $Port = Find-MowerEmuPort
}

$portsBefore = Get-ComPorts
if ($Port -notin $portsBefore) {
    throw "Application port $Port does not exist. Available ports: $($portsBefore -join ', ')"
}

Write-Host "Touching application port $Port at 1200 baud..."
$serial = [System.IO.Ports.SerialPort]::new($Port, 1200, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
try {
    $serial.DtrEnable = $true
    $serial.Open()
    Start-Sleep -Milliseconds 100
} finally {
    if ($serial.IsOpen) {
        $serial.Close()
    }
    $serial.Dispose()
}

$candidates = Wait-ForPortSetChange -Before $portsBefore -OriginalPort $Port -TimeoutSeconds $BootloaderTimeoutSeconds
$bootPort = $null
foreach ($candidate in $candidates) {
    Start-Sleep -Milliseconds 300
    $probe = @(& $bossac.FullName -d "--port=$candidate" -U -i 2>&1)
    if ($LASTEXITCODE -eq 0 -and ($probe -join "`n") -match 'nRF52840-QIAA') {
        $bootPort = $candidate
        break
    }
}
if ($null -eq $bootPort) {
    throw "No new port identified itself as the nRF52840 SAM-BA bootloader. Candidates: $($candidates -join ', ')"
}

Write-Host "Verified nRF52840 SAM-BA on $bootPort."
Write-Host "Uploading $resolvedImage..."
& $bossac.FullName "--port=$bootPort" -U -i -e -w $resolvedImage -R
if ($LASTEXITCODE -ne 0) {
    throw "bossac recovery upload failed with exit code $LASTEXITCODE."
}

$deadline = [DateTime]::UtcNow.AddSeconds($ApplicationTimeoutSeconds)
while ([DateTime]::UtcNow -lt $deadline) {
    $current = Get-ComPorts
    if ($Port -in $current) {
        Write-Host "Recovery upload complete; application returned on $Port."
        exit 0
    }
    Start-Sleep -Milliseconds 250
}

Write-Warning "Upload succeeded, but application port $Port did not return within $ApplicationTimeoutSeconds seconds."
exit 0
