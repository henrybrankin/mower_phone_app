$base = Join-Path $env:USERPROFILE 'Documents\Arduino\libraries\Arduino_BMI270_BMM150'
if (-not (Test-Path $base)) { Write-Output "NOT_FOUND: $base"; exit 1 }
Get-ChildItem $base -Recurse -Include *.ino,*.h,*.cpp |
  Select-String -Pattern 'magnetic|magnet|readMag|FieldAvailable' |
  Select-Object -First 120 |
  ForEach-Object { "{0}:{1}: {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim() }
