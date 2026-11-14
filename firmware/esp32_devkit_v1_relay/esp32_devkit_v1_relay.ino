/*
 * =========================================================================================
 * Off-Grid Decentralized "Message Mail" Relay Firmware (Protocol v2)
 * Hardware Target: DOIT ESP32 DEVKIT V1 (ESP-WROOM-32)
 * Framework: Arduino IDE (ESP32 Arduino Core 3.0+) / PlatformIO
 *
 * Features:
 *   1. Zero-Touch Multi-Client BLE GATT Server (up to 8 concurrent phones)
 *   2. Persistent Unique Username Registry (LittleFS /peers.dat) + Collision Detection
 *   3. Private 1-to-1 Unicast Routing (targets exact conn_id, no broadcast leaks)
 *   4. Group Chat Fan-out & Persistent Group Directory (/groups.dat)
 *   5. Persistent Store-and-Forward LittleFS Mailbox (/mb/) supporting chunked Voice Notes
 *   6. Zero-Latency RAM Pass-Through for Live Voice Calling + Instant Offline Detection
 *
 * Onboard Status LED (GPIO 2):
 *   - Slow Blink (600ms) : Advertising, waiting for clients
 *   - Solid ON           : At least 1 phone connected
 *   - Rapid Strobe       : Active packet relay
 * =========================================================================================
 */

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <LittleFS.h>
#include <esp_gatts_api.h>

#define STATUS_LED          2
#define SERVICE_UUID        "0000a101-0000-1000-8000-00805f9b34fb"
#define CHAR_DATA_TX_UUID   "0000a102-0000-1000-8000-00805f9b34fb"
#define CHAR_DATA_RX_UUID   "0000a103-0000-1000-8000-00805f9b34fb"

#define NODE_NAME           "OFFGRID-RELAY"
#define PROTO_VER_V2        0x02
#define MIN_HEADER_V2       23
#define MAX_ID_LEN          24
#define MAX_PACKET_SIZE     512

// Packet Types
#define PKT_TEXT_MSG        0x01
#define PKT_VOICE_CHUNK     0x02
#define PKT_DELIVERY_ACK    0x03
#define PKT_SYNC_POLL       0x04
#define PKT_PRESENCE_HELLO  0x05
#define PKT_PEER_DIRECTORY  0x06
#define PKT_GROUP_META      0x07
#define PKT_CALL_SIGNAL     0x08
#define PKT_CALL_AUDIO      0x09

// Flags bitmask
#define FLAG_GROUP          0x01
#define FLAG_CHUNKED        0x02
#define FLAG_COMPRESSED     0x04
#define FLAG_STATUS_FAIL    0x08

// Call Signals
#define CALL_SIG_INVITE       0x01
#define CALL_SIG_RINGING      0x02
#define CALL_SIG_ACCEPT       0x03
#define CALL_SIG_REJECT       0x04
#define CALL_SIG_BUSY         0x05
#define CALL_SIG_UNAVAILABLE  0x06
#define CALL_SIG_HANGUP       0x07
#define CALL_SIG_VOICEMAIL    0x08

// Capacity limits
#define MAX_CLIENTS         8
#define MAX_PEERS           40
#define MAX_GROUPS          20
#define MAX_GROUP_MEMBERS   16
#define MAX_MAILBOX_FILES   160
#define RX_RING_SIZE        32

BLEServer* pServer = nullptr;
BLECharacteristic* pTxCharacteristic = nullptr;
BLECharacteristic* pRxCharacteristic = nullptr;
esp_gatt_if_t g_gatts_if = ESP_GATT_IF_NONE;

void onCustomGattsEvent(
  esp_gatts_cb_event_t event,
  esp_gatt_if_t gatts_if,
  esp_ble_gatts_cb_param_t* param
);

unsigned long lastLedBlink = 0;
bool ledState = false;
bool fsReady = false;
uint32_t nextMailSeq = 1;
bool pendingDirectoryBroadcast = false;

// Active BLE Session Table
struct ClientSession {
  bool active;
  uint16_t connId;
  char username[MAX_ID_LEN + 1];
  bool registered;
};
ClientSession sessions[MAX_CLIENTS];

// Persistent Unique Peer Registry (/peers.dat)
struct PeerRecord {
  bool active;
  uint8_t deviceUuid[16];
  char username[MAX_ID_LEN + 1];
  char displayName[33];
};
PeerRecord peers[MAX_PEERS];

// Persistent Group Membership Table (/groups.dat)
struct GroupRecord {
  bool active;
  char groupId[MAX_ID_LEN + 1];
  uint8_t memberCount;
  char members[MAX_GROUP_MEMBERS][MAX_ID_LEN + 1];
};
GroupRecord groups[MAX_GROUPS];

