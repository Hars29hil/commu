/*
 * =========================================================================================
 * 5 km Decentralized Off-Grid "Message Mail" - ESP32 DEVKIT V1 Edition
 *
 * Board: DOIT ESP32 DEVKIT V1 (ESP-WROOM-32)
 * Framework: Arduino IDE / PlatformIO
 * 
 * Hardware Details:
 *   - ESP32 Dual-Core @ 240MHz, 520KB SRAM
 *   - Built-in Bluetooth Low Energy (BLE 4.2)
 *   - Onboard Status LED: GPIO 2 (Blue LED)
 *       * Blinking: Waiting for Mobile Connection (Advertising)
 *       * Solid ON: Connected to Mobile Phone
 *       * Rapid Strobe: Transmitting / Receiving Message Mail
 *
 * Communication Architecture:
 *   - 100% Off-Grid, Zero-Backend, No Wi-Fi router, No SIM card
 *   - BLE Service UUID: 0000a101-0000-1000-8000-00805f9b34fb
 *   - TX Char (Phone -> ESP32 Write Without Response): 0000a102-0000-1000-8000-00805f9b34fb
 *   - RX Char (ESP32 -> Phone Notify): 0000a103-0000-1000-8000-00805f9b34fb
 * =========================================================================================
 */

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// Onboard Blue LED on ESP32 DevKit V1
#define STATUS_LED          2

// GATT Service & Characteristic UUIDs matching the Flutter App
#define SERVICE_UUID        "0000a101-0000-1000-8000-00805f9b34fb"
#define CHAR_DATA_TX_UUID   "0000a102-0000-1000-8000-00805f9b34fb"
#define CHAR_DATA_RX_UUID   "0000a103-0000-1000-8000-00805f9b34fb"

#define NODE_NAME           "NODE-P1" // Device name discovered by phone
#define HEADER_LENGTH       27
#define MAX_PAYLOAD_SIZE    1024
#define MAX_QUEUE_ITEMS     30

BLEServer* pServer = nullptr;
BLECharacteristic* pTxCharacteristic = nullptr;
BLECharacteristic* pRxCharacteristic = nullptr;

bool deviceConnected = false;
bool oldDeviceConnected = false;
unsigned long lastLedBlink = 0;
bool ledState = false;

// Store-and-Forward In-Memory Mailbox Structure
struct MailboxMessage {
  uint8_t uuid[16];
  uint8_t payloadType; // 0x01 = Text, 0x02 = Voice Note, 0x03 = Delivery ACK
  char recipient[9];
  uint16_t length;
  uint8_t payload[MAX_PAYLOAD_SIZE];
  bool isBuffered;
};

MailboxMessage mailbox[MAX_QUEUE_ITEMS];
int mailboxCount = 0;

// Function Prototypes
void sendDeliveryAck(const uint8_t* messageUuid, const char* recipient);
void pushBufferedMailToPhone();
void strobeLed(int times, int delayMs);

// BLE Server Connection Callbacks
class DevKitServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    deviceConnected = true;
    digitalWrite(STATUS_LED, HIGH); // Solid ON when mobile phone is connected
    Serial.printf("\n[BLE] >>> Mobile phone paired! Total clients connected: %d\n", pServer->getConnectedCount());
    // Keep advertising beacon active so another phone can connect for real-time mesh chat!
    pServer->startAdvertising();
  }

  void onDisconnect(BLEServer* pServer) override {
    uint32_t count = pServer->getConnectedCount();
    if (count == 0) {
      deviceConnected = false;
      digitalWrite(STATUS_LED, LOW);
      Serial.println("\n[BLE] <<< All mobile phones disconnected. Resuming advertising beacon...");
    } else {
      Serial.printf("\n[BLE] <<< A phone disconnected. %d phone(s) still connected.\n", count);
    }
    pServer->startAdvertising();
  }
};

// BLE Characteristic TX Callbacks (Receives message mail packets from phone)
class DevKitTxCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) override {
    String rxData = pCharacteristic->getValue();
    size_len_check:
    size_t len = rxData.length();

    if (len < HEADER_LENGTH) {
      Serial.printf("[BLE] Warning: Frame too short (%d bytes, min %d)\n", len, HEADER_LENGTH);
      return;
    }

    strobeLed(3, 40); // Flash LED to indicate packet reception
    const uint8_t* bytes = (const uint8_t*)rxData.c_str();

