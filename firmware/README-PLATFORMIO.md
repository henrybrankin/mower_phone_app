PlatformIO workflow for XIAO nRF52840

Prerequisites
- Install PlatformIO extension in VS Code or the `platformio` CLI.

Build & upload

- To build:

```powershell
pio run -d firmware
```

- To upload (auto-detect port):

```powershell
pio run -d firmware -t upload -e xiao_nrf52840
```

Notes
- `platformio.ini` targets the `seeed_xiao_nrf52840` board on the `nordicnrf52` platform and pulls `NimBLE-Arduino` as a library.
- If PlatformIO cannot find the board, run `pio boards | Select-String xiao` to list available board IDs and adjust `platformio.ini`.
