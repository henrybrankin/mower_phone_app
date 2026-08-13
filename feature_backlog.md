# Mower Phone App Feature Backlog

## Time sync and event log

- Consider adding a BLE command for the app to send current time to the mower.
- This allows the mower to timestamp events without requiring a real-time clock.
- Useful log events:
  - zero calibration
  - oil pressure fault or drop
  - roll/pitch threshold warnings
  - BLE connect/disconnect and command receipt
- The mower should store the log locally and expose a retrieval command for the app.
- This is primarily useful for debugging, diagnostics, and later field review.

## BLE connection lockout

- Mower advertises and accepts the first phone that connects after power-up.
- Once connected, the mower stops advertising and locks out other phones.
- The connection stays exclusive until the mower is switched off and on again.
- This keeps pairing simple and avoids multi-phone contention.

## Firmware updates

- we will have BLE OTA firmware updates in a later phase.
- The mower should be updatable over BLE so the board does not need to be removed for software changes.
- This should be implemented after the main BLE telemetry and IMU features are working reliably.
