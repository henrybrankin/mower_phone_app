# Arduino mower firmware

This folder contains the Arduino Nano 33 BLE Sense Rev2 mower firmware and the
OTA prototype configuration. The sketch advertises as `MowerEMU`, sends IMU
telemetry, accepts zero calibration, and reports firmware version `0.1.0`.

See [OTA-DESIGN.md](OTA-DESIGN.md) for the verified MCUboot layout, image
formats, hardware-test results, and planned BLE update workflow.

## Prerequisites

- `arduino-cli` on `PATH`.
- Arduino Nano mbed core 4.6.0.
- ArduinoBLE and Arduino_BMI270_BMM150 libraries.

```powershell
arduino-cli core update-index
arduino-cli core install arduino:mbed_nano
arduino-cli lib install "ArduinoBLE"
arduino-cli lib install "Arduino_BMI270_BMM150"
```

## Standard build

This command builds the original Arduino layout at `0x10000`:

```powershell
arduino-cli compile --fqbn arduino:mbed_nano:nano33ble firmware/mower_mcu
```

On a board using the original Arduino layout, it can be uploaded with:

```powershell
arduino-cli upload -p COM3 --fqbn arduino:mbed_nano:nano33ble firmware/mower_mcu
```

## Important OTA warning

Do not use the ordinary Arduino upload command on a board after the MCUboot
layout has been installed. A normal Arduino upload starts at physical
`0x10000`, so it will overwrite the second-stage manager.

For an OTA-layout board, enter SAM-BA mode by double-tapping reset and upload a
combined recovery image containing both MCUboot and the mower application. The
BLE update image contains only the MCUboot-format mower application and is
written to the secondary slot by the running firmware.

The OTA installation and BLE transfer remain prototype work. Use the checked
artifact build below instead of manually composing recovery images.

## OTA artifact build

With the repository-local Zephyr tools installed under `.tools`, run:

```powershell
powershell -ExecutionPolicy Bypass -File firmware/build_ota.ps1
```

The script reads the version from `kFirmwareVersion`, rebuilds MCUboot with the
Arduino handoff patch, builds the relocated mower application, verifies slot
sizes and the MCUboot image, and writes these files under
`build/ota-build/output/`:

- `mower-update.bin`: application-only image for the planned BLE updater.
- `mower-sam-ba.bin`: combined MCUboot and application image for SAM-BA upload.
- `mower-ota-manifest.json`: version, target, sizes, destinations, and SHA-256
  hashes.

An optional output directory can be supplied with `-OutputDirectory`. An
optional `-Version` is accepted only when it matches the version compiled into
the sketch.

## Startup LED diagnostics

- Solid yellow: BLE advertising started.
- Repeating two yellow blinks: IMU initialization failed.
- Repeating three yellow blinks: BLE initialization failed.
- Off: Arduino `setup()` was not reached.

When starting through MCUboot, the sketch deliberately power-cycles the
onboard sensor rail and re-enables the Nano's software-controlled internal I2C
pull-ups before initializing the BMI270. This hardware-verified handoff step is
required for reliable IMU identification; see [OTA-DESIGN.md](OTA-DESIGN.md).
