import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/message_mail.dart';

/// Database service managing offline SQLite persistence for Message Mail.
/// Follows strict schema constraints and state lifecycle transitions:
/// PENDING_LOCAL -> IN_TRANSIT -> DELIVERED (or FAILED).
class DatabaseService {
  static const String tableName = 'message_mail';
  static const String databaseName = 'message_mail.db';
  static const int databaseVersion = 1;

  Database? _db;

  /// Optional injected database instance (used for unit testing with in-memory SQLite).
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
    );
  }

  /// Creates schema and indices matching specification.
  static Future<void> createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE $tableName (
        id TEXT PRIMARY KEY,
        sender_id TEXT NOT NULL,
        recipient_id TEXT NOT NULL,
        payload_type TEXT NOT NULL CHECK(payload_type IN ('text', 'voice_mail')),
        text_content TEXT,
        audio_blob BLOB,
        timestamp INTEGER NOT NULL,
        retry_count INTEGER DEFAULT 0,
        status TEXT NOT NULL CHECK(status IN ('PENDING_LOCAL', 'IN_TRANSIT', 'DELIVERED', 'FAILED'))
      );
    ''');

    await db.execute('''
      CREATE INDEX idx_recipient_status ON $tableName (recipient_id, status);
    ''');

    await db.execute('''
      CREATE INDEX idx_status ON $tableName (status);
    ''');
  }

  /// Enqueues an outgoing message mail into local SQLite as `PENDING_LOCAL`.
  Future<void> saveOutgoingMessage(MessageMail message) async {
    final db = await database;
    final record = message.copyWith(status: MessageStatus.pendingLocal);
    await db.insert(
      tableName,
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Retrieves all `PENDING_LOCAL` records ordered chronologically by `timestamp ASC`.
  Future<List<MessageMail>> getPendingOutbox() async {
    final db = await database;
    final results = await db.query(
      tableName,
      where: 'status = ?',
      whereArgs: [MessageStatus.pendingLocal.value],
      orderBy: 'timestamp ASC',
    );
    return results.map((map) => MessageMail.fromMap(map)).toList();
  }

  /// Updates status to `IN_TRANSIT` when message is transferred to the connected ESP32 node.
  Future<int> markAsInTransit(String id) async {
    final db = await database;
    return await db.update(
      tableName,
      {'status': MessageStatus.inTransit.value},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Inserts a newly received message mail and marks it as `DELIVERED`.
  Future<void> saveIncomingMessage(MessageMail message) async {
    final db = await database;
    final record = message.copyWith(status: MessageStatus.delivered);
    await db.insert(
      tableName,
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Handles end-to-end LoRa delivery acknowledgments or retry failures.
  Future<int> updateStatusByAck(String id, String newStatus) async {
    final db = await database;
    // Validate constraint
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

  /// Increments the retry counter for a message that failed BLE transmission.
  Future<void> incrementRetryCount(String id) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE $tableName SET retry_count = retry_count + 1 WHERE id = ?',
      [id],
    );
  }

  /// Retrieves all messages in chronological order.
  Future<List<MessageMail>> getAllMessages() async {
    final db = await database;
    final results = await db.query(tableName, orderBy: 'timestamp ASC');
    return results.map((map) => MessageMail.fromMap(map)).toList();
  }

  /// Retrieves messages exchanged with a specific contact / node.
  Future<List<MessageMail>> getMessagesForConversation(String contactId) async {
    final db = await database;
    final results = await db.query(
      tableName,
      where: 'sender_id = ? OR recipient_id = ? OR recipient_id = ?',
      whereArgs: [contactId, contactId, 'ALL'],
      orderBy: 'timestamp ASC',
    );
    return results.map((map) => MessageMail.fromMap(map)).toList();
  }

  /// Retrieves a specific message by UUID.
  Future<MessageMail?> getMessageById(String id) async {
    final db = await database;
    final results = await db.query(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return MessageMail.fromMap(results.first);
  }

  /// Deletes a specific message.
  Future<int> deleteMessage(String id) async {
    final db = await database;
    return await db.delete(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Resets stuck `IN_TRANSIT` or `FAILED` messages back to `PENDING_LOCAL` for retransmission.
  Future<int> resetStuckQueueToPending() async {
    final db = await database;
    return await db.update(
      tableName,
      {'status': MessageStatus.pendingLocal.value},
      where: 'status IN (?, ?)',
      whereArgs: [MessageStatus.inTransit.value, MessageStatus.failed.value],
    );
  }

  /// Clears all messages from the database.
  Future<int> clearAllMessages() async {
    final db = await database;
    return await db.delete(tableName);
  }

  /// Returns diagnostic stats about the offline database.
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

