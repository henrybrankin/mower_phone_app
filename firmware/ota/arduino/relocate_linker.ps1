param(
    [Parameter(Mandatory = $true)] [string] $InputPath,
    [Parameter(Mandatory = $true)] [string] $OutputPath
)

$linker = Get-Content -LiteralPath $InputPath -Raw
$original = 'FLASH (rx) : ORIGIN = 0x10000, LENGTH = 0xf0000'
$relocated = 'FLASH (rx) : ORIGIN = 0x20200, LENGTH = 0x6de00'

if (-not $linker.Contains($original)) {
    throw "Expected Arduino flash layout was not found in $InputPath"
}

$linker.Replace($original, $relocated) | Set-Content -LiteralPath $OutputPath -NoNewline
