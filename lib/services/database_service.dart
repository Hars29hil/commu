import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/message_mail.dart';
import '../protocol/ble_packet_codec.dart';

/// Offline SQLite persistence layer (Schema v2):
/// Supports local user profile, auto-discovered mesh peers, groups,
/// 1-to-1 & group chats, unread counters, call logs, and store-and-forward queue.
class DatabaseService {
  static const String tableName = 'message_mail';
  static const String databaseName = 'message_mail.db';
  static const int databaseVersion = 2;

  Database? _db;

  DatabaseService([Database? db]) : _db = db;

  Future<Database> get database async {
    if (_db != null && _db!.isOpen) return _db!;
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, databaseName);

    return await openDatabase(
      path,
      version: databaseVersion,
      onCreate: (db, version) async {
        await createSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _upgradeToV2(db);
        }
      },
    );
  }

  /// Creates full v2 schema.
  static Future<void> createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE local_profile (
        id INTEGER PRIMARY KEY CHECK(id = 1),
        device_uuid TEXT NOT NULL,
        username TEXT NOT NULL,
        display_name TEXT NOT NULL,
        is_verified INTEGER DEFAULT 0
      );
    ''');

    await db.execute('''
      CREATE TABLE peers (
        username TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        is_online INTEGER DEFAULT 0,
        last_seen INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE groups (
        group_id TEXT PRIMARY KEY,
        group_name TEXT NOT NULL,
        created_by TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE group_members (
        group_id TEXT NOT NULL,
        username TEXT NOT NULL,
        PRIMARY KEY (group_id, username)
      );
    ''');

    await db.execute('''
      CREATE TABLE $tableName (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        recipient_id TEXT NOT NULL,
        is_group INTEGER DEFAULT 0,
        payload_type TEXT NOT NULL CHECK(payload_type IN ('text', 'voice_mail', 'call_log')),
        text_content TEXT,
        audio_blob BLOB,
        duration_ms INTEGER DEFAULT 0,
        codec_type INTEGER DEFAULT 1,
        is_read INTEGER DEFAULT 1,
        timestamp INTEGER NOT NULL,
        retry_count INTEGER DEFAULT 0,
        status TEXT NOT NULL CHECK(status IN ('PENDING_LOCAL', 'IN_TRANSIT', 'DELIVERED', 'FAILED'))
      );
    ''');

    await db.execute('CREATE INDEX idx_chat_time ON $tableName (chat_id, timestamp);');
    await db.execute('CREATE INDEX idx_status ON $tableName (status);');
  }

  static Future<void> _upgradeToV2(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS local_profile (
        id INTEGER PRIMARY KEY CHECK(id = 1),
        device_uuid TEXT NOT NULL,
        username TEXT NOT NULL,
        display_name TEXT NOT NULL,
        is_verified INTEGER DEFAULT 0
      );
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS peers (
        username TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        is_online INTEGER DEFAULT 0,
        last_seen INTEGER NOT NULL
      );
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS groups (
        group_id TEXT PRIMARY KEY,
        group_name TEXT NOT NULL,
        created_by TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS group_members (
        group_id TEXT NOT NULL,
        username TEXT NOT NULL,
        PRIMARY KEY (group_id, username)
      );
    ''');

    // Recreate message_mail cleanly to relax old CHECK constraint on payload_type
    await db.execute('ALTER TABLE $tableName RENAME TO ${tableName}_v1;');
    await db.execute('''
      CREATE TABLE $tableName (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL,
        sender_id TEXT NOT NULL,
        recipient_id TEXT NOT NULL,
        is_group INTEGER DEFAULT 0,
        payload_type TEXT NOT NULL CHECK(payload_type IN ('text', 'voice_mail', 'call_log')),
        text_content TEXT,
        audio_blob BLOB,
        duration_ms INTEGER DEFAULT 0,
        codec_type INTEGER DEFAULT 1,
        is_read INTEGER DEFAULT 1,
        timestamp INTEGER NOT NULL,
        retry_count INTEGER DEFAULT 0,
        status TEXT NOT NULL CHECK(status IN ('PENDING_LOCAL', 'IN_TRANSIT', 'DELIVERED', 'FAILED'))
      );
    ''');
    await db.execute('''
      INSERT INTO $tableName (id, chat_id, sender_id, recipient_id, is_group, payload_type, text_content, audio_blob, duration_ms, codec_type, is_read, timestamp, retry_count, status)
      SELECT id, recipient_id, sender_id, recipient_id, 0, payload_type, text_content, audio_blob, 0, 1, 1, timestamp, retry_count, status
      FROM ${tableName}_v1;
    ''');
    await db.execute('DROP TABLE ${tableName}_v1;');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_chat_time ON $tableName (chat_id, timestamp);');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_status ON $tableName (status);');
  }

  // ---------------------------------------------------------------------------
  // Local Profile
  // ---------------------------------------------------------------------------

  Future<LocalProfile?> getLocalProfile() async {
    final db = await database;
    final rows = await db.query('local_profile', where: 'id = 1', limit: 1);
    if (rows.isEmpty) return null;
    return LocalProfile.fromMap(rows.first);
  }

  Future<void> saveLocalProfile(LocalProfile profile) async {
    final db = await database;
    await db.insert(
      'local_profile',
      profile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------------------------------------------------------------------------
  // Peers Directory
  // ---------------------------------------------------------------------------

  Future<void> upsertPeers(List<DirectoryPeerEntry> entries, {bool markOthersOffline = false}) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      if (markOthersOffline) {
        await txn.update('peers', {'is_online': 0});
      }
      for (final e in entries) {
        await txn.insert(
          'peers',
          {
            'username': e.username,
            'display_name': e.displayName,
            'is_online': e.isOnline ? 1 : 0,
            'last_seen': now,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<void> setAllPeersOffline() async {
    final db = await database;
    await db.update('peers', {'is_online': 0});
  }

  Future<List<PeerUser>> getPeers({String? excludeUsername}) async {
    final db = await database;
    final rows = excludeUsername == null
        ? await db.query('peers', orderBy: 'is_online DESC, display_name ASC')
        : await db.query(
            'peers',
            where: 'username != ?',
            whereArgs: [excludeUsername],
            orderBy: 'is_online DESC, display_name ASC',
          );
    return rows.map((r) => PeerUser.fromMap(r)).toList();
  }

  Future<PeerUser?> getPeer(String username) async {
    final db = await database;
    final rows = await db.query('peers', where: 'username = ?', whereArgs: [username], limit: 1);
    if (rows.isEmpty) return null;
    return PeerUser.fromMap(rows.first);
  }

  // ---------------------------------------------------------------------------
  // Groups
  // ---------------------------------------------------------------------------

  Future<void> saveGroup(ChatGroup group) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'groups',
        group.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.delete('group_members', where: 'group_id = ?', whereArgs: [group.groupId]);
      for (final m in group.members) {
        await txn.insert(
          'group_members',
          {'group_id': group.groupId, 'username': m},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<List<ChatGroup>> getGroups() async {
    final db = await database;
    final groupRows = await db.query('groups', orderBy: 'created_at DESC');
    final result = <ChatGroup>[];
    for (final row in groupRows) {
      final gId = row['group_id'] as String;
      final memRows = await db.query(
        'group_members',
        where: 'group_id = ?',
        whereArgs: [gId],
      );
      final members = memRows.map((m) => m['username'] as String).toList();
      result.add(ChatGroup.fromMap(row, members));
    }
    return result;
  }

  Future<ChatGroup?> getGroupById(String groupId) async {
    final db = await database;
    final rows = await db.query('groups', where: 'group_id = ?', whereArgs: [groupId], limit: 1);
    if (rows.isEmpty) return null;
    final memRows = await db.query('group_members', where: 'group_id = ?', whereArgs: [groupId]);
    final members = memRows.map((m) => m['username'] as String).toList();
    return ChatGroup.fromMap(rows.first, members);
  }

  // ---------------------------------------------------------------------------
  // Messages & WhatsApp Chat Summaries
  // ---------------------------------------------------------------------------

  Future<void> saveOutgoingMessage(MessageMail message) async {
    final db = await database;
    final record = message.copyWith(
      status: message.payloadType == PayloadType.callLog
          ? MessageStatus.delivered
          : MessageStatus.pendingLocal,
      isRead: true,
    );
    await db.insert(
      tableName,
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<MessageMail>> getPendingOutbox() async {
    final db = await database;
    final results = await db.query(
      tableName,
      where: 'status = ? AND payload_type != ?',
      whereArgs: [MessageStatus.pendingLocal.value, PayloadType.callLog.value],
      orderBy: 'timestamp ASC',
    );
    return results.map((map) => MessageMail.fromMap(map)).toList();
  }

  Future<int> markAsInTransit(String id) async {
    final db = await database;
    return await db.update(
      tableName,
      {'status': MessageStatus.inTransit.value},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> saveIncomingMessage(MessageMail message) async {
    final db = await database;
    final record = message.copyWith(status: MessageStatus.delivered);
    await db.insert(
      tableName,
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> updateStatusByAck(String id, String newStatus) async {
    final db = await database;
    if (!['PENDING_LOCAL', 'IN_TRANSIT', 'DELIVERED', 'FAILED'].contains(newStatus)) {
      throw ArgumentError('Invalid status constraint value: $newStatus');
    }
    return await db.update(
      tableName,
      {'status': newStatus},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> incrementRetryCount(String id) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE $tableName SET retry_count = retry_count + 1 WHERE id = ?',
      [id],
    );
  }

  Future<void> markChatAsRead(String chatId) async {
    final db = await database;
    await db.update(
      tableName,
      {'is_read': 1},
      where: 'chat_id = ? AND is_read = 0',
      whereArgs: [chatId],
    );
  }

  Future<List<MessageMail>> getAllMessages() async {
    final db = await database;
    final results = await db.query(tableName, orderBy: 'timestamp ASC');
    return results.map((map) => MessageMail.fromMap(map)).toList();
  }

  Future<List<MessageMail>> getMessagesForChat(String chatId) async {
    final db = await database;
    final results = await db.query(
      tableName,
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp ASC',
    );
    return results.map((map) => MessageMail.fromMap(map)).toList();
  }

  Future<List<ChatSummary>> getChatSummaries(String localUsername) async {
    final peers = await getPeers(excludeUsername: localUsername);
    final peerMap = {for (final p in peers) p.username: p};
    final groups = await getGroups();
    final groupMap = {for (final g in groups) g.groupId: g};

    final db = await database;
    final allMsgs = await db.query(tableName, orderBy: 'timestamp DESC');

    final lastMsgByChat = <String, MessageMail>{};
    final unreadByChat = <String, int>{};

    for (final row in allMsgs) {
      final msg = MessageMail.fromMap(row);
      lastMsgByChat.putIfAbsent(msg.chatId, () => msg);
      if (!msg.isRead && msg.senderId != localUsername) {
        unreadByChat[msg.chatId] = (unreadByChat[msg.chatId] ?? 0) + 1;
      }
    }

    final chatIds = <String>{
      ...lastMsgByChat.keys,
      ...groupMap.keys,
    };

    final summaries = <ChatSummary>[];
    for (final cid in chatIds) {
      if (cid == localUsername) continue;
      final group = groupMap[cid];
      final peer = peerMap[cid];
      final lastMsg = lastMsgByChat[cid];

      if (group != null) {
        summaries.add(
          ChatSummary(
            chatId: cid,
            title: group.groupName,
            isGroup: true,
            isOnline: false,
            memberCount: group.members.length,
            lastMessage: lastMsg,
            unreadCount: unreadByChat[cid] ?? 0,
            lastActivityMs: lastMsg?.timestamp ?? group.createdAt,
          ),
        );
      } else {
        summaries.add(
          ChatSummary(
            chatId: cid,
            title: peer?.displayName ?? cid,
            isGroup: false,
            isOnline: peer?.isOnline ?? false,
            memberCount: 2,
            lastMessage: lastMsg,
            unreadCount: unreadByChat[cid] ?? 0,
            lastActivityMs: lastMsg?.timestamp ?? peer?.lastSeen ?? 0,
          ),
        );
      }
    }

    summaries.sort((a, b) => b.lastActivityMs.compareTo(a.lastActivityMs));
    return summaries;
  }

  Future<MessageMail?> getMessageById(String id) async {
    final db = await database;
    final results = await db.query(tableName, where: 'id = ?', whereArgs: [id], limit: 1);
    if (results.isEmpty) return null;
    return MessageMail.fromMap(results.first);
  }

  Future<int> deleteMessage(String id) async {
    final db = await database;
    return await db.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> resetStuckQueueToPending() async {
    final db = await database;
    return await db.update(
      tableName,
      {'status': MessageStatus.pendingLocal.value},
      where: 'status IN (?, ?)',
      whereArgs: [MessageStatus.inTransit.value, MessageStatus.failed.value],
    );
  }

  Future<int> clearAllMessages() async {
    final db = await database;
    return await db.delete(tableName);
  }

  Future<Map<String, int>> getDatabaseStats() async {
    final db = await database;
    final pendingCount = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM $tableName WHERE status = 'PENDING_LOCAL'",
        )) ??
        0;
    final transitCount = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM $tableName WHERE status = 'IN_TRANSIT'",
        )) ??
        0;
    final deliveredCount = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM $tableName WHERE status = 'DELIVERED'",
        )) ??
        0;
    final failedCount = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM $tableName WHERE status = 'FAILED'",
        )) ??
        0;
    final totalCount = Sqflite.firstIntValue(await db.rawQuery(
          "SELECT COUNT(*) FROM $tableName",
        )) ??
        0;

    return {
      'PENDING_LOCAL': pendingCount,
      'IN_TRANSIT': transitCount,
      'DELIVERED': deliveredCount,
      'FAILED': failedCount,
      'TOTAL': totalCount,
    };
  }

  Future<void> close() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
      _db = null;
    }
  }
}
