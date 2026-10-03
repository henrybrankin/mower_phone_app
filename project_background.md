# Mower EMU App Background

## Problem overview

The project exists to protect a mower engine from oil starvation and related failures.

- Mower engines can lose oil pressure when operating on uneven terrain, steep slopes, or under heavy loads. Of most interest to this project is where the engine is on a steep slope and the oil accumulates at one side or end of the sump and the oil pump
pickup is not immersed in oil, with a resulting loss of oil pressure.
- Oil starvation can cause rapid engine damage before the operator notices.
- A dedicated monitoring system can warn the operator of oil pressure loss, save the motor, and provide a safety cutoff or alert.
- the mower itself will have a PCB mith microcontroller that will monitor the oil pressure from a sensor that will be added as part of the project.
- we are also considering monitoring oil temperature
- on the mower PCB we are planning to put an inclination sensor so we can monitor the pitch and roll of the mower.
- plan to build, on the MCU, a 2-D map of pitch vs roll. In each cell of the map store times-visited, max pressure, min pressure.
- the PCB will drive a siren for warning the operator - the siren will sound continuously when oil pressure is lost, and will sound intermittently when nearing a danger point.
- the engine has a generator built into the flywheel that would normally be used to charge a battery for electric start. We plan to use the ripple on this generator output to detect the RPM of the engine.
- there will be two sofware parts: 1. the firmware on the mower - running on a microcontroller. 2. an app to run on an iPhone. BLE will be used to communicate between the mower and the phone.

## Core goals

- Read live mower telemetry for:
  - roll and pitch
  - oil pressure
  - oil temperature
- Detect edge cases where low oil pressure coincides with unsafe pitch/roll conditions.
- Build a local map of roll vs pitch that records trouble points.
- Present live status and historical failure points in a mobile app.
- Keep the design local-first, with BLE between phone and mower.
- plan to implement BLE OTA firmware updates so the microcontroller board does not have to be removed from the mower to update the firmware.

## Current implementation notes

- The Flutter app is currently a UI scaffold in `lib/main.dart` with mock telemetry.
- There is a `feature_backlog.md` for future ideas such as time sync, event logging, and BLE lockout behavior.
- The app should eventually pair with the mower via BLE and display real readings instead of simulated data.
- on the mower we plan to use "Arduino Nano 33 BLE Sense Rev 2" microcontroller board. This board has BLE for communication with the phone app, and a 9-axis inertial measurement unit that will enable us to determine the pitch and roll of the mower.
- Project layout:
  - Flutter app code lives in `lib/`
  - EMU firmware code lives in `firmware/mower_mcu/`

## Important design decisions

- The mower should be the BLE peripheral and advertise when powered on.
- The first phone to connect by BLE should be allowed in, and the mower should stop advertising after that connection.
- A mower power cycle should be required to hand the connection to a different phone.
- The app should be able to send a "set as level" zero-calibration command to the mower so the mower can treat the current orientation as `0,0`.

## EMU pin assignments

These Arduino Nano 33 BLE Sense Rev2 assignments are reserved for the mower
interface PCB:

| Pin | Direction | Function | Active state |
| --- | --- | --- | --- |
| `A1` | Output | Siren relay driver | `HIGH` switches the siren on |
| `A6` | Input | Oil-pressure switch | `HIGH` means pressure is good; `LOW` means pressure is lost |
| `A2` | Input | Engine flywheel-generator RPM signal | Signal conditioning and decoding are to be determined experimentally |
| `D9` | Output | MAX31856 thermocouple interface chip select | SPI chip select |
| `D10` | Input | MAX31856 `FAULT` signal | Thermocouple/interface fault indication |
| `D8` | Input | MAX31856 `DRDY` signal | Temperature conversion data-ready indication |
| `SCK` / `MOSI` / `MISO` | SPI | MAX31856 thermocouple interface | Standard Nano hardware-SPI signals |

The `A1` output must be driven `LOW` immediately during firmware startup. The
oil-pressure input circuitry must present only a valid 3.3 V logic level to
`A6` and should bias a disconnected input toward the pressure-lost state. The
raw generator waveform must not be connected directly to `A2`: its voltage,
polarity, frequency, noise, and transient behaviour must first be measured,
then suitable protection and waveform conditioning designed and bench-tested.

Engine temperature will be measured with a thermocouple connected to a
MAX31856 converter. The MAX31856 communicates with the Nano over hardware SPI,
using `D9` as its dedicated chip select. Its separate `FAULT` and `DRDY`
outputs connect to `D10` and `D8`, respectively. The PCB design must apply the
MAX31856 datasheet requirements for pull-ups, decoupling, thermocouple input
filtering, and cold-junction measurement layout.

Oil-pressure loss has priority over tilt-map warnings: confirmed pressure loss
while the engine is running commands a continuous siren, whereas approaching a
dangerous roll/pitch region commands an intermittent warning. Engine-running
state will ultimately be determined using the `A2` RPM signal.

## Latest progress

- Confirmed the Flutter app is ready to connect to a BLE peripheral and parse telemetry.
- Investigated Arduino CLI firmware build for Seeeduino XIAO nRF52840 and found board/core BLE compatibility problems.
- Determined `ArduinoBLE` is not compatible with the non-Sense XIAO board package due to missing transport support.
- We have now ordered an `Arduino Nano 33 BLE Sense V2` board to continue with a supported BLE + 9-axis IMU platform.
- No repo source files were changed during the compatibility investigation.

## Notes for restart

If you restart the project later, use this document as the high-level summary:

- problem: oil starvation and damaging low oil pressure
- mower sensors: roll/pitch plus pressure, temperature and RPM.
- mower PCB output - driver for 12 Volt siren. (Relay contacts or FET)
- reserved mower I/O: `A1` siren output, `A6` oil-pressure-good input, and `A2`
  conditioned flywheel-generator RPM input.
- engine-temperature interface: MAX31856 on hardware SPI, with `D9` chip
  select, `D10` `FAULT`, and `D8` `DRDY`.
- connectivity: BLE app-to-mower, no mower button required for pairing.
- BLE lockout model: first phone gets the mower until the mower power cycles
- debugging utility: time-sync and event log retrieval are valuable for diagnostics
- OTA firmware updates over BLE will be required.

## Development environments

- macOS project directory: `~/development/mower_phone_app`