    // 1. Parse 16-byte Message UUID
    char uuidStr[37];
    snprintf(uuidStr, sizeof(uuidStr), 
      "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
      bytes[0], bytes[1], bytes[2], bytes[3],
      bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11],
      bytes[12], bytes[13], bytes[14], bytes[15]
    );

    // 2. Parse Payload Type Flag
    uint8_t payloadType = bytes[16];

    // 3. Parse Recipient ID (8 bytes)
    char recipientId[9];
    memset(recipientId, 0, sizeof(recipientId));
    memcpy(recipientId, &bytes[17], 8);

    // 4. Parse Payload Length (Big Endian uint16)
    uint16_t payloadLen = ((uint16_t)bytes[25] << 8) | (uint16_t)bytes[26];

    // Handle SYNC POLL command (0x04)
    if (payloadType == 0x04) {
      Serial.println("[BLE] >>> Received SYNC POLL from phone. Pushing buffered mailbox...");
      pushBufferedMailToPhone();
      return;
    }

    Serial.println("\n+-------------------------------------------------------------+");
    Serial.println("|  [ESP32 DEVKIT V1] INCOMING MESSAGE MAIL FROM PHONE         |");
    Serial.println("+-------------------------------------------------------------+");
    Serial.printf("  Message UUID : %s\n", uuidStr);
    Serial.printf("  Payload Type : 0x%02X [%s]\n", payloadType, 
      payloadType == 0x01 ? "UTF-8 TEXT" : 
      payloadType == 0x02 ? "COMPRESSED VOICE MAIL (Codec2)" : 
      payloadType == 0x03 ? "DELIVERY ACK" : "SYNC POLL");
    Serial.printf("  Recipient ID : %s\n", recipientId);
    Serial.printf("  Payload Size : %d bytes (Total frame: %d bytes)\n", payloadLen, len);

    if (payloadType == 0x01 && payloadLen > 0) {
      char textBuf[512];
      size_t copyLen = payloadLen < sizeof(textBuf) - 1 ? payloadLen : sizeof(textBuf) - 1;
      memcpy(textBuf, &bytes[27], copyLen);
      textBuf[copyLen] = '\0';
      Serial.printf("  Text Content : \"%s\"\n", textBuf);
    } else if (payloadType == 0x02) {
      Serial.printf("  Audio Blob   : %d bytes of 8 kHz Codec2 voice frame stream\n", payloadLen);
    }

    // A. REAL-TIME RELAY: Immediately notify any connected phone(s) in real time
    if (pRxCharacteristic != nullptr) {
      pRxCharacteristic->setValue((uint8_t*)bytes, len);
      pRxCharacteristic->notify();
      Serial.println("  Forwarding   : NOTIFIED IN REAL-TIME TO CONNECTED PHONES");
    }

    // B. STORE-AND-FORWARD: Buffer in local ESP32 RAM mailbox for offline users
    if (payloadType != 0x03 && mailboxCount < MAX_QUEUE_ITEMS) {
      MailboxMessage& item = mailbox[mailboxCount];
      memcpy(item.uuid, bytes, 16);
      item.payloadType = payloadType;
      strncpy(item.recipient, recipientId, 8);
      item.recipient[8] = '\0';
      item.length = payloadLen < MAX_PAYLOAD_SIZE ? payloadLen : MAX_PAYLOAD_SIZE;
      memcpy(item.payload, &bytes[27], item.length);
      item.isBuffered = true;
      mailboxCount++;
      Serial.printf("  Queue Status : BUFFERED IN ESP32 RAM (Total in queue: %d)\n", mailboxCount);
    }
    Serial.println("+-------------------------------------------------------------+");
  }
};

void setup() {
  Serial.begin(115200);
  delay(500);

  // Initialize Onboard Blue LED on GPIO 2
  pinMode(STATUS_LED, OUTPUT);
  digitalWrite(STATUS_LED, LOW);

  Serial.println("\n=============================================================");
  Serial.println("  ESP32 DEVKIT V1 - OFF-GRID 'MESSAGE MAIL' RELAY NODE");
  Serial.println("=============================================================");
  Serial.printf("  Chip Model   : %s (Rev %d)\n", ESP.getChipModel(), ESP.getChipRevision());
  Serial.printf("  CPU Clock    : %d MHz\n", ESP.getCpuFreqMHz());
  Serial.printf("  Free Heap    : %d bytes\n", ESP.getFreeHeap());
  Serial.printf("  BLE Device   : %s\n", NODE_NAME);
  Serial.printf("  Service UUID : %s\n", SERVICE_UUID);
  Serial.println("=============================================================");

  // Initialize ESP32 BLE
  BLEDevice::init(NODE_NAME);

  // Set MTU to 512 bytes for fast binary voice mail transfers
  BLEDevice::setMTU(512);

  // Create BLE Server
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new DevKitServerCallbacks());

  // Create GATT Service
  BLEService* pService = pServer->createService(SERVICE_UUID);

  // Characteristic Data TX (Phone -> ESP32 Write Without Response)
  pTxCharacteristic = pService->createCharacteristic(
    CHAR_DATA_TX_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  pTxCharacteristic->setCallbacks(new DevKitTxCallbacks());

  // Characteristic Data RX (ESP32 -> Phone Notify)
  pRxCharacteristic = pService->createCharacteristic(
    CHAR_DATA_RX_UUID,
    BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ
  );
  pRxCharacteristic->addDescriptor(new BLE2902());

  // Start the Service
  pService->start();

  // Configure Advertising
  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06); // functions that help with iPhone connections issue
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("[BLE] GATT Server active!");
  Serial.println("[BLE] Open 'Message Mail' on your mobile and tap the connection pill to pair.\n");
}