// Thread-safe RX Ring Buffer (decouples BLE stack callback from LittleFS I/O)
struct RxFrame {
  uint16_t connId;
  uint16_t len;
  uint8_t data[MAX_PACKET_SIZE];
};
RxFrame rxRing[RX_RING_SIZE];
volatile int rxHead = 0;
volatile int rxTail = 0;
portMUX_TYPE rxMux = portMUX_INITIALIZER_UNLOCKED;

// ============================================================================
// Helper Utilities
// ============================================================================

void strobeLed(int times, int delayMs) {
  int connectedCount = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (sessions[i].active) connectedCount++;
  }
  for (int i = 0; i < times; i++) {
    digitalWrite(STATUS_LED, HIGH);
    delay(delayMs);
    digitalWrite(STATUS_LED, LOW);
    delay(delayMs);
  }
  digitalWrite(STATUS_LED, connectedCount > 0 ? HIGH : LOW);
}

int getActiveSessionCount() {
  int cnt = 0;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (sessions[i].active) cnt++;
  }
  return cnt;
}

int findSessionByConnId(uint16_t connId) {
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (sessions[i].active && sessions[i].connId == connId) return i;
  }
  return -1;
}

int findSessionByUsername(const char* username) {
  if (!username || username[0] == '\0') return -1;
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (sessions[i].active && sessions[i].registered &&
        strcmp(sessions[i].username, username) == 0) {
      return i;
    }
  }
  return -1;
}

int findPeerByUsername(const char* username) {
  for (int i = 0; i < MAX_PEERS; i++) {
    if (peers[i].active && strcmp(peers[i].username, username) == 0) {
      return i;
    }
  }
  return -1;
}

int findGroupById(const char* groupId) {
  for (int i = 0; i < MAX_GROUPS; i++) {
    if (groups[i].active && strcmp(groups[i].groupId, groupId) == 0) {
      return i;
    }
  }
  return -1;
}

// Captures the active GATTS interface handle without accessing private BLEServer members
void onCustomGattsEvent(
  esp_gatts_cb_event_t event,
  esp_gatt_if_t gatts_if,
  esp_ble_gatts_cb_param_t* param
) {
  if (event == ESP_GATTS_REG_EVT && param && param->reg.status == ESP_GATT_OK) {
    g_gatts_if = gatts_if;
  } else if (g_gatts_if == ESP_GATT_IF_NONE && gatts_if != ESP_GATT_IF_NONE) {
    g_gatts_if = gatts_if;
  }
}

// Send raw BLE notification directly to ONE specific client conn_id
bool sendToConnId(uint16_t connId, const uint8_t* data, size_t len) {
  if (pServer == nullptr || pRxCharacteristic == nullptr ||
      g_gatts_if == ESP_GATT_IF_NONE || len == 0 || len > MAX_PACKET_SIZE) {
    return false;
  }
  esp_err_t err = esp_ble_gatts_send_indicate(
    g_gatts_if,
    connId,
    pRxCharacteristic->getHandle(),
    len,
    (uint8_t*)data,
    false // false = Notification (fast, non-blocking)
  );
  return err == ESP_OK;
}

// Build a Protocol v2 binary frame
size_t buildV2Packet(
  uint8_t* outBuf,
  uint8_t pktType,
  const uint8_t* msgUuid,
  const char* senderId,
  const char* targetId,
  uint8_t flags,
  const uint8_t* payload,
  uint16_t payloadLen
) {
  uint8_t sLen = senderId ? (uint8_t)min((size_t)MAX_ID_LEN, strlen(senderId)) : 0;
  uint8_t tLen = targetId ? (uint8_t)min((size_t)MAX_ID_LEN, strlen(targetId)) : 0;
  size_t total = MIN_HEADER_V2 + sLen + tLen + payloadLen;
  if (total > MAX_PACKET_SIZE) return 0;

  outBuf[0] = PROTO_VER_V2;
  outBuf[1] = pktType;
  if (msgUuid) {
    memcpy(&outBuf[2], msgUuid, 16);
  } else {
    memset(&outBuf[2], 0, 16);
  }
  outBuf[18] = sLen;
  outBuf[19] = tLen;
  outBuf[20] = flags;
  outBuf[21] = (payloadLen >> 8) & 0xFF;
  outBuf[22] = payloadLen & 0xFF;

  size_t offset = MIN_HEADER_V2;
  if (sLen > 0) {
    memcpy(&outBuf[offset], senderId, sLen);
    offset += sLen;
  }
  if (tLen > 0) {
    memcpy(&outBuf[offset], targetId, tLen);
    offset += tLen;
  }
  if (payloadLen > 0 && payload != nullptr) {
    memcpy(&outBuf[offset], payload, payloadLen);
    offset += payloadLen;
  }
  return offset;
}

// ============================================================================
// Persistent LittleFS Storage (/peers.dat, /groups.dat, /mb/*)
// ============================================================================

void savePeersToFS() {
  if (!fsReady) return;
  File f = LittleFS.open("/peers.dat", "w");
  if (!f) return;
  f.write((const uint8_t*)peers, sizeof(peers));
  f.close();
}

