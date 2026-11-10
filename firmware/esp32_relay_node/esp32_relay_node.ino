/*
 * =========================================================================================
 * 5 km Decentralized Off-Grid "Message Mail" Relay Firmware
 * Hardware Target: Heltec WiFi LoRa 32 V3 / ESP32-S3 / Standard ESP32 (WROOM/WROVER)
 * 
 * Protocols:
 *   1. Local BLE Bridge (Phone <-> ESP32 GATT Server)
 *   2. Store-and-Forward RAM Mailbox
 *   3. Sub-GHz LoRa Mesh Broadcast (SX1262 / SX1276)
 * =========================================================================================
 */

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// Service and Characteristic UUIDs matching Flutter BleGattConstants
#define SERVICE_UUID        "0000a101-0000-1000-8000-00805f9b34fb"
#define CHAR_DATA_TX_UUID   "0000a102-0000-1000-8000-00805f9b34fb" // Phone -> ESP32 Write Without Response
#define CHAR_DATA_RX_UUID   "0000a103-0000-1000-8000-00805f9b34fb" // ESP32 -> Phone Notify

#define NODE_NAME           "NODE-P1" // Node identifier in 5 km mesh
#define HEADER_LENGTH       27
#define MAX_PAYLOAD_SIZE    1024
#define MAX_QUEUE_ITEMS     20

BLEServer* pServer = nullptr;
BLECharacteristic* pTxCharacteristic = nullptr;
BLECharacteristic* pRxCharacteristic = nullptr;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// Store-and-Forward In-Memory Mailbox Item
struct MailboxMessage {
  uint8_t uuid[16];
  uint8_t payloadType;
  char recipient[9];
  uint16_t length;
  uint8_t payload[MAX_PAYLOAD_SIZE];
  bool isBuffered;
};

MailboxMessage mailbox[MAX_QUEUE_ITEMS];
int mailboxCount = 0;

// Forward declaration
void sendDeliveryAck(const uint8_t* messageUuid, const char* recipient);
void pushBufferedMailToPhone();

// BLE Server Callbacks
class ServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    deviceConnected = true;
    Serial.printf("\n[BLE] >>> Mobile phone paired! Total connected: %d\n", pServer->getConnectedCount());
    pServer->startAdvertising();
  }

  void onDisconnect(BLEServer* pServer) override {
    if (pServer->getConnectedCount() == 0) {
      deviceConnected = false;
      Serial.println("\n[BLE] <<< All mobile phones disconnected. Resuming BLE beacon advertising...");
    }
    pServer->startAdvertising();
  }
};

// BLE Characteristic TX Callbacks (Receives data from phone)
class TxCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) override {
    String rxData = pCharacteristic->getValue();
    size_t len = rxData.length();

    if (len < HEADER_LENGTH) {
      Serial.printf("[BLE] Error: Received runt frame (%d bytes, min %d)\n", len, HEADER_LENGTH);
      return;
    }

    const uint8_t* bytes = (const uint8_t*)rxData.c_str();

    // Extract UUID (16 bytes)
    char uuidStr[37];
    snprintf(uuidStr, sizeof(uuidStr), 
      "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    );

    // Extract Payload Type Flag
    uint8_t payloadType = bytes[16];

    // Extract Recipient ID (8 bytes)
    char recipientId[9];
    memset(recipientId, 0, sizeof(recipientId));
    memcpy(recipientId, &bytes[17], 8);

    // Extract Payload Length (Big Endian)
    uint16_t payloadLen = ((uint16_t)bytes[25] << 8) | (uint16_t)bytes[26];

    // Handle SYNC / POLL command (0x04)
    if (payloadType == 0x04) {
      Serial.println("[BLE] >>> Received SYNC POLL from phone. Pushing buffered mailbox...");
      pushBufferedMailToPhone();
      return;
    }

    Serial.println("\n=======================================================");
    Serial.println("[ESP32 RELAY NODE] Incoming Message Mail from Mobile App");
    Serial.printf("  Message ID  : %s\n", uuidStr);
    Serial.printf("  Payload Type: 0x%02X (%s)\n", payloadType, 
      payloadType == 0x01 ? "UTF-8 Text" : 
      payloadType == 0x02 ? "Codec2 Voice Mail" : 
      payloadType == 0x03 ? "Delivery ACK" : "SYNC POLL");
    Serial.printf("  Recipient   : %s\n", recipientId);
    Serial.printf("  Payload Size: %d bytes\n", payloadLen);

    if (payloadType == 0x01 && payloadLen > 0) {
      char textBuf[512];
      size_t copyLen = payloadLen < sizeof(textBuf) - 1 ? payloadLen : sizeof(textBuf) - 1;
      memcpy(textBuf, &bytes[27], copyLen);
      textBuf[copyLen] = '\0';
      Serial.printf("  Text Content: \"%s\"\n", textBuf);
    } else if (payloadType == 0x02) {
      Serial.printf("  Voice Blob  : %d bytes (Codec2 8 kHz frames ready for LoRa relay)\n", payloadLen);
    }
    Serial.println("=======================================================");

    // A. Real-time broadcast to connected phones
    if (pRxCharacteristic != nullptr) {
      pRxCharacteristic->setValue((uint8_t*)bytes, len);
      pRxCharacteristic->notify();
      Serial.println("[REAL-TIME] Broadcasted packet to connected phones over BLE");
    }

    // B. Buffer message in local ESP32 store-and-forward mailbox for offline users
    if (mailboxCount < MAX_QUEUE_ITEMS && payloadType != 0x03) {
      MailboxMessage& item = mailbox[mailboxCount];
      memcpy(item.uuid, bytes, 16);
      item.payloadType = payloadType;
      strncpy(item.recipient, recipientId, 8);
      item.recipient[8] = '\0';
      item.length = payloadLen < MAX_PAYLOAD_SIZE ? payloadLen : MAX_PAYLOAD_SIZE;
      memcpy(item.payload, &bytes[27], item.length);
      item.isBuffered = true;
      mailboxCount++;
      Serial.printf("[MAILBOX] Message queued in ESP32 RAM (Total buffered: %d)\n", mailboxCount);
    }
  }

