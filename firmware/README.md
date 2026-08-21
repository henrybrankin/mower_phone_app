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
embedded MCUboot image to the secondary slot. Firmware startup erases that slot
before BLE advertising begins, avoiding blocking erase operations while a phone
is connected.
The Arduino verifies both streaming and flash-readback CRC-32 and checks the
MCUboot header and TLV. It deliberately does not mark the image pending, reboot,
or activate it; activation is a later milestone. The full path was
hardware-verified on Windows with the 366680-byte firmware 0.1.0 image in 641
seconds (572 B/s).

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
Full-image staging on iPhone currently uses conservative 16-byte fragments,
64-byte acknowledged flow control, and 256-byte offset checks to prioritise
reliability before throughput optimisation.
