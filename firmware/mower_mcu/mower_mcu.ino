#include <Arduino.h>
#include <Wire.h>
#include <Arduino_BMI270_BMM150.h>
#include <FlashIAP.h>

#include <ArduinoBLE.h>

// Service and characteristic UUIDs
#define MOWER_SERVICE_UUID        "12345678-1234-5678-1234-56789abcdef0"
#define TELEMETRY_CHAR_UUID       "12345678-1234-5678-1234-56789abcdef1"
#define CONTROL_CHAR_UUID         "12345678-1234-5678-1234-56789abcdef2"
#define VERSION_CHAR_UUID         "12345678-1234-5678-1234-56789abcdef3"
#define OTA_CONTROL_CHAR_UUID     "12345678-1234-5678-1234-56789abcdef4"
#define OTA_DATA_CHAR_UUID        "12345678-1234-5678-1234-56789abcdef5"
#define OTA_STATUS_CHAR_UUID      "12345678-1234-5678-1234-56789abcdef6"

const char kFirmwareVersion[] = "0.1.1";

bool g_isConnected = false;
bool g_zeroCommandReceived = false;
unsigned long lastMillis = 0;
float g_filteredRoll = 0.0f;
float g_filteredPitch = 0.0f;
float g_rollZeroOffset = 0.0f;
float g_pitchZeroOffset = 0.0f;
float g_headingDeg = 0.0f;
bool g_headingValid = false;
char g_serialCommand[32];
size_t g_serialCommandLength = 0;
const unsigned long kUpdateIntervalMs = 20;
const float kComplementaryAlpha = 0.95f;
const float kHeadingAlpha = 0.2f;
const uint32_t kMaxOtaTransportTestBytes = 4096;
const uint32_t kSecondarySlotAddress = 0x0008E000u;
const uint32_t kSecondarySlotSize = 0x0006E000u;
const uint32_t kOtaFlashTestBytes = 1024;

enum OtaState : uint8_t {
  kOtaIdle = 0,
  kOtaReceiving = 1,
  kOtaComplete = 2,
  kOtaError = 3,
  kOtaPreparing = 4,
};

enum OtaResult : uint8_t {
  kOtaResultOk = 0,
  kOtaResultInvalidCommand = 1,
  kOtaResultInvalidLength = 2,
  kOtaResultUnexpectedOffset = 3,
  kOtaResultLengthMismatch = 4,
  kOtaResultCrcMismatch = 5,
  kOtaResultNotReceiving = 6,
  kOtaResultFlashInitFailed = 7,
  kOtaResultFlashLayoutInvalid = 8,
  kOtaResultFlashEraseFailed = 9,
  kOtaResultFlashProgramFailed = 10,
  kOtaResultFlashReadbackFailed = 11,
  kOtaResultInvalidImage = 12,
  kOtaResultSlotNotPrepared = 13,
};

uint8_t g_otaState = kOtaIdle;
uint8_t g_otaResult = kOtaResultOk;
uint32_t g_otaExpectedBytes = 0;
uint32_t g_otaReceivedBytes = 0;
uint32_t g_otaExpectedCrc = 0;
uint32_t g_otaRunningCrc = 0xFFFFFFFFu;
uint32_t g_otaLastPublishedBytes = 0;
bool g_otaWritesFlash = false;
bool g_otaStagesFullImage = false;
bool g_otaTelemetryPaused = false;
bool g_flashInitialized = false;
bool g_secondarySlotBlank = false;
uint32_t g_otaNextSectorEraseAddress = kSecondarySlotAddress;
unsigned long g_otaLastStatusMillis = 0;
mbed::FlashIAP g_flash;

static void haltWithBlinkCode(uint8_t blinkCount) {
  for (;;) {
    for (uint8_t i = 0; i < blinkCount; ++i) {
      digitalWrite(LED_BUILTIN, HIGH);
      delay(150);
      digitalWrite(LED_BUILTIN, LOW);
      delay(150);
    }
    delay(900);
  }
}