void loadPeersFromFS() {
  memset(peers, 0, sizeof(peers));
  if (!fsReady || !LittleFS.exists("/peers.dat")) return;
  File f = LittleFS.open("/peers.dat", "r");
  if (!f) return;
  if (f.size() == sizeof(peers)) {
    f.read((uint8_t*)peers, sizeof(peers));
  }
  f.close();
}

void saveGroupsToFS() {
  if (!fsReady) return;
  File f = LittleFS.open("/groups.dat", "w");
  if (!f) return;
  f.write((const uint8_t*)groups, sizeof(groups));
  f.close();
}

void loadGroupsFromFS() {
  memset(groups, 0, sizeof(groups));
  if (!fsReady || !LittleFS.exists("/groups.dat")) return;
  File f = LittleFS.open("/groups.dat", "r");
  if (!f) return;
  if (f.size() == sizeof(groups)) {
    f.read((uint8_t*)groups, sizeof(groups));
  }
  f.close();
}

void initMailboxDir() {
  if (!fsReady) return;
  if (!LittleFS.exists("/mb")) {
    LittleFS.mkdir("/mb");
  }
  // Find max sequence ID
  File root = LittleFS.open("/mb");
  if (root && root.isDirectory()) {
    File file = root.openNextFile();
    while (file) {
      String name = String(file.name());
      int slash = name.lastIndexOf('/');
      String base = slash >= 0 ? name.substring(slash + 1) : name;
      uint32_t seq = (uint32_t)base.toInt();
      if (seq >= nextMailSeq) nextMailSeq = seq + 1;
      file = root.openNextFile();
    }
    root.close();
  }
}

void pruneOldestMailboxIfNeeded() {
  if (!fsReady) return;
  int count = 0;
  String oldestPath = "";
  uint32_t oldestSeq = 0xFFFFFFFF;

  File root = LittleFS.open("/mb");
  if (!root || !root.isDirectory()) return;
  File file = root.openNextFile();
  while (file) {
    count++;
    String name = String(file.name());
    int slash = name.lastIndexOf('/');
    String base = slash >= 0 ? name.substring(slash + 1) : name;
    uint32_t seq = (uint32_t)base.toInt();
    if (seq < oldestSeq) {
      oldestSeq = seq;
      oldestPath = name.startsWith("/mb") ? name : ("/mb/" + base);
    }
    file = root.openNextFile();
  }
  root.close();

  if (count >= MAX_MAILBOX_FILES && oldestPath.length() > 0) {
    LittleFS.remove(oldestPath);
    Serial.printf("[MAILBOX] Pruned oldest item %s (queue limit %d)\n", oldestPath.c_str(), MAX_MAILBOX_FILES);
  }
}

// Stored mailbox file format:
// [0] recipientCount (1 byte)
// [1..] recipientCount * 25-byte null-terminated strings
// [..] uint16_t rawFrameLen
// [..] rawFrameBytes
void storeOfflinePacket(const char recipients[][MAX_ID_LEN + 1], int recipientCount, const uint8_t* frame, uint16_t frameLen) {
  if (!fsReady || recipientCount <= 0 || frameLen == 0) return;
  pruneOldestMailboxIfNeeded();

  char path[32];
  snprintf(path, sizeof(path), "/mb/%08lu.pkt", (unsigned long)nextMailSeq++);
  File f = LittleFS.open(path, "w");
  if (!f) return;

  uint8_t count = (uint8_t)min(recipientCount, MAX_GROUP_MEMBERS);
  f.write(&count, 1);
  for (int i = 0; i < count; i++) {
    uint8_t recBuf[MAX_ID_LEN + 1];
    memset(recBuf, 0, sizeof(recBuf));
    strncpy((char*)recBuf, recipients[i], MAX_ID_LEN);
    f.write(recBuf, MAX_ID_LEN + 1);
  }
  uint8_t lenBuf[2] = { (uint8_t)((frameLen >> 8) & 0xFF), (uint8_t)(frameLen & 0xFF) };
  f.write(lenBuf, 2);
  f.write(frame, frameLen);
  f.close();

  Serial.printf("[MAILBOX] Stored %s for %d offline recipient(s) (%d bytes)\n", path, count, frameLen);
}

