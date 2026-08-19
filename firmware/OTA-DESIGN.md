# BLE firmware update design

## Status

The two-stage boot architecture has been proven on a spare Arduino Nano 33 BLE
Sense Rev2:

1. The stock Arduino SAM-BA bootloader remains installed and provides USB
   recovery.
2. MCUboot runs as a second-stage manager at `0x10000`.
3. MCUboot validates an image in the primary slot and starts it at `0x20000`.
4. A relocated Zephyr LED test ran successfully.
5. The relocated Arduino mower firmware starts normally, advertises over BLE,
   reports firmware version `0.1.0`, and communicates with the Flutter app.
6. The normal Arduino USB serial interface returns as COM3 after startup.
7. `firmware/build_ota.ps1` has been exercised from a clean build and produces
   a verified BLE image, a structurally checked SAM-BA image, and a SHA-256
   manifest.

The BLE image-transfer service, swap request, confirmation, and rollback tests
have not yet been implemented.

## Objective

Allow the Flutter app to update mower firmware over BLE while retaining the
stock Arduino SAM-BA bootloader for USB recovery. The running application must
write only to a secondary slot and must never overwrite itself or MCUboot.

## Verified flash layout

All boundaries are aligned to the nRF52840's 4 KiB erase pages.

| Region | Address range | Size | Purpose |
| --- | --- | ---: | --- |
| Stock SAM-BA bootloader | `0x00000`-`0x0FFFF` | 64 KiB | Arduino USB recovery; currently about 35,768 bytes occupied |
| MCUboot second stage | `0x10000`-`0x1FFFF` | 64 KiB | Image validation, swap, trial boot, and rollback |
| Primary mower image | `0x20000`-`0x8DFFF` | 440 KiB | Active MCUboot-format application |
| Secondary update image | `0x8E000`-`0xFBFFF` | 440 KiB | Inactive image received over BLE |
| Swap scratch/status | `0xFC000`-`0xFFFFF` | 16 KiB | Power-failure-safe scratch and persistent swap state |

The MCUboot prototype occupies 24,296 bytes of its 64 KiB region. The current
Arduino mower payload is about 363 KiB including its MCUboot header and hash,
leaving roughly 77 KiB in each 440 KiB slot. Image size must be monitored as
features are added.

## Application placement

The standard Arduino mbed core 4.6.0 application layout is:

```text
FLASH ORIGIN = 0x10000
FLASH LENGTH = 0xF0000
```

For MCUboot, the raw Arduino payload is linked as:

```text
FLASH ORIGIN = 0x20200
FLASH LENGTH = 0x6DE00
MBED_APP_START = 0x20200
MBED_APP_SIZE = 0x6DE00
```

The first `0x200` bytes of the primary slot are reserved for the MCUboot image
header. MCUboot therefore finds the image at `0x20000` and hands control to the
Arduino vector table at `0x20200`.

The project-owned files in `firmware/ota/arduino/` relocate the Arduino linker
layout without modifying the installed Arduino core.

## Arduino-compatible MCUboot handoff

MCUboot normally chain-loads an application with the Cortex-M global interrupt
mask (`PRIMASK`) set. Zephyr startup clears that mask, but the prebuilt Arduino
mbed RTOS startup assumes reset-state interrupts are already enabled. Without a
compatibility handoff, USB, BLE, and `setup()` never start.

The patch in `firmware/ota/mcuboot/arduino-mbed-handoff.patch` restores the
reset-state interrupt mask immediately before MCUboot calls the Arduino reset
handler. This was hardware-tested: without it the diagnostic LED remained off;
with it USB returned on COM3 and Flutter connected over BLE.

The patch must be applied to the selected MCUboot source before building the
second stage. It is deliberately stored in the repository because the Zephyr
workspace under `.tools/` is ignored.

### Nano sensor power and I2C state

MCUboot also leaves the Nano 33 BLE Sense Rev2's internal sensor interface in a
different state from a direct SAM-BA application start. The internal I2C bus
still acknowledged all five onboard devices, including the BMI270 at `0x68`,
but the BMI270 chip-ID register returned `0x20` instead of the required `0x24`.
The IMU library consequently reported `BMI2_E_DEV_NOT_FOUND`, halted startup,
and BLE never began advertising.

This was reproduced on two boards. A conventional SAM-BA IMU test succeeded on
the same spare board, proving the sensor hardware and Arduino library were
sound. The permanent application startup sequence now explicitly disables the
internal I2C pull-ups, power-cycles the sensor 3.3 V rail, waits for it to
settle, and re-enables the pull-ups before calling `IMU.begin()`. With that
sequence the chip ID returns `0x24`, the IMU initializes, and Flutter connects
over BLE. Do not remove this reset sequence while MCUboot is the second-stage
boot manager.

## Two distributable image types

### USB/SAM-BA recovery image

Output name: `mower-sam-ba.bin`

Contains MCUboot at relative offset zero followed by a padded gap and the
MCUboot-format mower image at relative offset `0x10000`. SAM-BA maps the file's
start to physical address `0x10000`, producing:

```text
physical 0x10000: MCUboot
physical 0x20000: mower image header and application
```

Use this image for initial installation and wired recovery. It does not contain
the stock SAM-BA bootloader below physical `0x10000`.