    // 3. (Optional LoRa Transmission): Broadcast to 5 km LoRa mesh
    // LoRa.beginPacket();
    // LoRa.write(bytes, len);
    // LoRa.endPacket();
  }
};

void setup() {
  Serial.begin(115200);
  delay(1000);

  Serial.println("\n*************************************************************");
  Serial.println("  5 KM OFF-GRID 'MESSAGE MAIL' RELAY NODE STARTUP");
  Serial.printf("  Node ID     : %s\n", NODE_NAME);
  Serial.printf("  Service UUID: %s\n", SERVICE_UUID);
  Serial.println("*************************************************************");

  // Initialize BLE
  BLEDevice::init(NODE_NAME);

  // Set MTU to 512 bytes for high-efficiency voice mail packet throughput
  BLEDevice::setMTU(512);

  // Create BLE Server
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  // Create GATT Service
  BLEService* pService = pServer->createService(SERVICE_UUID);

  // Characteristic Data TX (Phone -> ESP32 Write Without Response)
  pTxCharacteristic = pService->createCharacteristic(
    CHAR_DATA_TX_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  pTxCharacteristic->setCallbacks(new TxCallbacks());

  // Characteristic Data RX (ESP32 -> Phone Notify)
  pRxCharacteristic = pService->createCharacteristic(
    CHAR_DATA_RX_UUID,
    BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ
  );
  pRxCharacteristic->addDescriptor(new BLE2902());

  // Start Service
  pService->start();

  // Start Advertising
  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("[BLE] GATT Server active. Advertising as " NODE_NAME "...");
}

void loop() {
  // Handle disconnection & reconnection advertising
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    oldDeviceConnected = deviceConnected;
  }
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
    // When a phone connects, push any buffered mailbox items
    delay(1000);
    pushBufferedMailToPhone();
  }

  delay(20);
}

// Sends an end-to-end Delivery ACK packet back to the phone
void sendDeliveryAck(const uint8_t* messageUuid, const char* recipient) {
  if (!deviceConnected || pRxCharacteristic == nullptr) return;

  uint8_t ackFrame[HEADER_LENGTH + 1];
  // [0..15]: UUID
  memcpy(ackFrame, messageUuid, 16);
  // [16]: Payload Type = 0x03 (Delivery ACK)
  ackFrame[16] = 0x03;
  // [17..24]: Recipient ID
  memset(&ackFrame[17], 0, 8);
  memcpy(&ackFrame[17], recipient, strlen(recipient) < 8 ? strlen(recipient) : 8);
  // [25..26]: Length = 1 byte
  ackFrame[25] = 0x00;
  ackFrame[26] = 0x01;
  // [27]: Status 0x01 = DELIVERED
  ackFrame[27] = 0x01;

  pRxCharacteristic->setValue(ackFrame, sizeof(ackFrame));
  pRxCharacteristic->notify();
  Serial.println("[BLE] Sent Delivery ACK (0x01 DELIVERED) back to mobile phone.");
}

// Pushes buffered messages from the ESP32 mailbox to the connected mobile phone
void pushBufferedMailToPhone() {
  if (mailboxCount == 0 || !deviceConnected || pRxCharacteristic == nullptr) return;

  Serial.printf("[MAILBOX] Delivering %d buffered message(s) to connected mobile phone...\n", mailboxCount);

  for (int i = 0; i < mailboxCount; i++) {
    MailboxMessage& item = mailbox[i];
    if (!item.isBuffered) continue;

    uint16_t frameSize = HEADER_LENGTH + item.length;
    uint8_t frame[frameSize];

    // [0..15]: UUID
    memcpy(frame, item.uuid, 16);
    // [16]: Payload Type
    frame[16] = item.payloadType;
    // [17..24]: Recipient / Source
    memset(&frame[17], 0, 8);
    memcpy(&frame[17], item.recipient, strlen(item.recipient) < 8 ? strlen(item.recipient) : 8);
    // [25..26]: Length
    frame[25] = (item.length >> 8) & 0xFF;
    frame[26] = item.length & 0xFF;
    // [27..N]: Payload
    memcpy(&frame[27], item.payload, item.length);

    pRxCharacteristic->setValue(frame, frameSize);
    pRxCharacteristic->notify();

    Serial.printf("  -> Delivered buffered message %d/%d (%d bytes) to mobile phone\n", i + 1, mailboxCount, frameSize);
    item.isBuffered = false;
    delay(100);
  }

  // Clear delivered items
  mailboxCount = 0;
  Serial.println("[MAILBOX] All buffered messages delivered!");
}