static uint8_t headingToByte(float headingDeg) {
  float wrapped = fmodf(headingDeg, 360.0f);
  if (wrapped < 0.0f) {
    wrapped += 360.0f;
  }
  return static_cast<uint8_t>(constrain(roundf(wrapped * (255.0f / 360.0f)), 0.0f, 255.0f));
}

static float wrapHeading360(float headingDeg) {
  float wrapped = fmodf(headingDeg, 360.0f);
  if (wrapped < 0.0f) {
    wrapped += 360.0f;
  }
  return wrapped;
}

static void updateHeadingFromMag(float mx, float my, float mz, float rollDeg, float pitchDeg) {
  float rollRad = rollDeg * PI / 180.0f;
  float pitchRad = pitchDeg * PI / 180.0f;
  float xh = mx * cosf(pitchRad) + mz * sinf(pitchRad);
  float yh = mx * sinf(rollRad) * sinf(pitchRad) + my * cosf(rollRad) - mz * sinf(rollRad) * cosf(pitchRad);
  float headingDeg = wrapHeading360(atan2f(yh, xh) * 180.0f / PI);

  if (!g_headingValid) {
    g_headingDeg = headingDeg;
    g_headingValid = true;
    return;
  }

  float delta = headingDeg - g_headingDeg;
  if (delta > 180.0f) {
    delta -= 360.0f;
  } else if (delta < -180.0f) {
    delta += 360.0f;
  }
  g_headingDeg = wrapHeading360(g_headingDeg + (kHeadingAlpha * delta));
}

static void serviceSerialCommands() {
  while (Serial.available() > 0) {
    const char value = static_cast<char>(Serial.read());
    if (value == '\r' || value == '\n') {
      if (g_serialCommandLength > 0) {
        g_serialCommand[g_serialCommandLength] = '\0';
        if (strcmp(g_serialCommand, "MOWER_EMU?") == 0) {
          char response[96];
          snprintf(response, sizeof(response),
                   "MOWER_EMU/1 FW=%s ID=%08lX%08lX", kFirmwareVersion,
                   static_cast<unsigned long>(NRF_FICR->DEVICEADDR[1]),
                   static_cast<unsigned long>(NRF_FICR->DEVICEADDR[0]));
          Serial.println(response);
        }
        g_serialCommandLength = 0;
      }
    } else if (g_serialCommandLength < sizeof(g_serialCommand) - 1) {
      g_serialCommand[g_serialCommandLength++] = value;
    } else {
      // Discard an oversized or binary command without blocking the main loop.
      g_serialCommandLength = 0;
    }
  }
}

static uint32_t readUint32Le(const uint8_t* bytes) {
  return static_cast<uint32_t>(bytes[0]) |
         (static_cast<uint32_t>(bytes[1]) << 8) |
         (static_cast<uint32_t>(bytes[2]) << 16) |
         (static_cast<uint32_t>(bytes[3]) << 24);
}

static void writeUint32Le(uint8_t* bytes, uint32_t value) {
  bytes[0] = static_cast<uint8_t>(value);
  bytes[1] = static_cast<uint8_t>(value >> 8);
  bytes[2] = static_cast<uint8_t>(value >> 16);
  bytes[3] = static_cast<uint8_t>(value >> 24);
}

static uint32_t updateCrc32(uint32_t crc, const uint8_t* bytes, size_t length) {
  for (size_t i = 0; i < length; ++i) {
    crc ^= bytes[i];
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
  }
  return crc;
}