// Delivers ONLY stored packets addressed to `username` and deletes them once delivered
void deliverOfflineMailboxForUser(uint16_t connId, const char* username) {
  if (!fsReady || !username || username[0] == '\0') return;

  // Store integer sequence numbers on stack (only ~640 bytes) so loopTask stack stays safe
  uint32_t seqList[MAX_MAILBOX_FILES];
  int matchCount = 0;

  File root = LittleFS.open("/mb");
  if (!root || !root.isDirectory()) return;

  File file = root.openNextFile();
  while (file && matchCount < MAX_MAILBOX_FILES) {
    String name = String(file.name());
    int slash = name.lastIndexOf('/');
    String base = slash >= 0 ? name.substring(slash + 1) : name;
    uint32_t seq = (uint32_t)base.toInt();
    if (seq > 0) {
      seqList[matchCount++] = seq;
    }
    file = root.openNextFile();
  }
  root.close();

  // Sort ascending so messages arrive chronologically
  for (int i = 0; i < matchCount - 1; i++) {
    for (int j = i + 1; j < matchCount; j++) {
      if (seqList[j] < seqList[i]) {
        uint32_t tmp = seqList[i];
        seqList[i] = seqList[j];
        seqList[j] = tmp;
      }
    }
  }

  int delivered = 0;
  char pathBuf[32];
  for (int i = 0; i < matchCount; i++) {
    snprintf(pathBuf, sizeof(pathBuf), "/mb/%08lu.pkt", (unsigned long)seqList[i]);
    File f = LittleFS.open(pathBuf, "r");
    if (!f) continue;

    uint8_t count = 0;
    if (f.read(&count, 1) != 1 || count == 0 || count > MAX_GROUP_MEMBERS) {
      f.close();
      LittleFS.remove(pathBuf);
      continue;
    }

    char recList[MAX_GROUP_MEMBERS][MAX_ID_LEN + 1];
    bool isForUser = false;
    for (int r = 0; r < count; r++) {
      memset(recList[r], 0, MAX_ID_LEN + 1);
      f.read((uint8_t*)recList[r], MAX_ID_LEN + 1);
      recList[r][MAX_ID_LEN] = '\0';
      if (strcmp(recList[r], username) == 0) {
        isForUser = true;
      }
    }

    if (!isForUser) {
      f.close();
      continue;
    }

    uint8_t lenBuf[2];
    if (f.read(lenBuf, 2) != 2) {
      f.close();
      continue;
    }
    uint16_t frameLen = ((uint16_t)lenBuf[0] << 8) | lenBuf[1];
    if (frameLen == 0 || frameLen > MAX_PACKET_SIZE) {
      f.close();
      LittleFS.remove(pathBuf);
      continue;
    }

    uint8_t frame[MAX_PACKET_SIZE];
    size_t got = f.read(frame, frameLen);
    f.close();

    if (got == frameLen) {
      if (sendToConnId(connId, frame, frameLen)) {
        delivered++;
        delay(18); // Gentle pacing so BLE queue never drops multi-chunk voice notes

        // Remove this user from pending recipient list
        char remaining[MAX_GROUP_MEMBERS][MAX_ID_LEN + 1];
        int remCount = 0;
        for (int r = 0; r < count; r++) {
          if (strcmp(recList[r], username) != 0) {
            strncpy(remaining[remCount], recList[r], MAX_ID_LEN);
            remaining[remCount][MAX_ID_LEN] = '\0';
            remCount++;
          }
        }

        if (remCount == 0) {
          LittleFS.remove(pathBuf);
        } else {
          File wf = LittleFS.open(pathBuf, "w");
          if (wf) {
            uint8_t rc = (uint8_t)remCount;
            wf.write(&rc, 1);
            for (int r = 0; r < remCount; r++) {
              wf.write((const uint8_t*)remaining[r], MAX_ID_LEN + 1);
            }
            wf.write(lenBuf, 2);
            wf.write(frame, frameLen);
            wf.close();
          }
        }
      }
    }
  }

  if (delivered > 0) {
    Serial.printf("[MAILBOX] Synced %d buffered packet(s) to '%s'\n", delivered, username);
  }
}

// ============================================================================
// Peer Directory Broadcast
// ============================================================================

void sendPeerDirectoryToConn(uint16_t connId) {
  int totalPeers = 0;
  int peerIndices[MAX_PEERS];
  for (int i = 0; i < MAX_PEERS; i++) {
    if (peers[i].active) {
      peerIndices[totalPeers++] = i;
    }
  }

  if (totalPeers == 0) return;

  // Paginate up to 8 peers per packet so payload stays well under BLE MTU
  const int PER_PAGE = 8;
  uint8_t totalPages = (uint8_t)((totalPeers + PER_PAGE - 1) / PER_PAGE);

  for (uint8_t page = 0; page < totalPages; page++) {
    uint8_t payload[420];
    size_t pOff = 0;
    payload[pOff++] = page;
    payload[pOff++] = totalPages;

    int startIdx = page * PER_PAGE;
    int endIdx = min(startIdx + PER_PAGE, totalPeers);
    payload[pOff++] = (uint8_t)(endIdx - startIdx);

    for (int k = startIdx; k < endIdx; k++) {
      PeerRecord& pr = peers[peerIndices[k]];
      uint8_t uLen = (uint8_t)strlen(pr.username);
      uint8_t dLen = (uint8_t)strlen(pr.displayName);
      if (pOff + 3 + uLen + dLen >= sizeof(payload)) break;

      payload[pOff++] = uLen;
      memcpy(&payload[pOff], pr.username, uLen);
      pOff += uLen;

      payload[pOff++] = dLen;
      memcpy(&payload[pOff], pr.displayName, dLen);
      pOff += dLen;

      bool online = (findSessionByUsername(pr.username) >= 0);
      payload[pOff++] = online ? 0x01 : 0x00;
    }

    uint8_t frame[MAX_PACKET_SIZE];
    size_t fLen = buildV2Packet(
      frame,
      PKT_PEER_DIRECTORY,
      nullptr,
      "RELAY",
      "ALL",
      0x00,
      payload,
      (uint16_t)pOff
    );
    if (fLen > 0) {
      sendToConnId(connId, frame, fLen);
      delay(12);
    }
  }
}