void loop() {
  // Handle disconnection & reconnection advertising
  if (!deviceConnected && oldDeviceConnected) {
    delay(500);
    pServer->startAdvertising();
    oldDeviceConnected = deviceConnected;
    Serial.println("[BLE] Restarted advertising...");
  }
  
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
    // When a phone connects, wait 800ms and deliver any buffered mail
    delay(800);
    pushBufferedMailToPhone();
  }

  // LED Behavior:
  // - If connected: solid ON
  // - If disconnected: blinking slowly (every 600ms)
  if (!deviceConnected) {
    unsigned long currentMillis = millis();
    if (currentMillis - lastLedBlink >= 600) {
      lastLedBlink = currentMillis;
      ledState = !ledState;
      digitalWrite(STATUS_LED, ledState ? HIGH : LOW);
    }
  } else {
    digitalWrite(STATUS_LED, HIGH);
  }

  delay(20);
}

// Sends an end-to-end Delivery ACK packet back to the sender phone
void sendDeliveryAck(const uint8_t* messageUuid, const char* recipient) {
  if (!deviceConnected || pRxCharacteristic == nullptr) return;

  uint8_t ackFrame[HEADER_LENGTH + 1];
  // [0..15]: Message UUID
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
  Serial.println("[BLE] >>> Sent Delivery ACK (0x01 DELIVERED) back to mobile phone.");
}

// Pushes all buffered messages from the ESP32 RAM mailbox to the connected mobile phone
void pushBufferedMailToPhone() {
  if (mailboxCount == 0 || !deviceConnected || pRxCharacteristic == nullptr) return;

  Serial.printf("[MAILBOX] Delivering %d buffered message(s) to connected mobile phone...\n", mailboxCount);

  for (int i = 0; i < mailboxCount; i++) {
    MailboxMessage& item = mailbox[i];
    if (!item.isBuffered) continue;

    strobeLed(2, 50);
    uint16_t frameSize = HEADER_LENGTH + item.length;
    uint8_t frame[frameSize];

    // [0..15]: UUID
    memcpy(frame, item.uuid, 16);
    // [16]: Payload Type (0x01 text, 0x02 voice)
    frame[16] = item.payloadType;
    // [17..24]: Recipient / Source
    memset(&frame[17], 0, 8);
    memcpy(&frame[17], item.recipient, strlen(item.recipient) < 8 ? strlen(item.recipient) : 8);
    // [25..26]: Length (Big Endian)
    frame[25] = (item.length >> 8) & 0xFF;
    frame[26] = item.length & 0xFF;
    // [27..N]: Payload
    memcpy(&frame[27], item.payload, item.length);

    pRxCharacteristic->setValue(frame, frameSize);
    pRxCharacteristic->notify();

    Serial.printf("  -> Delivered buffered message %d/%d (%d bytes) to mobile phone\n", 
      i + 1, mailboxCount, frameSize);
    item.isBuffered = false;
    delay(120); // Small interval between packet deliveries
  }

  // Clear delivered mailbox
  mailboxCount = 0;
  Serial.println("[MAILBOX] All buffered messages successfully delivered to mobile!\n");
}

// Flashes the onboard blue LED
void strobeLed(int times, int delayMs) {
  for (int i = 0; i < times; i++) {
    digitalWrite(STATUS_LED, HIGH);
    delay(delayMs);
    digitalWrite(STATUS_LED, LOW);
    delay(delayMs);
  }
  if (deviceConnected) {
    digitalWrite(STATUS_LED, HIGH);
  }
}