BLEService mowerService(MOWER_SERVICE_UUID);
BLECharacteristic telemetryChar(TELEMETRY_CHAR_UUID, BLERead | BLENotify, 4);
BLECharacteristic controlChar(CONTROL_CHAR_UUID, BLEWrite, 1);
BLEStringCharacteristic versionChar(VERSION_CHAR_UUID, BLERead, 16);
BLECharacteristic otaControlChar(OTA_CONTROL_CHAR_UUID, BLEWrite, 9);
BLECharacteristic otaDataChar(OTA_DATA_CHAR_UUID,
                              BLEWrite | BLEWriteWithoutResponse, 244);
BLECharacteristic otaStatusChar(OTA_STATUS_CHAR_UUID, BLERead | BLENotify, 10);

static void publishOtaStatus() {
  uint8_t status[10] = {g_otaState, g_otaResult};
  writeUint32Le(status + 2, g_otaReceivedBytes);
  writeUint32Le(status + 6, g_otaExpectedBytes);
  otaStatusChar.setValue(status, sizeof(status));
  if (g_isConnected) {
    otaStatusChar.broadcast();
  }
  g_otaLastStatusMillis = millis();
}

static void resetOtaTransfer() {
  g_otaState = kOtaIdle;
  g_otaResult = kOtaResultOk;
  g_otaExpectedBytes = 0;
  g_otaReceivedBytes = 0;
  g_otaExpectedCrc = 0;
  g_otaRunningCrc = 0xFFFFFFFFu;
  g_otaLastPublishedBytes = 0;
  g_otaWritesFlash = false;
  g_otaStagesFullImage = false;
  g_otaTelemetryPaused = false;
}

static void setOtaError(uint8_t result) {
  g_otaState = kOtaError;
  g_otaResult = result;
  g_otaTelemetryPaused = false;
  publishOtaStatus();
}

static bool eraseSecondarySlot() {
  if (!g_flashInitialized) {
    if (g_flash.init() != 0) {
      return false;
    }
    g_flashInitialized = true;
  }

  const uint32_t flashStart = g_flash.get_flash_start();
  const uint32_t flashSize = g_flash.get_flash_size();
  const uint32_t slotEnd = kSecondarySlotAddress + kSecondarySlotSize;
  if (kSecondarySlotAddress < flashStart ||
      slotEnd > flashStart + flashSize) {
    return false;
  }

  uint32_t address = kSecondarySlotAddress;
  while (address < slotEnd) {
    const uint32_t sectorSize = g_flash.get_sector_size(address);
    if (sectorSize == 0 || address + sectorSize > slotEnd ||
        g_flash.erase(address, sectorSize) != 0) {
      return false;
    }
    address += sectorSize;
  }

  g_otaNextSectorEraseAddress = slotEnd;
  g_secondarySlotBlank = true;
  return true;
}

static bool prepareFlashTransfer(bool fullImage) {
  if (!g_flashInitialized) {
    if (g_flash.init() != 0) {
      setOtaError(kOtaResultFlashInitFailed);
      return false;
    }
    g_flashInitialized = true;
  }

  const uint32_t flashStart = g_flash.get_flash_start();
  const uint32_t flashSize = g_flash.get_flash_size();
  const uint32_t sectorSize = g_flash.get_sector_size(kSecondarySlotAddress);
  const uint32_t programSize = g_flash.get_page_size();
  if (kSecondarySlotAddress < flashStart ||
      kSecondarySlotAddress + kSecondarySlotSize > flashStart + flashSize ||
      sectorSize == 0 ||
      sectorSize > kSecondarySlotSize ||
      kSecondarySlotAddress % sectorSize != 0 ||
      programSize == 0 ||
      kSecondarySlotAddress % programSize != 0 ||
      (!fullImage && kOtaFlashTestBytes > sectorSize)) {
    setOtaError(kOtaResultFlashLayoutInvalid);
    return false;
  }
  if (fullImage) {
    if (!g_secondarySlotBlank) {
      setOtaError(kOtaResultSlotNotPrepared);
      return false;
    }
    g_otaNextSectorEraseAddress = kSecondarySlotAddress + kSecondarySlotSize;
  } else {
    g_otaNextSectorEraseAddress = kSecondarySlotAddress;
    if (g_flash.erase(kSecondarySlotAddress, sectorSize) != 0) {
      setOtaError(kOtaResultFlashEraseFailed);
      return false;
    }
    g_otaNextSectorEraseAddress += sectorSize;
  }
  return true;
}