void broadcastPeerDirectoryToAll() {
  for (int i = 0; i < MAX_CLIENTS; i++) {
    if (sessions[i].active && sessions[i].registered) {
      sendPeerDirectoryToConn(sessions[i].connId);
    }
  }
}

// ============================================================================
// Protocol v2 Packet Processor
// ============================================================================

void routePacketToTargets(
  const char targets[][MAX_ID_LEN + 1],
  int targetCount,
  const uint8_t* rawFrame,
  uint16_t rawLen,
  bool storeIfOffline
) {
  char offlineList[MAX_GROUP_MEMBERS][MAX_ID_LEN + 1];
  int offlineCount = 0;

  for (int i = 0; i < targetCount; i++) {
    int sessIdx = findSessionByUsername(targets[i]);
    if (sessIdx >= 0) {
      sendToConnId(sessions[sessIdx].connId, rawFrame, rawLen);
    } else if (storeIfOffline && offlineCount < MAX_GROUP_MEMBERS) {
      strncpy(offlineList[offlineCount], targets[i], MAX_ID_LEN);
      offlineList[offlineCount][MAX_ID_LEN] = '\0';
      offlineCount++;
    }
  }

  if (storeIfOffline && offlineCount > 0) {
    storeOfflinePacket(offlineList, offlineCount, rawFrame, rawLen);
  }
}

