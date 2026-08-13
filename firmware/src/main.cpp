#include <Arduino.h>
#include <NimBLEDevice.h>

#define MOWER_SERVICE_UUID        "12345678-1234-5678-1234-56789abcdef0"
#define TELEMETRY_CHAR_UUID       "12345678-1234-5678-1234-56789abcdef1"
#define CONTROL_CHAR_UUID         "12345678-1234-5678-1234-56789abcdef2"

static NimBLECharacteristic* pTelemetryChar = nullptr;
static NimBLECharacteristic* pControlChar = nullptr;
unsigned long lastMillis = 0;

class ControlCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* pChar) override {
    std::string val = pChar->getValue();
    (void)val; // handle calibration here
  }
};

void setup() {
  NimBLEDevice::init("MowerXiao");
  NimBLEServer* pServer = NimBLEDevice::createServer();
  NimBLEService* pService = pServer->createService(MOWER_SERVICE_UUID);
  pTelemetryChar = pService->createCharacteristic(TELEMETRY_CHAR_UUID, NIMBLE_PROPERTY::NOTIFY);
  pControlChar = pService->createCharacteristic(CONTROL_CHAR_UUID, NIMBLE_PROPERTY::WRITE);
  pControlChar->setCallbacks(new ControlCallbacks());
  pService->start();
  NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
  pAdv->addServiceUUID(MOWER_SERVICE_UUID);
  pAdv->start();
}

void loop() {
  unsigned long now = millis();
  if (now - lastMillis > 500) {
    lastMillis = now;
    int8_t roll = random(-20, 20);
    int8_t pitch = random(-20, 20);
    uint8_t pressure = random(0, 100);
    uint8_t buf[3] = {(uint8_t)roll, (uint8_t)pitch, pressure};
    if (pTelemetryChar) {
      pTelemetryChar->setValue(buf, 3);
      pTelemetryChar->notify();
    }
  }
  delay(10);
}