static bool eraseFlashThrough(uint32_t exclusiveOffset) {
  const uint32_t requiredEnd = kSecondarySlotAddress + exclusiveOffset;
  const uint32_t slotEnd = kSecondarySlotAddress + kSecondarySlotSize;
  while (g_otaNextSectorEraseAddress < requiredEnd) {
    const uint32_t sectorSize =
        g_flash.get_sector_size(g_otaNextSectorEraseAddress);
    if (sectorSize == 0 ||
        g_otaNextSectorEraseAddress + sectorSize > slotEnd ||
        g_flash.erase(g_otaNextSectorEraseAddress, sectorSize) != 0) {
      setOtaError(kOtaResultFlashEraseFailed);
      return false;
    }
    g_otaNextSectorEraseAddress += sectorSize;
  }
  return true;
}

static bool verifyFlashReadback() {
  alignas(4) uint8_t readBuffer[64];
  uint32_t crc = 0xFFFFFFFFu;
  for (uint32_t offset = 0; offset < g_otaExpectedBytes;
       offset += sizeof(readBuffer)) {
    const uint32_t remaining = g_otaExpectedBytes - offset;
    const uint32_t length = remaining < sizeof(readBuffer)
                                ? remaining
                                : sizeof(readBuffer);
    if (g_flash.read(readBuffer, kSecondarySlotAddress + offset, length) != 0) {
      setOtaError(kOtaResultFlashReadbackFailed);
      return false;
    }
    crc = updateCrc32(crc, readBuffer, length);
  }
  if ((crc ^ 0xFFFFFFFFu) != g_otaExpectedCrc) {
    setOtaError(kOtaResultFlashReadbackFailed);
    return false;
  }
  return true;
}

static bool verifyMcubootImage() {
  alignas(4) uint8_t header[32];
  if (g_flash.read(header, kSecondarySlotAddress, sizeof(header)) != 0) {
    setOtaError(kOtaResultFlashReadbackFailed);
    return false;
  }
  const uint32_t magic = readUint32Le(header);
  const uint16_t headerSize = static_cast<uint16_t>(header[8]) |
                              (static_cast<uint16_t>(header[9]) << 8);
  const uint32_t imageSize = readUint32Le(header + 12);
  const uint32_t tlvOffset = static_cast<uint32_t>(headerSize) + imageSize;
  if (magic != 0x96F3B83Du || headerSize != 0x0200u || imageSize == 0 ||
      tlvOffset + 4 > g_otaExpectedBytes) {
    setOtaError(kOtaResultInvalidImage);
    return false;
  }

  alignas(4) uint8_t tlvInfo[4];
  if (g_flash.read(tlvInfo, kSecondarySlotAddress + tlvOffset,
                   sizeof(tlvInfo)) != 0) {
    setOtaError(kOtaResultFlashReadbackFailed);
    return false;
  }
  const uint16_t tlvMagic = static_cast<uint16_t>(tlvInfo[0]) |
                            (static_cast<uint16_t>(tlvInfo[1]) << 8);
  if (tlvMagic != 0x6907u && tlvMagic != 0x6908u) {
    setOtaError(kOtaResultInvalidImage);
    return false;
  }
  return true;
}

