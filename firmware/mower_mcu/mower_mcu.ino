#include <Arduino.h>
#include <Wire.h>
#include <Arduino_BMI270_BMM150.h>

#include <ArduinoBLE.h>

// Service and characteristic UUIDs
#define MOWER_SERVICE_UUID        "12345678-1234-5678-1234-56789abcdef0"
#define TELEMETRY_CHAR_UUID       "12345678-1234-5678-1234-56789abcdef1"
#define CONTROL_CHAR_UUID         "12345678-1234-5678-1234-56789abcdef2"
#define VERSION_CHAR_UUID         "12345678-1234-5678-1234-56789abcdef3"

const char kFirmwareVersion[] = "0.1.0";

bool g_isConnected = false;
bool g_zeroCommandReceived = false;
unsigned long lastMillis = 0;
float g_filteredRoll = 0.0f;
float g_filteredPitch = 0.0f;
float g_rollZeroOffset = 0.0f;
float g_pitchZeroOffset = 0.0f;
float g_headingDeg = 0.0f;
bool g_headingValid = false;
const unsigned long kUpdateIntervalMs = 20;
const float kComplementaryAlpha = 0.95f;
const float kHeadingAlpha = 0.2f;

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

BLEService mowerService(MOWER_SERVICE_UUID);
BLECharacteristic telemetryChar(TELEMETRY_CHAR_UUID, BLERead | BLENotify, 4);
BLECharacteristic controlChar(CONTROL_CHAR_UUID, BLEWrite, 1);
BLEStringCharacteristic versionChar(VERSION_CHAR_UUID, BLERead, 16);

void setup() {
  Serial.begin(115200);

  Wire.begin();
  IMU.debug(Serial);
  if (!IMU.begin()) {
    Serial.println("IMU init failed");
    while (1);
  }
  Serial.println("IMU initialized");

  if (!BLE.begin()) {
    Serial.println("BLE init failed");
    while (1);
  }

  BLE.setLocalName("MowerXiao");
  BLE.setAdvertisedService(mowerService);

  mowerService.addCharacteristic(telemetryChar);
  mowerService.addCharacteristic(controlChar);
  mowerService.addCharacteristic(versionChar);
  BLE.addService(mowerService);

  versionChar.writeValue(kFirmwareVersion);

  controlChar.setEventHandler(BLEWritten, [](BLEDevice central, BLECharacteristic characteristic) {
    if (controlChar.valueLength() > 0 && controlChar.value()[0] == 0x01) {
      g_zeroCommandReceived = true;
      Serial.println("Received zero command");
    }
  });

  BLE.advertise();
  Serial.println("Advertising started");
}

void loop() {
  BLEDevice central = BLE.central();

  if (central) {
    if (!g_isConnected) {
      g_isConnected = true;
      Serial.println("Connected");
      BLE.stopAdvertise();
    }
  } else if (g_isConnected) {
    g_isConnected = false;
    Serial.println("Disconnected");
    BLE.advertise();
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

    if (g_isConnected) {
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
