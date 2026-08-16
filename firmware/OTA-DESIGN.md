# BLE firmware update design

## Objective

Allow the Flutter app to update mower firmware over BLE while retaining the
stock Arduino SAM-BA bootloader for USB recovery and preventing the running
application from overwriting itself.

## Verified current layout

These values were measured from Arduino mbed core 4.6.0 and the built ELF/HEX
files for the Nano 33 BLE Sense Rev2:

| Region | Address range | Notes |
| --- | --- | --- |
| SAM-BA bootloader | `0x00000`–`0x08BB7` | 35,768 bytes currently occupied |
| Reserved boot area | `0x00000`–`0x0FFFF` | Arduino application begins after 64 KiB |
| Current application | `0x10000`–approximately `0x68A00` | 362,944-byte binary |
| Physical flash | `0x00000`–`0xFFFFF` | 1 MiB total |

The standard Arduino linker configuration is:

```text
FLASH ORIGIN = 0x10000
FLASH LENGTH = 0xF0000
```

## Provisional OTA layout

All boundaries are aligned to the nRF52840's 4 KiB flash erase pages.

| Region | Address range | Size |
| --- | --- | --- |
| Stock SAM-BA bootloader | `0x00000`–`0x0FFFF` | 64 KiB reserved |
| Second-stage image manager | `0x10000`–`0x1FFFF` | 64 KiB |
| Primary mower application | `0x20000`–`0x8DFFF` | 440 KiB |
| Secondary update slot | `0x8E000`–`0xFBFFF` | 440 KiB |
| Swap scratch and status | `0xFC000`–`0xFFFFF` | 16 KiB |

The current application occupies about 354 KiB, leaving approximately 86 KiB
of growth space in each application slot. Image size must be monitored as oil
pressure, temperature, RPM, logging, and safety features are added.

## Boot and update sequence

1. The stock SAM-BA bootloader starts after reset.
2. In USB recovery mode it accepts a combined recovery image.
3. During normal boot it starts the second-stage manager at `0x10000`.
4. The manager validates the primary image and starts it at `0x20000`.
5. The running mower application receives a signed image over BLE and writes
   only to the secondary slot.
6. After the transfer, it verifies the image hash and records an update-pending
   flag before resetting.
7. The manager performs a power-failure-safe swap using scratch pages and a
   persistent progress journal.
8. The new application boots in trial mode and must confirm itself.
9. If confirmation does not occur, the manager rolls back to the old image.

## USB recovery consequence

The normal Arduino upload image begins at `0x10000`. With this layout, an
ordinary upload would overwrite the second-stage manager. USB recovery must
therefore upload a combined artifact containing both the manager and the mower
application, or use a custom upload workflow that protects the manager.

## Safety rules

- Do not change the working board's boot or linker configuration until a
  second Nano or an SWD recovery probe is available.
- Never erase or program the active application slot from the application.
- Verify board identity, image length, SHA-256 hash, and digital signature.
- Reject updates while the engine is running or supply voltage is unsafe.
- Make every swap step resumable after arbitrary power loss.
- Preserve a tested USB or SWD recovery path.

## Next prototype steps

1. Select and build a second-stage manager, preferably based on MCUboot.
2. Link a trivial test application at `0x20000` without flashing it.
3. Produce a combined SAM-BA recovery image.
4. Verify the complete boot chain on a spare Nano or with an SWD probe ready.
5. Test interrupted swaps and rollback before implementing BLE transfer.
