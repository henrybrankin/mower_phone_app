Firmware workspace for Arduino Nano 33 BLE Sense Rev2

This folder contains an Arduino sketch for the mower MCU and helper commands for `arduino-cli`.

Prerequisites
- `arduino-cli` installed and on PATH.
- Install the Arduino Nano Mbed core and ArduinoBLE library:

```powershell
arduino-cli core update-index
arduino-cli core install arduino:mbed_nano
arduino-cli lib install "ArduinoBLE"
```

Build and upload
- Compile:

```powershell
arduino-cli compile --fqbn arduino:mbed_nano:nano33ble firmware/mower_mcu
```

- Upload (replace COM3 with your port):

```powershell
arduino-cli upload -p COM3 --fqbn arduino:mbed_nano:nano33ble firmware/mower_mcu
```

Notes
- If upload fails, ensure the board is in bootloader/reset mode or use the Arduino Web Editor instructions for Nano 33 BLE.
- The sketch advertises as `MowerXiao` and exposes a simple telemetry service (notify) and a control characteristic (write) to request zero calibration.
