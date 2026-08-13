$type = [Type]::GetType('Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows, ContentType=WindowsRuntime')
Write-Output "RuntimeType: $type"
if ($type -eq $null) {
    Write-Output 'WinRT BLE API unavailable.'
    exit 1
}

$watcher = New-Object Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher
$handler = [System.EventHandler[Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementReceivedEventArgs]]{
    param($sender,$args)
    $name = $args.Advertisement.LocalName
    if ([string]::IsNullOrEmpty($name)) { $name = '<unnamed>' }
    Write-Output "ADV: $name RSSI=$($args.RawSignalStrengthInDBm) Address=$($args.BluetoothAddress)"
}
$watcher.add_Received($handler)
$watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Active
$watcher.Start()
Write-Output 'Scanning for 10 seconds...'
Start-Sleep -Seconds 10
$watcher.Stop()
Write-Output 'Scan complete.'
