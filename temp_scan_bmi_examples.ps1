$examplesPath = Join-Path $env:USERPROFILE 'Documents\Arduino\libraries\Arduino_BMI270_BMM150\examples'
if (-not (Test-Path $examplesPath)) {
  Write-Output "NOT_FOUND: $examplesPath"
  exit 1
}
Get-ChildItem -Path $examplesPath -Recurse -Include *.ino | ForEach-Object {
  Write-Output ("FILE: " + $_.FullName)
  Select-String -Path $_.FullName -Pattern 'IMU.begin','setContinuousMode','BOSCH_ACCEL_AND_MAGN' | ForEach-Object {
    Write-Output ("  " + $_.Line.Trim())
  }
}