static void handleOtaControl(BLEDevice, BLECharacteristic) {
  const int length = otaControlChar.valueLength();
  const uint8_t* value = otaControlChar.value();
  if (length < 1) {
    setOtaError(kOtaResultInvalidCommand);
    return;
  }

  switch (value[0]) {
    case 0x01:
    case 0x04:
    case 0x05:
      if (length != 9) {
        setOtaError(kOtaResultInvalidCommand);
        return;
      }
      g_otaExpectedBytes = readUint32Le(value + 1);
      g_otaExpectedCrc = readUint32Le(value + 5);
      g_otaReceivedBytes = 0;
      g_otaRunningCrc = 0xFFFFFFFFu;
      g_otaLastPublishedBytes = 0;
      g_otaWritesFlash = value[0] == 0x04 || value[0] == 0x05;
      g_otaStagesFullImage = value[0] == 0x05;
      if (g_otaExpectedBytes == 0 ||
          (!g_otaWritesFlash &&
           g_otaExpectedBytes > kMaxOtaTransportTestBytes) ||
          (g_otaStagesFullImage &&
           g_otaExpectedBytes > kSecondarySlotSize)) {
        setOtaError(kOtaResultInvalidLength);
        return;
      }
      if (g_otaWritesFlash && !g_otaStagesFullImage &&
          g_otaExpectedBytes != kOtaFlashTestBytes) {
        setOtaError(kOtaResultInvalidLength);
        return;
      }
      if (g_otaWritesFlash && !prepareFlashTransfer(g_otaStagesFullImage)) {
        if (g_otaState != kOtaError) {
          setOtaError(kOtaResultInvalidLength);
        }
        return;
      }
      if (g_otaStagesFullImage &&
          (g_otaExpectedBytes < 0x204u ||
           g_otaExpectedBytes % g_flash.get_page_size() != 0)) {
        setOtaError(kOtaResultInvalidLength);
        return;
      }
      g_otaTelemetryPaused = true;
      if (g_otaStagesFullImage) {
        g_secondarySlotBlank = false;
      }
      g_otaState = kOtaReceiving;
      g_otaResult = kOtaResultOk;
      publishOtaStatus();
      break;

    case 0x02:
      if (g_otaState != kOtaReceiving) {
        setOtaError(kOtaResultNotReceiving);
      } else if (g_otaReceivedBytes != g_otaExpectedBytes) {
        setOtaError(kOtaResultLengthMismatch);
      } else if ((g_otaRunningCrc ^ 0xFFFFFFFFu) != g_otaExpectedCrc) {
        setOtaError(kOtaResultCrcMismatch);
      } else if (g_otaWritesFlash && !verifyFlashReadback()) {
        return;
      } else if (g_otaStagesFullImage && !verifyMcubootImage()) {
        return;
      } else {
        g_otaState = kOtaComplete;
        g_otaResult = kOtaResultOk;
        g_otaTelemetryPaused = false;
        publishOtaStatus();
      }
      break;

    case 0x03:
      resetOtaTransfer();
      publishOtaStatus();
      break;

    default:
      setOtaError(kOtaResultInvalidCommand);
      break;
  }
}