void processIncomingFrame(const RxFrame& rf) {
  if (rf.len < MIN_HEADER_V2) return;
  const uint8_t* b = rf.data;

  if (b[0] != PROTO_VER_V2) {
    Serial.printf("[PROTO] Ignored non-v2 frame (ver=0x%02X)\n", b[0]);
    return;
  }

  uint8_t pktType = b[1];
  const uint8_t* msgUuid = &b[2];
  uint8_t sLen = b[18];
  uint8_t tLen = b[19];
  uint8_t flags = b[20];
  uint16_t pLen = ((uint16_t)b[21] << 8) | b[22];

  if (sLen > MAX_ID_LEN || tLen > MAX_ID_LEN) return;
  size_t expectedLen = MIN_HEADER_V2 + sLen + tLen + pLen;
  if (rf.len < expectedLen) {
    Serial.printf("[PROTO] Truncated frame: got %d, expected %d\n", rf.len, expectedLen);
    return;
  }

  char senderId[MAX_ID_LEN + 1];
  char targetId[MAX_ID_LEN + 1];
  memset(senderId, 0, sizeof(senderId));
  memset(targetId, 0, sizeof(targetId));
  if (sLen > 0) memcpy(senderId, &b[MIN_HEADER_V2], sLen);
  if (tLen > 0) memcpy(targetId, &b[MIN_HEADER_V2 + sLen], tLen);
  const uint8_t* payload = &b[MIN_HEADER_V2 + sLen + tLen];

  // Fast path: Live Call Audio Frame (zero Flash I/O, zero LED delay)
  if (pktType == PKT_CALL_AUDIO) {
    int sessIdx = findSessionByUsername(targetId);
    if (sessIdx >= 0) {
      sendToConnId(sessions[sessIdx].connId, rf.data, rf.len);
    }
    return;
  }

  // Fast path: Call Signaling (INVITE, RINGING, ACCEPT, REJECT, BUSY, HANGUP)
  if (pktType == PKT_CALL_SIGNAL) {
    uint8_t sigCode = pLen > 0 ? payload[0] : 0;
    int targetSess = findSessionByUsername(targetId);
    Serial.printf("[CALL] Signal 0x%02X: %s -> %s (online=%d)\n", sigCode, senderId, targetId, targetSess >= 0 ? 1 : 0);

    if (targetSess >= 0) {
      if (!sendToConnId(sessions[targetSess].connId, rf.data, rf.len)) {
        delay(4);
        sendToConnId(sessions[targetSess].connId, rf.data, rf.len);
      }
    } else if (sigCode == CALL_SIG_INVITE) {
      // Callee is not connected to relay right now: respond UNAVAILABLE immediately!
      uint8_t unavailPayload[1] = { CALL_SIG_UNAVAILABLE };
      uint8_t respFrame[MAX_PACKET_SIZE];
      size_t respLen = buildV2Packet(
        respFrame,
        PKT_CALL_SIGNAL,
        msgUuid,
        targetId,
        senderId,
        0x00,
        unavailPayload,
        1
      );
      if (respLen > 0) {
        sendToConnId(rf.connId, respFrame, respLen);
      }
    }
    return;
  }

  // Visual strobe for standard messages & control packets
  strobeLed(1, 20);

  // Presence Hello & Unique Username Registration
  if (pktType == PKT_PRESENCE_HELLO) {
    char displayName[33];
    memset(displayName, 0, sizeof(displayName));
    size_t dCopy = min((size_t)32, (size_t)pLen);
    if (dCopy > 0) memcpy(displayName, payload, dCopy);
    if (displayName[0] == '\0') strncpy(displayName, senderId, 32);

    int existingPeer = findPeerByUsername(senderId);
    bool conflict = false;

    if (existingPeer >= 0) {
      // Same username already registered: verify deviceUuid (stored in msgUuid)
      if (memcmp(peers[existingPeer].deviceUuid, msgUuid, 16) != 0) {
        conflict = true;
      } else {
        strncpy(peers[existingPeer].displayName, displayName, 32);
        peers[existingPeer].displayName[32] = '\0';
        savePeersToFS();
      }
    } else {
      // Register new unique user
      int slot = -1;
      for (int i = 0; i < MAX_PEERS; i++) {
        if (!peers[i].active) { slot = i; break; }
      }
      if (slot >= 0) {
        peers[slot].active = true;
        memcpy(peers[slot].deviceUuid, msgUuid, 16);
        strncpy(peers[slot].username, senderId, MAX_ID_LEN);
        peers[slot].username[MAX_ID_LEN] = '\0';
        strncpy(peers[slot].displayName, displayName, 32);
        peers[slot].displayName[32] = '\0';
        savePeersToFS();
        Serial.printf("[PRESENCE] Registered new unique user: '%s' (%s)\n", senderId, displayName);
      }
    }

    uint8_t ackStatus[1] = { (uint8_t)(conflict ? 0x02 : 0x01) }; // 0x01=OK, 0x02=NAME_CONFLICT
    uint8_t ackFrame[MAX_PACKET_SIZE];
    size_t ackLen = buildV2Packet(
      ackFrame,
      PKT_PRESENCE_HELLO,
      msgUuid,
      "RELAY",
      senderId,
      0x00,
      ackStatus,
      1
    );
    if (ackLen > 0) {
      sendToConnId(rf.connId, ackFrame, ackLen);
    }

    if (conflict) {
      Serial.printf("[PRESENCE] Name conflict rejected for '%s' on conn %d\n", senderId, rf.connId);
      return;
    }

    int sessIdx = findSessionByConnId(rf.connId);
    if (sessIdx < 0) {
      for (int i = 0; i < MAX_CLIENTS; i++) {
        if (!sessions[i].active) {
          sessions[i].active = true;
          sessions[i].connId = rf.connId;
          sessions[i].registered = false;
          memset(sessions[i].username, 0, sizeof(sessions[i].username));
          sessIdx = i;
          break;
        }
      }
    }
    if (sessIdx >= 0) {
      // Evict stale duplicate-username registration from any other connection
      for (int i = 0; i < MAX_CLIENTS; i++) {
        if (i != sessIdx && sessions[i].active && sessions[i].registered &&
            strcmp(sessions[i].username, senderId) == 0) {
          Serial.printf("[PRESENCE] Evicting stale '%s' on connId=%d\n",
            senderId, sessions[i].connId);
          sessions[i].registered = false;
          memset(sessions[i].username, 0, sizeof(sessions[i].username));
        }
      }
      strncpy(sessions[sessIdx].username, senderId, MAX_ID_LEN);
      sessions[sessIdx].username[MAX_ID_LEN] = '\0';
      sessions[sessIdx].registered = true;
    }

    Serial.printf("[PRESENCE] '%s' online on connId=%d\n", senderId, rf.connId);
    pendingDirectoryBroadcast = true;
    return;
  }

  // Sync Poll: Push directory + any offline messages addressed to senderId
  if (pktType == PKT_SYNC_POLL) {
    Serial.printf("[SYNC] Poll from '%s' (connId=%d)\n", senderId, rf.connId);
    sendPeerDirectoryToConn(rf.connId);
    deliverOfflineMailboxForUser(rf.connId, senderId);
    return;
  }

  // Group Meta Creation / Sync
  if (pktType == PKT_GROUP_META) {
    if (pLen < 2) return;
    uint8_t nameLen = payload[0];
    if (1 + nameLen >= pLen) return;
    uint8_t memberCount = payload[1 + nameLen];
    size_t pos = 2 + nameLen;

    int gIdx = findGroupById(targetId);
    if (gIdx < 0) {
      for (int i = 0; i < MAX_GROUPS; i++) {
        if (!groups[i].active) { gIdx = i; break; }
      }
    }
    if (gIdx >= 0) {
      groups[gIdx].active = true;
      strncpy(groups[gIdx].groupId, targetId, MAX_ID_LEN);
      groups[gIdx].groupId[MAX_ID_LEN] = '\0';
      groups[gIdx].memberCount = 0;

      char forwardTargets[MAX_GROUP_MEMBERS][MAX_ID_LEN + 1];
      int fwdCount = 0;

      for (int m = 0; m < memberCount && groups[gIdx].memberCount < MAX_GROUP_MEMBERS; m++) {
        if (pos >= pLen) break;
        uint8_t mLen = payload[pos++];
        if (mLen == 0 || mLen > MAX_ID_LEN || pos + mLen > pLen) break;

        char mName[MAX_ID_LEN + 1];
        memset(mName, 0, sizeof(mName));
        memcpy(mName, &payload[pos], mLen);
        pos += mLen;

        strncpy(groups[gIdx].members[groups[gIdx].memberCount], mName, MAX_ID_LEN);
        groups[gIdx].members[groups[gIdx].memberCount][MAX_ID_LEN] = '\0';
        groups[gIdx].memberCount++;

        if (strcmp(mName, senderId) != 0 && fwdCount < MAX_GROUP_MEMBERS) {
          strncpy(forwardTargets[fwdCount], mName, MAX_ID_LEN);
          forwardTargets[fwdCount][MAX_ID_LEN] = '\0';
          fwdCount++;
        }
      }
      saveGroupsToFS();
      Serial.printf("[GROUP] Saved group '%s' (%d members). Fanning out to %d peers.\n",
        targetId, groups[gIdx].memberCount, fwdCount);

      if (fwdCount > 0) {
        routePacketToTargets(forwardTargets, fwdCount, rf.data, rf.len, true);
      }
    }
    return;
  }

  // Standard 1-to-1 or Group Message / Voice Chunk / Delivery ACK
  if (pktType == PKT_TEXT_MSG || pktType == PKT_VOICE_CHUNK || pktType == PKT_DELIVERY_ACK) {
    bool isGroup = (flags & FLAG_GROUP) != 0;
    bool storeOffline = (pktType != PKT_DELIVERY_ACK); // Queue texts/voice & ACKs? Wait: queue ACKs too so sender gets double-check when returning!
    storeOffline = true;

    if (isGroup && pktType != PKT_DELIVERY_ACK) {
      int gIdx = findGroupById(targetId);
      if (gIdx >= 0) {
        char targets[MAX_GROUP_MEMBERS][MAX_ID_LEN + 1];
        int tCount = 0;
        for (int m = 0; m < groups[gIdx].memberCount; m++) {
          if (strcmp(groups[gIdx].members[m], senderId) != 0 && tCount < MAX_GROUP_MEMBERS) {
            strncpy(targets[tCount], groups[gIdx].members[m], MAX_ID_LEN);
            targets[tCount][MAX_ID_LEN] = '\0';
            tCount++;
          }
        }
        Serial.printf("[RELAY] Group %s (%s -> %d members, %d B)\n",
          pktType == PKT_TEXT_MSG ? "TXT" : "VOICE", senderId, tCount, rf.len);
        routePacketToTargets(targets, tCount, rf.data, rf.len, true);
      } else {
        Serial.printf("[RELAY] Unknown group '%s' from '%s'\n", targetId, senderId);
      }
    } else {
      char singleTarget[1][MAX_ID_LEN + 1];
      memset(singleTarget[0], 0, MAX_ID_LEN + 1);
      strncpy(singleTarget[0], targetId, MAX_ID_LEN);
      Serial.printf("[RELAY] Unicast 0x%02X: %s -> %s (%d B)\n", pktType, senderId, targetId, rf.len);
      routePacketToTargets(singleTarget, 1, rf.data, rf.len, storeOffline);
    }
  }
}

