import 'dart:convert';
import 'dart:io';

/// Зарегистрированное поле. Доступ к полю есть только у номера, который его
/// зарегистрировал: сам по себе номер не даёт права на чужие поля.
class FieldRecord {
  final String fieldId;
  final double latitude;
  final double longitude;
  final String? crop;
  final DateTime registeredAt;

  /// Кэш климатологии NASA POWER (закодированный ClimateSummary).
  final String? climate;

  const FieldRecord({
    required this.fieldId,
    required this.latitude,
    required this.longitude,
    this.crop,
    required this.registeredAt,
    this.climate,
  });

  FieldRecord withClimate(String value) => FieldRecord(
        fieldId: fieldId,
        latitude: latitude,
        longitude: longitude,
        crop: crop,
        registeredAt: registeredAt,
        climate: value,
      );

  Map<String, dynamic> toJson() => {
        'field_id': fieldId,
        'latitude': latitude,
        'longitude': longitude,
        'crop': crop,
        'registered_at': registeredAt.toIso8601String(),
        'climate': climate,
      };

  factory FieldRecord.fromJson(Map<String, dynamic> json) => FieldRecord(
        fieldId: json['field_id'] as String,
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        crop: json['crop'] as String?,
        registeredAt: DateTime.parse(json['registered_at'] as String),
        climate: json['climate'] as String?,
      );
}

/// Контекст SMS-диалога одного номера.
class Conversation {
  String? activeField;

  /// Признаки из прошлых сообщений (JSON) — для уточняющих ответов.
  String? facts;

  DateTime updatedAt;
  bool optedOut;

  /// Время входящих сообщений и запросов данных — для лимитов.
  final List<DateTime> inbound;
  final List<DateTime> dataRequests;

  Conversation({
    this.activeField,
    this.facts,
    required this.updatedAt,
    this.optedOut = false,
    List<DateTime>? inbound,
    List<DateTime>? dataRequests,
  })  : inbound = inbound ?? [],
        dataRequests = dataRequests ?? [];

  Map<String, dynamic> toJson() => {
        'active_field': activeField,
        'facts': facts,
        'updated_at': updatedAt.toIso8601String(),
        'opted_out': optedOut,
        'inbound': inbound.map((d) => d.toIso8601String()).toList(),
        'data_requests': dataRequests.map((d) => d.toIso8601String()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        activeField: json['active_field'] as String?,
        facts: json['facts'] as String?,
        updatedAt: DateTime.parse(json['updated_at'] as String),
        optedOut: json['opted_out'] as bool? ?? false,
        inbound: [for (final d in json['inbound'] as List? ?? []) DateTime.parse('$d')],
        dataRequests: [
          for (final d in json['data_requests'] as List? ?? []) DateTime.parse('$d'),
        ],
      );
}

class PackageRecord {
  final String token;
  final String requestId;
  final String ownerHash;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int bytes;

  const PackageRecord({
    required this.token,
    required this.requestId,
    required this.ownerHash,
    required this.createdAt,
    required this.expiresAt,
    required this.bytes,
  });

  Map<String, dynamic> toJson() => {
        'token': token,
        'request_id': requestId,
        'owner_hash': ownerHash,
        'created_at': createdAt.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
        'bytes': bytes,
      };

  factory PackageRecord.fromJson(Map<String, dynamic> json) => PackageRecord(
        token: json['token'] as String,
        requestId: json['request_id'] as String,
        ownerHash: json['owner_hash'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        expiresAt: DateTime.parse(json['expires_at'] as String),
        bytes: json['bytes'] as int,
      );
}

/// Простое файловое хранилище: один JSON-файл, атомарная запись.
/// Для пилота достаточно; при росте — заменить на базу данных.
class Store {
  final Directory dir;
  final Map<String, Map<String, FieldRecord>> fields = {};
  final Map<String, Conversation> conversations = {};
  final Map<String, PackageRecord> packages = {};

  /// Идентификаторы уже обработанных сообщений — защита от повторов.
  final Map<String, DateTime> seenMessages = {};

  int _requestCounter = 0;

  /// Записи идут по очереди: фоновые задачи и новые сообщения не должны
  /// одновременно перезаписывать файл.
  Future<void> _saving = Future.value();

  Store(this.dir);

  File get _file => File('${dir.path}/store.json');
  Directory get packagesDir => Directory('${dir.path}/packages');

  static Future<Store> open(String path) async {
    final store = Store(Directory(path));
    await store.dir.create(recursive: true);
    await store.packagesDir.create(recursive: true);
    if (await store._file.exists()) {
      store._load(jsonDecode(await store._file.readAsString()) as Map<String, dynamic>);
    }
    return store;
  }

  void _load(Map<String, dynamic> json) {
    (json['fields'] as Map<String, dynamic>? ?? {}).forEach((phone, items) {
      fields[phone] = {
        for (final entry in (items as Map<String, dynamic>).entries)
          entry.key: FieldRecord.fromJson(entry.value as Map<String, dynamic>),
      };
    });
    (json['conversations'] as Map<String, dynamic>? ?? {}).forEach((phone, value) {
      conversations[phone] = Conversation.fromJson(value as Map<String, dynamic>);
    });
    (json['packages'] as Map<String, dynamic>? ?? {}).forEach((token, value) {
      packages[token] = PackageRecord.fromJson(value as Map<String, dynamic>);
    });
    (json['seen'] as Map<String, dynamic>? ?? {}).forEach((id, value) {
      seenMessages[id] = DateTime.parse('$value');
    });
    _requestCounter = json['request_counter'] as int? ?? 0;
  }

  Future<void> save() {
    final next = _saving.then((_) => _write());
    _saving = next.catchError((_) {});
    return next;
  }

  Future<void> _write() async {
    final payload = jsonEncode({
      'fields': {
        for (final e in fields.entries)
          e.key: {for (final f in e.value.entries) f.key: f.value.toJson()},
      },
      'conversations': {
        for (final e in conversations.entries) e.key: e.value.toJson(),
      },
      'packages': {for (final e in packages.entries) e.key: e.value.toJson()},
      'seen': {
        for (final e in seenMessages.entries) e.key: e.value.toIso8601String(),
      },
      'request_counter': _requestCounter,
    });
    final temp = File('${_file.path}.tmp');
    await temp.writeAsString(payload, flush: true);
    await temp.rename(_file.path);
  }

  Conversation conversation(String phone, DateTime now) =>
      conversations.putIfAbsent(phone, () => Conversation(updatedAt: now));

  String nextRequestId(DateTime now) {
    _requestCounter++;
    return 'REQ-${now.year}-${_requestCounter.toString().padLeft(6, '0')}';
  }

  /// Убирает устаревшее: контексты, отметки сообщений, просроченные пакеты.
  Future<void> purge(DateTime now, Duration contextTtl) async {
    for (final conversation in conversations.values) {
      if (now.difference(conversation.updatedAt) > contextTtl) {
        conversation.facts = null;
      }
      conversation.inbound.removeWhere((d) => now.difference(d).inDays >= 1);
      conversation.dataRequests.removeWhere((d) => now.difference(d).inDays >= 1);
    }
    seenMessages.removeWhere((_, d) => now.difference(d).inDays >= 2);

    final expired = [
      for (final p in packages.values)
        if (now.isAfter(p.expiresAt)) p.token,
    ];
    for (final token in expired) {
      packages.remove(token);
      final file = File('${packagesDir.path}/$token.json');
      if (await file.exists()) {
        await file.delete();
      }
    }
  }
}