static void handleOtaData(BLEDevice, BLECharacteristic) {
  const int length = otaDataChar.valueLength();
  const uint8_t* value = otaDataChar.value();
  if (g_otaState != kOtaReceiving) {
    setOtaError(kOtaResultNotReceiving);
    return;
  }
  if (length <= 4) {
    setOtaError(kOtaResultInvalidLength);
    return;
  }

  const uint32_t offset = readUint32Le(value);
  const uint32_t payloadLength = static_cast<uint32_t>(length - 4);
  if (offset != g_otaReceivedBytes) {
    // Gaps and duplicates are recoverable. The status offset tells Flutter
    // exactly where transmission should resume.
    publishOtaStatus();
    return;
  }
  if (g_otaReceivedBytes > g_otaExpectedBytes ||
      payloadLength > g_otaExpectedBytes - g_otaReceivedBytes) {
    setOtaError(kOtaResultInvalidLength);
    return;
  }

  if (g_otaWritesFlash) {
    const uint32_t programSize = g_flash.get_page_size();
    if (payloadLength > 240 || payloadLength % programSize != 0 ||
        offset % programSize != 0) {
      setOtaError(kOtaResultInvalidLength);
      return;
    }
    alignas(4) uint8_t programBuffer[240];
    memcpy(programBuffer, value + 4, payloadLength);
    if (!eraseFlashThrough(offset + payloadLength)) {
      return;
    }
    if (g_flash.program(programBuffer, kSecondarySlotAddress + offset,
                        payloadLength) != 0) {
      setOtaError(kOtaResultFlashProgramFailed);
      return;
    }
  }

  g_otaRunningCrc = updateCrc32(g_otaRunningCrc, value + 4, payloadLength);
  g_otaReceivedBytes += payloadLength;
  if (g_otaReceivedBytes == g_otaExpectedBytes ||
      g_otaReceivedBytes - g_otaLastPublishedBytes >= 256) {
    g_otaLastPublishedBytes = g_otaReceivedBytes;
    publishOtaStatus();
  }
}

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  digitalWrite(LED_BUILTIN, LOW);
  Serial.begin(115200);

  Serial.println("Erasing OTA secondary slot");
  if (!eraseSecondarySlot()) {
    Serial.println("OTA secondary slot erase failed");
    haltWithBlinkCode(4);
  }
  Serial.println("OTA secondary slot ready");

  Serial.println("Initializing Wire and IMU");
  // Re-establish the Nano 33 BLE Sense internal sensor power and I2C pull-up
  // controls after MCUboot, then give the BMI270 a clean power-on interval.
  pinMode(PIN_ENABLE_I2C_PULLUP, OUTPUT);
  pinMode(PIN_ENABLE_SENSORS_3V3, OUTPUT);
  digitalWrite(PIN_ENABLE_I2C_PULLUP, LOW);
  digitalWrite(PIN_ENABLE_SENSORS_3V3, LOW);
  delay(50);
  digitalWrite(PIN_ENABLE_SENSORS_3V3, HIGH);
  delay(20);
  digitalWrite(PIN_ENABLE_I2C_PULLUP, HIGH);
  delay(50);
  Wire.begin();
  IMU.debug(Serial);
  if (!IMU.begin()) {
    Serial.println("IMU init failed");
    haltWithBlinkCode(2);
  }
  Serial.println("IMU initialized");

  Serial.println("Initializing BLE");
  if (!BLE.begin()) {
    Serial.println("BLE init failed");
    haltWithBlinkCode(3);
  }

  BLE.setLocalName("MowerEMU");
  BLE.setAdvertisedService(mowerService);

  mowerService.addCharacteristic(telemetryChar);
  mowerService.addCharacteristic(controlChar);
  mowerService.addCharacteristic(versionChar);
  mowerService.addCharacteristic(otaControlChar);
  mowerService.addCharacteristic(otaDataChar);
  mowerService.addCharacteristic(otaStatusChar);
  BLE.addService(mowerService);

  versionChar.writeValue(kFirmwareVersion);
  publishOtaStatus();

  controlChar.setEventHandler(BLEWritten, [](BLEDevice central, BLECharacteristic characteristic) {
    if (controlChar.valueLength() > 0 && controlChar.value()[0] == 0x01) {
      g_zeroCommandReceived = true;
      Serial.println("Received zero command");
    }
  });
  otaControlChar.setEventHandler(BLEWritten, handleOtaControl);
  otaDataChar.setEventHandler(BLEWritten, handleOtaData);

  BLE.advertise();
  digitalWrite(LED_BUILTIN, HIGH);
  Serial.println("Advertising started");
}

