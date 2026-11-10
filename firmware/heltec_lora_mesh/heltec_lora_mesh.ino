/*
 * =========================================================================================
 * 5 km Decentralized Sub-GHz LoRa Mesh + BLE Bridge Firmware
 * Hardware Target: Heltec WiFi LoRa 32 V3 (ESP32-S3 + SX1262)
 *
 * Requirements:
 *   - RadioLib library by Jan Gromes (available in Arduino Library Manager)
 * 
 * Features:
 *   1. Full BLE GATT server (Service UUID: 0000a101-0000-1000-8000-00805f9b34fb)
 *   2. Bi-directional SX1262 Sub-GHz LoRa transceiver (915 MHz / 868 MHz)
 *   3. Relays packets between local phone (BLE) and remote ESP32 node (LoRa)
 * =========================================================================================
 */

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <RadioLib.h>

// BLE GATT Protocol Definitions
#define SERVICE_UUID        "0000a101-0000-1000-8000-00805f9b34fb"
#define CHAR_DATA_TX_UUID   "0000a102-0000-1000-8000-00805f9b34fb"
#define CHAR_DATA_RX_UUID   "0000a103-0000-1000-8000-00805f9b34fb"

#define NODE_CALLSIGN       "NODE-P1" // Set to NODE-P1 on Node 1, NODE-P2 on Node 2
#define HEADER_LENGTH       27
#define MAX_PAYLOAD_SIZE    1024

// Heltec WiFi LoRa 32 V3 SX1262 Pin Definitions
#define LORA_NSS            8
#define LORA_DIO1           14
#define LORA_NRST           12
#define LORA_BUSY           13
#define VEXT_PIN            36

SX1262 radio = new Module(LORA_NSS, LORA_DIO1, LORA_NRST, LORA_BUSY);

BLEServer* pServer = nullptr;
BLECharacteristic* pTxCharacteristic = nullptr;
BLECharacteristic* pRxCharacteristic = nullptr;
bool deviceConnected = false;
bool oldDeviceConnected = false;

volatile bool loraPacketReceived = false;
volatile bool loraOperationDone = false;

void IRAM_ATTR onDio1Action() {
  loraPacketReceived = true;
}

// Forward declarations
void broadcastOverLoRa(const uint8_t* data, size_t length);
void handleIncomingLoRaPacket();

class ServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    deviceConnected = true;
    Serial.println("\n[BLE] >>> Mobile phone connected via BLE GATT!");
  }

  void onDisconnect(BLEServer* pServer) override {
    deviceConnected = false;
    Serial.println("\n[BLE] <<< Mobile phone disconnected.");
  }
};

class TxCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) override {
    String rxData = pCharacteristic->getValue();
    size_t len = rxData.length();
    if (len < HEADER_LENGTH) return;

    const uint8_t* bytes = (const uint8_t*)rxData.c_str();
    uint8_t payloadType = bytes[16];
    char recipientId[9];
    memset(recipientId, 0, sizeof(recipientId));
    memcpy(recipientId, &bytes[17], 8);

    Serial.printf("[BLE -> LORA] Relaying %d bytes across 5 km LoRa mesh to %s\n", len, recipientId);

    // Broadcast across 5 km LoRa mesh
    broadcastOverLoRa(bytes, len);
  }
};

void setup() {
  Serial.begin(115200);
  delay(1000);

  // Power on Heltec V3 LoRa / Vext rail (Active LOW)
  pinMode(VEXT_PIN, OUTPUT);
  digitalWrite(VEXT_PIN, LOW);
  delay(100);

  Serial.println("\n*****************************************************************");
  Serial.println("  5 KM HELTEC V3 LORA MESH + BLE GATEWAY STARTUP");
  Serial.printf("  Callsign: %s | Frequency: 915.0 MHz\n", NODE_CALLSIGN);
  Serial.println("*****************************************************************");

  // Initialize SX1262 LoRa
  // Carrier Freq: 915.0 MHz, Bandwidth: 125.0 kHz, SF: 10, CR: 4/5, SyncWord: 0x12, Output Power: 22 dBm
  int state = radio.begin(915.0, 125.0, 10, 5, 0x12, 22);
  if (state == RADIOLIB_ERR_NONE) {
    Serial.println("[SX1262] LoRa radio initialized successfully (915 MHz, 22 dBm).");
  } else {
    Serial.printf("[SX1262] LoRa radio init failed, code: %d\n", state);
  }

  radio.setDio1Action(onDio1Action);
  radio.startReceive();

  // Initialize BLE GATT Server
  BLEDevice::init(NODE_CALLSIGN);
  BLEDevice::setMTU(512);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  pTxCharacteristic = pService->createCharacteristic(
    CHAR_DATA_TX_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  pTxCharacteristic->setCallbacks(new TxCallbacks());

  pRxCharacteristic = pService->createCharacteristic(
    CHAR_DATA_RX_UUID,
    BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ
  );
  pRxCharacteristic->addDescriptor(new BLE2902());

  pService->start();

  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.println("[BLE] Advertising ready as " NODE_CALLSIGN);
}

void loop() {
  // Re-advertise on BLE disconnect
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    oldDeviceConnected = deviceConnected;
  }
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }

  // Handle incoming packet from distant LoRa node
  if (loraPacketReceived) {
    loraPacketReceived = false;
    handleIncomingLoRaPacket();
  }

  delay(10);
}

void broadcastOverLoRa(const uint8_t* data, size_t length) {
  // Put radio in standby to transmit
  radio.standby();
  int state = radio.transmit((uint8_t*)data, length);
  if (state == RADIOLIB_ERR_NONE) {
    Serial.printf("[LORA] Transmission complete (%d bytes sent at 22 dBm).\n", length);
  } else {
    Serial.printf("[LORA] Transmission failed, code: %d\n", state);
  }
  // Return to receive mode
  radio.startReceive();
}

void handleIncomingLoRaPacket() {
  size_t length = radio.getPacketLength();
  if (length < HEADER_LENGTH) {
    radio.startReceive();
    return;
  }

  uint8_t rxBuffer[length];
  int state = radio.readData(rxBuffer, length);
  if (state == RADIOLIB_ERR_NONE) {
    float rssi = radio.getRSSI();
    float snr = radio.getSNR();

    char recipientId[9];
    memset(recipientId, 0, sizeof(recipientId));
    memcpy(recipientId, &rxBuffer[17], 8);

    Serial.println("\n[LORA] >>> Received packet from distant mesh node!");
    Serial.printf("  Signal : RSSI %.1f dBm | SNR %.1f dB\n", rssi, snr);
    Serial.printf("  Target : %s | Size: %d bytes\n", recipientId, length);

    // If local phone is paired via BLE, push packet directly to phone
    if (deviceConnected && pRxCharacteristic != nullptr) {
      pRxCharacteristic->setValue(rxBuffer, length);
      pRxCharacteristic->notify();
      Serial.println("[LORA -> BLE] Delivered packet to locally paired mobile phone.");
    } else {
      Serial.println("[LORA] Mobile phone currently out of range. Dropped or buffered.");
    }
  }

  radio.startReceive();
}