### BLE update image

Output name: `mower-update.bin`

Contains only the MCUboot-format mower application: header, payload, hash, and
eventually a digital signature. Flutter sends this file to the running mower,
which writes it to the secondary slot at `0x8E000`. It does not contain SAM-BA
or MCUboot.

Initially the latest BLE update image will be embedded as a Flutter asset. A
later version may download signed images from a release server without changing
the verification model.

## Intended BLE update sequence

1. The About & Diagnostics screen shows the connected mower version and the
   bundled update version.
2. Flutter enables **Update mower firmware** only when the board is compatible,
   the mower is safely inactive, supply voltage is acceptable, and no update is
   already running.
3. Flutter transfers the bundled update image in chunks over BLE.
4. The running mower writes only to the secondary slot at `0x8E000` and reports
   progress.
5. The mower verifies image length, board identity, version, SHA-256 hash, and
   digital signature before marking it pending.
6. The mower restarts. MCUboot performs a power-failure-safe swap using the
   scratch area.
7. The new image boots in trial mode, performs health checks, and confirms
   itself.
8. If it does not confirm, MCUboot restores the previous image on a subsequent
   restart.
9. Flutter reconnects and verifies the newly reported firmware version.

## Stage-one BLE transport test

The first implemented OTA stage is intentionally non-destructive. It proves
ordered chunk transfer and end-to-end CRC-32 validation but does not retain the
payload, erase or write flash, mark an MCUboot image pending, or reboot.

Three characteristics extend the existing mower service:

| Characteristic | UUID suffix | Properties | Payload |
| --- | --- | --- | --- |
| OTA control | `...def4` | Write | Command plus optional parameters |
| OTA data | `...def5` | Write | 32-bit offset plus up to 16 data bytes |
| OTA status | `...def6` | Read, Notify | State, result, received length, expected length |

All multibyte integers are unsigned little-endian. Control command `0x01`
starts a transfer and contains the total length and expected IEEE CRC-32.
Command `0x02` finishes and validates it; command `0x03` aborts and resets the
receiver. The status payload is ten bytes: one state byte, one result byte,
four received-length bytes, and four expected-length bytes.

The receiver accepts only the next exact byte offset, rejects chunks that
would exceed the announced length, and currently limits test transfers to
4096 bytes. Flutter sends a deterministic 1024-byte payload in 16-byte chunks,
uses acknowledged writes, and reads status after every chunk. The About &
Diagnostics screen reports progress and the validated CRC-32. This deliberately
slow stop-and-confirm flow establishes correctness before adding flash writes
or optimizing throughput.

### Secondary-slot flash test

A separate, explicitly confirmed diagnostics action exercises real internal
flash writes without attempting an update. Control command `0x04` starts this
mode. The Arduino accepts exactly 1024 bytes and uses a compile-time address of
`0x8E000`; the phone cannot provide or alter the destination address.

Before receiving data, the firmware validates the FlashIAP-reported flash
range, erase-sector size, program alignment, secondary-slot boundary, and test
length. It then erases only the first 4 KiB sector of the secondary slot,
programs aligned 16-byte chunks, and calculates the streaming CRC-32. At finish
it reads the 1 KiB back from flash and independently recalculates CRC-32 before
reporting success.

This test destroys any pending image already stored at the beginning of the
secondary slot. It cannot write the primary slot, MCUboot, SAM-BA, the scratch
area, or the remainder of the secondary slot. It does not mark an image
pending, invoke MCUboot, or reboot. Its purpose is to prove the flash API and
BLE/flash interaction before extending erasure and programming across the full
secondary slot.

## Current LED diagnostics

The Arduino mower sketch uses the yellow `LED_BUILTIN` during startup:

- Solid yellow: BLE advertising started successfully.
- Repeating two-blink pattern: IMU initialization failed.
- Repeating three-blink pattern: BLE initialization failed.
- Off: execution did not reach Arduino `setup()`.

The earlier Zephyr handoff test used Zephyr's `led0` alias, which illuminated
the red LED rather than Arduino's yellow built-in LED.

## Safety and recovery rules

- The Arduino is a monitoring, warning, diagnostics, and logging system only.
  It must have no electrical or mechanical connection capable of changing
  engine speed, governor position, fuel delivery, or engine shutdown.
- The operator remains responsible for reducing engine speed/load and shutting
  the engine down by closing off the fuel supply.
- Arduino outputs are limited to the siren, local status indication, BLE
  telemetry, and persistent diagnostic logging.
- Never erase or program the primary slot from the running application.
- Reject images that exceed the slot or target a different board/layout.
- Require a valid digital signature before allowing an update or boot.
- Reject updates while the engine or control outputs are active.
- Make every swap step resumable after arbitrary power loss.
- Preserve and test the SAM-BA USB recovery path after boot-manager changes.
- An ordinary Arduino upload starts at physical `0x10000` and overwrites
  MCUboot. Use a combined recovery image once this layout is installed.

## Next milestones

1. Add production signing keys and enable signature enforcement in MCUboot.
2. Add a BLE update service that can erase and write only the secondary slot.
3. Add the update controls and progress display to About & Diagnostics.
4. Test interrupted transfers, interrupted swaps, trial confirmation, rollback,
   incompatible images, corrupt images, and low-voltage rejection.