void loop() {
  serviceSerialCommands();
  BLEDevice central = BLE.central();

  if (central) {
    if (!g_isConnected) {
      g_isConnected = true;
      Serial.println("Connected");
      BLE.stopAdvertise();
    }
  } else if (g_isConnected) {
    g_isConnected = false;
    const bool interruptedFullImage =
        g_otaTelemetryPaused && g_otaStagesFullImage;
    if (g_otaTelemetryPaused) {
      // The phone may disappear while flash is busy. Treat that as an aborted
      // transfer so a later connection immediately receives normal telemetry
      // and can start the image again from offset zero.
      resetOtaTransfer();
    }
    if (interruptedFullImage && !eraseSecondarySlot()) {
      Serial.println("OTA secondary slot recovery erase failed");
      haltWithBlinkCode(4);
    }
    Serial.println("Disconnected");
    BLE.advertise();
  }

  if (g_otaState == kOtaReceiving &&
      millis() - g_otaLastStatusMillis >= 1000) {
    // Credit/status notifications are idempotent. Repeat the latest offset so
    // a single lost BLE notification cannot stall a long transfer forever.
    publishOtaStatus();
  }

  unsigned long now = millis();
  if (now - lastMillis >= kUpdateIntervalMs) {
    float dt = (now - lastMillis) / 1000.0f;
    lastMillis = now;

    float ax = 0.0f;
    float ay = 0.0f;
    float az = 0.0f;
    float gx = 0.0f;
    float gy = 0.0f;
    float gz = 0.0f;
    float mx = 0.0f;
    float my = 0.0f;
    float mz = 0.0f;
    bool gotAccel = IMU.accelerationAvailable() > 0;
    bool gotGyro = IMU.gyroscopeAvailable() > 0;
    bool gotMag = IMU.magneticFieldAvailable() > 0;

    if (gotAccel) {
      IMU.readAcceleration(ax, ay, az);
    }
    if (gotGyro) {
      IMU.readGyroscope(gx, gy, gz);
    }
    if (gotMag) {
      IMU.readMagneticField(mx, my, mz);
    }

    if (gotAccel) {
      float accelRoll = atan2(ay, az) * 180.0f / PI;
      float accelPitch = atan2(-ax, sqrt(ay * ay + az * az)) * 180.0f / PI;

      if (!gotGyro) {
        g_filteredRoll = accelRoll;
        g_filteredPitch = accelPitch;
      } else {
        float gyroRoll = g_filteredRoll + gx * dt;
        float gyroPitch = g_filteredPitch + gy * dt;
        g_filteredRoll = kComplementaryAlpha * gyroRoll + (1.0f - kComplementaryAlpha) * accelRoll;
        g_filteredPitch = kComplementaryAlpha * gyroPitch + (1.0f - kComplementaryAlpha) * accelPitch;
      }
    } else if (gotGyro) {
      g_filteredRoll += gx * dt;
      g_filteredPitch += gy * dt;
    }

    int8_t roll = static_cast<int8_t>(constrain(roundf(g_filteredRoll - g_rollZeroOffset), -128.0f, 127.0f));
    int8_t pitch = static_cast<int8_t>(constrain(roundf(g_filteredPitch - g_pitchZeroOffset), -128.0f, 127.0f));
    uint8_t pressure = g_headingValid ? headingToByte(g_headingDeg) : 0;
    if (gotMag) {
      updateHeadingFromMag(mx, my, mz, g_filteredRoll, g_filteredPitch);
      pressure = headingToByte(g_headingDeg);
    }
    int8_t temp = gotGyro ? static_cast<int8_t>(constrain(roundf(gz), -128.0f, 127.0f)) : 0;
    uint8_t packet[4] = {static_cast<uint8_t>(roll), static_cast<uint8_t>(pitch), pressure, static_cast<uint8_t>(temp)};

    if (g_isConnected && !g_otaTelemetryPaused) {
      telemetryChar.setValue(packet, sizeof(packet));
      telemetryChar.broadcast();
    }

    if (g_zeroCommandReceived) {
      g_rollZeroOffset = g_filteredRoll;
      g_pitchZeroOffset = g_filteredPitch;
      Serial.println("Zero calibration command processed");
      g_zeroCommandReceived = false;
    }
  }

  delay(10);
}