// ============================================================================
// BLE Callbacks
// ============================================================================

class DevKitServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pSrv, esp_ble_gatts_cb_param_t* param) override {
    uint16_t connId = param ? param->connect.conn_id : pSrv->getConnId();
    int existing = findSessionByConnId(connId);
    if (existing >= 0) {
      sessions[existing].registered = false;
      memset(sessions[existing].username, 0, sizeof(sessions[existing].username));
    } else {
      for (int i = 0; i < MAX_CLIENTS; i++) {
        if (!sessions[i].active) {
          sessions[i].active = true;
          sessions[i].connId = connId;
          sessions[i].registered = false;
          memset(sessions[i].username, 0, sizeof(sessions[i].username));
          break;
        }
      }
    }
    digitalWrite(STATUS_LED, HIGH);
    Serial.printf("\n[BLE] >>> Client connected (connId=%d). Active: %d\n", connId, getActiveSessionCount());
    pSrv->startAdvertising(); // Keep advertising for additional phones
  }

  void onDisconnect(BLEServer* pSrv, esp_ble_gatts_cb_param_t* param) override {
    uint16_t connId = param ? param->disconnect.conn_id : 0;
    bool wasRegistered = false;
    for (int i = 0; i < MAX_CLIENTS; i++) {
      if (sessions[i].active && sessions[i].connId == connId) {
        wasRegistered = sessions[i].registered;
        Serial.printf("\n[BLE] <<< Client disconnected (connId=%d, user='%s')\n",
          connId, sessions[i].username);
        sessions[i].active = false;
        sessions[i].registered = false;
        memset(sessions[i].username, 0, sizeof(sessions[i].username));
        break;
      }
    }
    if (getActiveSessionCount() == 0) {
      digitalWrite(STATUS_LED, LOW);
    }
    if (wasRegistered) {
      pendingDirectoryBroadcast = true;
    }
    pSrv->startAdvertising();
  }
};

class DevKitTxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pChar, esp_ble_gatts_cb_param_t* param) override {
    const uint8_t* rawPtr = nullptr;
    size_t len = 0;
    String rxData;

    if (param && param->write.len > 0 && param->write.value != nullptr) {
      rawPtr = param->write.value;
      len = param->write.len;
    } else {
      rxData = pChar->getValue();
      len = rxData.length();
      rawPtr = (const uint8_t*)rxData.c_str();
    }
    if (!rawPtr || len < MIN_HEADER_V2 || len > MAX_PACKET_SIZE) return;

    uint16_t connId = param ? param->write.conn_id : 0;

    portENTER_CRITICAL(&rxMux);
    int nextHead = (rxHead + 1) % RX_RING_SIZE;
    if (nextHead != rxTail) {
      rxRing[rxHead].connId = connId;
      rxRing[rxHead].len = (uint16_t)len;
      memcpy(rxRing[rxHead].data, rawPtr, len);
      rxHead = nextHead;
    }
    portEXIT_CRITICAL(&rxMux);
  }
};

// ============================================================================
// Setup & Main Loop
// ============================================================================

void setup() {
  Serial.begin(115200);
  delay(400);

  pinMode(STATUS_LED, OUTPUT);
  digitalWrite(STATUS_LED, LOW);
  memset(sessions, 0, sizeof(sessions));

  Serial.println("\n=============================================================");
  Serial.println("  ESP32 DEVKIT V1 - OFF-GRID MESSAGE MAIL RELAY (v2)");
  Serial.println("=============================================================");

  fsReady = LittleFS.begin(true);
  if (fsReady) {
    loadPeersFromFS();
    loadGroupsFromFS();
    initMailboxDir();
    Serial.printf("  LittleFS     : Mounted (%u / %u KB used)\n",
      (unsigned)(LittleFS.usedBytes() / 1024),
      (unsigned)(LittleFS.totalBytes() / 1024));
  } else {
    Serial.println("  LittleFS     : Failed to mount! Offline flash disabled.");
  }

  BLEDevice::init(NODE_NAME);
  BLEDevice::setCustomGattsHandler(onCustomGattsEvent);
  BLEDevice::setMTU(512);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new DevKitServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  pTxCharacteristic = pService->createCharacteristic(
    CHAR_DATA_TX_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  pTxCharacteristic->setCallbacks(new DevKitTxCallbacks());

  pRxCharacteristic = pService->createCharacteristic(
    CHAR_DATA_RX_UUID,
    BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ
  );
  pRxCharacteristic->addDescriptor(new BLE2902());

  pService->start();

  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.printf("  BLE Device   : %s\n", NODE_NAME);
  Serial.printf("  Service UUID : %s\n", SERVICE_UUID);
  Serial.println("=============================================================\n");
}

void loop() {
  // Drain queued incoming frames cleanly outside BLE stack task
  while (true) {
    RxFrame rf;
    bool hasItem = false;

    portENTER_CRITICAL(&rxMux);
    if (rxTail != rxHead) {
      rf = rxRing[rxTail];
      rxTail = (rxTail + 1) % RX_RING_SIZE;
      hasItem = true;
    }
    portEXIT_CRITICAL(&rxMux);

    if (!hasItem) break;
    processIncomingFrame(rf);
  }

  if (pendingDirectoryBroadcast) {
    pendingDirectoryBroadcast = false;
    broadcastPeerDirectoryToAll();
  }

  // LED Status Indicator
  if (getActiveSessionCount() == 0) {
    unsigned long now = millis();
    if (now - lastLedBlink >= 600) {
      lastLedBlink = now;
      ledState = !ledState;
      digitalWrite(STATUS_LED, ledState ? HIGH : LOW);
    }
  } else {
    digitalWrite(STATUS_LED, HIGH);
  }

  delay(2);
}
