# Arduino mower firmware

This folder contains the Arduino Nano 33 BLE Sense Rev2 mower firmware and the
OTA prototype configuration. The sketch advertises as `MowerEMU`, sends IMU
telemetry, accepts zero calibration, and currently reports firmware version
`0.1.4`.

See [OTA-DESIGN.md](OTA-DESIGN.md) for the verified MCUboot layout, image
formats, hardware-test results, and planned BLE update workflow.

## Reserved mower I/O

| Pin | Direction | Purpose | Logic |
| --- | --- | --- | --- |
| `A1` | Output | Siren relay driver | `HIGH` = siren on; `LOW` = siren off |
| `A6` | Input | Oil-pressure switch | `HIGH` = pressure good; `LOW` = pressure lost |
| `A2` | Input | Engine RPM | Conditioned flywheel-generator waveform; interface and decoder require experimental development |
| `D9` | Output | MAX31856 chip select | SPI chip select |
| `D10` | Input | MAX31856 `FAULT` | Thermocouple/interface fault indication |
| `D8` | Input | MAX31856 `DRDY` | Temperature conversion data-ready indication |
| `SCK` / `MOSI` / `MISO` | SPI | MAX31856 data interface | Nano hardware-SPI bus |

These assignments are recorded for PCB and firmware development but are not
yet implemented by the mower sketch. `A1` must default low as early as possible
during startup. Inputs must remain within the Nano's 3.3 V limits. The proposed
`A2` generator input requires transient protection and signal conditioning based
on measurements of the real waveform; it must not be connected directly to the
engine generator.

Engine temperature will use a thermocouple connected to a MAX31856. Firmware
will use the Nano's hardware SPI controller, select the converter with `D9`,
and monitor its dedicated `FAULT` and `DRDY` signals on `D10` and `D8`. This
interface is reserved but not yet implemented in the mower sketch.

The BMM150 magnetometer and heading display were removed in firmware 0.1.4.
The BMI270 accelerometer and gyroscope remain in use for roll and pitch, but
the combined sensor library is started in accelerometer-only mode so it does
not initialize or retain the BMM150 driver. This reduced the relocated Arduino
application from 367472 to 361872 bytes, recovering 5600 bytes of flash.

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

On Windows, the recovery uploader can enter SAM-BA automatically through the
Arduino core's 1200-baud touch mechanism:

```powershell
powershell -ExecutionPolicy Bypass -File firmware\upload_recovery.ps1 -Port COM11
```

After firmware 0.1.1 or later is running, the port can be discovered
automatically:

```powershell
powershell -ExecutionPolicy Bypass -File firmware\upload_recovery.ps1 -Auto
```

At 115200 baud the host sends `MOWER_EMU?`; the firmware responds with protocol
version, firmware version, and the nRF52840 unique device ID. The parser is
non-blocking and never waits for a serial terminal. Automatic discovery probes
only USB devices with the Nano 33 BLE application VID/PID. If more than one EMU
answers, the script refuses to choose and requires an explicit `-Port`.

The script verifies the artifact against its manifest, observes the application
port transition, confirms that the new port identifies as an nRF52840 SAM-BA
bootloader, uploads only `mower-sam-ba.bin`, and waits for the original
application port to return. Do not substitute the ordinary Arduino sketch
upload command, because it would overwrite MCUboot at `0x10000`.

Automatic discovery and the complete COM11 -> COM9 -> COM11 recovery cycle were
hardware-verified on Windows on 2026-08-21 with firmware 0.1.1 and the
433024-byte combined image.

The OTA installation, BLE transfer, MCUboot trial activation, and confirmation
path are now hardware-proven. Use the checked artifact build below instead of
manually composing recovery images.

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

It also copies `mower-update.bin` and the manifest into `assets/firmware/` so
the same verified update is bundled into subsequent Flutter builds.

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

The firmware also exposes the stage-one, non-destructive BLE OTA transport
test. From Flutter's About & Diagnostics screen it transfers a generated 1 KiB
payload with ordered offsets and CRC-32 verification. It does not write flash
or reboot; the protocol is documented in [OTA-DESIGN.md](OTA-DESIGN.md).

The same screen has a separately confirmed secondary-slot flash test. It
erases only the first 4 KiB sector at `0x8E000`, writes the 1 KiB test payload,
and verifies flash readback CRC-32. It does not mark an update pending or
reboot, but it does destroy any previously staged secondary image.

Transfer fragments adapt to the negotiated BLE MTU, up to 240 payload bytes,
use write-without-response for data, and receive cumulative acknowledgements in
roughly 256-byte windows. Diagnostics show the measured duration, throughput,
MTU, and chosen payload size.

The separately confirmed **Stage bundled firmware** action writes the complete
embedded MCUboot image to the secondary slot. On an ordinary confirmed boot,
firmware startup erases that slot before BLE advertising begins. On an MCUboot
trial boot, the firmware preserves it because it contains the rollback image.
The Arduino verifies both streaming and flash-readback CRC-32 and checks the
MCUboot header and TLV. **Activate staged firmware** marks the image pending and
reboots into an MCUboot trial. After reconnecting and checking the version and
telemetry, **Confirm running firmware** makes that image permanent.

The complete process was hardware-verified on Windows on 2026-10-03 by loading
firmware 0.1.2 through SAM-BA, transferring the 368032-byte 0.1.3 image over
BLE, activating it as a trial, confirming it from Flutter, resetting the board,
and verifying that it still reported 0.1.3.

The current reliable transport also retries uncertain Windows writes, resumes
from stable Arduino-reported offsets, and repeats transfer credits. Normal
telemetry is stopped while OTA writes the secondary slot to avoid BLE
contention. During that interval Flutter suspends its telemetry-freshness
watchdog but continues to monitor BLE connection events and OTA status/timeouts.
Direct per-fragment flash programming is intentional: larger buffered FlashIAP
operations caused ArduinoBLE disconnections in hardware tests. Normal 50 Hz
telemetry and its freshness watchdog resume when the transfer ends.
This telemetry-silent path was hardware-verified on Windows with the 366936-byte
image in 638 seconds (574 B/s); telemetry resumed normally afterward.
If BLE disconnects during an OTA session, the firmware aborts that session and
re-erases the partial slot before advertising again. The next connection can
therefore restart from zero and receives normal telemetry without a board reset.
Full-image staging on iPhone uses 64-byte fragments, 128-byte acknowledged flow
control, and 4096-byte offset checks. This configuration transferred 367192
bytes successfully in 200 seconds (1829 B/s). A 128-byte/256-byte test caused a
disconnect, so 64-byte fragments are the current reliable limit.
