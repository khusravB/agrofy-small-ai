
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../models/climate_history.dart';
import '../models/climate_summary.dart';
import '../models/terrain_info.dart';
import '../models/crop_season.dart';
import '../models/farmer_priorities.dart';
import '../models/field.dart';
import '../models/field_event.dart';

class DatabaseService {
  static final DatabaseService instance = DatabaseService._init();

  /// Текущая версия схемы локальной БД.
  static const int schemaVersion = 5;

  static Database? _database;

  DatabaseService._init();

  /// Подменяет базу данных (для тестов).
  static void useDatabaseForTesting(Database? database) {
    _database = database;
  }

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    _database = await _initDB('agrofy.db');
    return _database!;
  }

  Future<Database> _initDB(String fileName) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, fileName);

    return await openDatabase(
      path,
      version: schemaVersion,
      onCreate: createSchema,
      onUpgrade: upgradeSchema,
    );
  }

  static Future<void> createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE fields (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        location TEXT NOT NULL,
        area REAL NOT NULL,
        crop TEXT NOT NULL,
        latitude REAL,
        longitude REAL,
        soil_type TEXT,
        soil_ph REAL,
        soil_moisture REAL,
        irrigation TEXT,
        elevation REAL
      )
    ''');

    await _createFieldEventsTable(db);
    await _createAdvisorTables(db);
    await _createSmallAiTables(db);
  }

  static Future<void> upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE fields ADD COLUMN latitude REAL',
      );
      await db.execute(
        'ALTER TABLE fields ADD COLUMN longitude REAL',
      );
      await db.execute(
        'ALTER TABLE fields ADD COLUMN soil_type TEXT',
      );
      await db.execute(
        'ALTER TABLE fields ADD COLUMN soil_ph REAL',
      );
      await db.execute(
        'ALTER TABLE fields ADD COLUMN soil_moisture REAL',
      );
      await db.execute(
        'ALTER TABLE fields ADD COLUMN irrigation TEXT',
      );
      await db.execute(
        'ALTER TABLE fields ADD COLUMN elevation REAL',
      );
    }

    if (oldVersion < 3) {
      await _createFieldEventsTable(db);
    }

    if (oldVersion < 4) {
      await _createAdvisorTables(db);
    }

    if (oldVersion < 5) {
      // Таблица crop_seasons до v5 не имела полей жизненного цикла.
      if (oldVersion == 4) {
        await _addLifecycleColumns(db);
      }
      await _createSmallAiTables(db);
    }
  }

  static Future<void> _addLifecycleColumns(Database db) async {
    await db.execute(
      "ALTER TABLE crop_seasons ADD COLUMN stage TEXT NOT NULL "
      "DEFAULT 'harvested'",
    );
    await db.execute('ALTER TABLE crop_seasons ADD COLUMN sown_at TEXT');
    await db.execute('ALTER TABLE crop_seasons ADD COLUMN harvested_at TEXT');
    await db.execute('ALTER TABLE crop_seasons ADD COLUMN yield_t_ha REAL');
  }

  /// Схема v5: история климата по годам (для модели типов лет)
  /// и рельеф участка.
  static Future<void> _createSmallAiTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS climate_history (
        field_id INTEGER PRIMARY KEY,
        payload TEXT NOT NULL,
        fetched_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS terrain_cache (
        field_id INTEGER PRIMARY KEY,
        elevation REAL NOT NULL,
        slope_percent REAL NOT NULL,
        fetched_at TEXT NOT NULL
      )
    ''');
  }

  /// Схема v4: история культур по участку, кэш климата NASA POWER
  /// и приоритеты фермера для советника по севообороту.
  static Future<void> _createAdvisorTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS crop_seasons (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        field_id INTEGER NOT NULL,
        year INTEGER NOT NULL,
        crop_id TEXT NOT NULL,
        stage TEXT NOT NULL DEFAULT 'harvested',
        sown_at TEXT,
        harvested_at TEXT,
        yield_t_ha REAL,
        note TEXT,
        UNIQUE (field_id, year),
        FOREIGN KEY (field_id)
          REFERENCES fields (id)
          ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS climate_cache (
        field_id INTEGER PRIMARY KEY,
        payload TEXT NOT NULL,
        fetched_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS advisor_settings (
        field_id INTEGER PRIMARY KEY,
        priorities TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _createFieldEventsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS field_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        field_id INTEGER NOT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        description TEXT NOT NULL,
        date TEXT NOT NULL,
        quantity REAL,
        unit TEXT,
        FOREIGN KEY (field_id)
          REFERENCES fields (id)
          ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_field_events_field_date
      ON field_events (field_id, date)
    ''');
  }

  // ----------------------------------------
  // FIELDS
  // ----------------------------------------

  Future<List<Field>> getFields() async {
    final db = await database;

    final result = await db.query(
      'fields',
      orderBy: 'id DESC',
    );

    return result.map((map) => Field.fromMap(map)).toList();
  }

  Future<int> insertField(Field field) async {
    final db = await database;

    final data = field.toMap()..remove('id');

    return await db.insert('fields', data);
  }

  Future<int> updateField(Field field) async {
    final db = await database;

    if (field.id == null) {
      throw ArgumentError(
        'Field ID cannot be null when updating',
      );
    }

    final data = field.toMap()..remove('id');

    return await db.update(
      'fields',
      data,
      where: 'id = ?',
      whereArgs: [field.id],
    );
  }

  Future<int> deleteField(int id) async {
    final db = await database;

    return await db.transaction((txn) async {
      for (final table in const [
        'field_events',
        'crop_seasons',
        'climate_cache',
        'advisor_settings',
        'climate_history',
        'terrain_cache',
      ]) {
        await txn.delete(
          table,
          where: 'field_id = ?',
          whereArgs: [id],
        );
      }

      return await txn.delete(
        'fields',
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  // ----------------------------------------
  // FIELD EVENTS
  // ----------------------------------------

  Future<List<FieldEvent>> getFieldEvents(int fieldId) async {
    final db = await database;

    final result = await db.query(
      'field_events',
      where: 'field_id = ?',
      whereArgs: [fieldId],
      orderBy: 'date DESC, id DESC',
    );

    return result.map((map) {
      return FieldEvent.fromMap(map);
    }).toList();
  }

  Future<int> insertFieldEvent(FieldEvent event) async {
    final db = await database;

    final data = event.toMap()..remove('id');

    return await db.insert(
      'field_events',
      data,
    );
  }

  Future<int> updateFieldEvent(FieldEvent event) async {
    final db = await database;

    if (event.id == null) {
      throw ArgumentError(
        'Event ID cannot be null when updating',
      );
    }

    final data = event.toMap()..remove('id');

    return await db.update(
      'field_events',
      data,
      where: 'id = ?',
      whereArgs: [event.id],
    );
  }

  Future<int> deleteFieldEvent(int id) async {
    final db = await database;

    return await db.delete(
      'field_events',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ----------------------------------------
  // ROTATION ADVISOR
  // ----------------------------------------

  /// История культур участка, от старых лет к новым.
  Future<List<CropSeason>> getCropSeasons(int fieldId) async {
    final db = await database;

    final result = await db.query(
      'crop_seasons',
      where: 'field_id = ?',
      whereArgs: [fieldId],
      orderBy: 'year ASC',
    );

    return result.map(CropSeason.fromMap).toList();
  }

  /// Сохраняет культуру года; запись за тот же год заменяется.
  Future<void> saveCropSeason(CropSeason season) async {
    final db = await database;

    await db.insert(
      'crop_seasons',
      season.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteCropSeason(int fieldId, int year) async {
    final db = await database;

    await db.delete(
      'crop_seasons',
      where: 'field_id = ? AND year = ?',
      whereArgs: [fieldId, year],
    );
  }

  Future<ClimateSummary?> getCachedClimate(int fieldId) async {
    final db = await database;

    final result = await db.query(
      'climate_cache',
      where: 'field_id = ?',
      whereArgs: [fieldId],
      limit: 1,
    );

    if (result.isEmpty) {
      return null;
    }

    try {
      return ClimateSummary.decode(result.first['payload'] as String);
    } on Object {
      // Повреждённый кэш не должен ломать офлайн-работу.
      return null;
    }
  }

  Future<void> saveClimate(int fieldId, ClimateSummary climate) async {
    final db = await database;

    await db.insert(
      'climate_cache',
      {
        'field_id': fieldId,
        'payload': climate.encode(),
        'fetched_at': climate.fetchedAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<FarmerPriorities> getPriorities(int fieldId) async {
    final db = await database;

    final result = await db.query(
      'advisor_settings',
      where: 'field_id = ?',
      whereArgs: [fieldId],
      limit: 1,
    );

    if (result.isEmpty) {
      return const FarmerPriorities();
    }

    try {
      return FarmerPriorities.decode(
        result.first['priorities'] as String,
      );
    } on Object {
      return const FarmerPriorities();
    }
  }

  Future<void> savePriorities(
    int fieldId,
    FarmerPriorities priorities,
  ) async {
    final db = await database;

    await db.insert(
      'advisor_settings',
      {
        'field_id': fieldId,
        'priorities': priorities.encode(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<ClimateHistory?> getClimateHistory(int fieldId) async {
    final db = await database;

    final result = await db.query(
      'climate_history',
      where: 'field_id = ?',
      whereArgs: [fieldId],
      limit: 1,
    );

    if (result.isEmpty) {
      return null;
    }

    try {
      return ClimateHistory.decode(result.first['payload'] as String);
    } on Object {
      return null;
    }
  }

  Future<void> saveClimateHistory(int fieldId, ClimateHistory history) async {
    final db = await database;

    await db.insert(
      'climate_history',
      {
        'field_id': fieldId,
        'payload': history.encode(),
        'fetched_at': history.fetchedAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<TerrainInfo?> getTerrain(int fieldId) async {
    final db = await database;

    final result = await db.query(
      'terrain_cache',
      where: 'field_id = ?',
      whereArgs: [fieldId],
      limit: 1,
    );

    return result.isEmpty ? null : TerrainInfo.fromMap(result.first);
  }

  Future<void> saveTerrain(int fieldId, TerrainInfo terrain) async {
    final db = await database;

    await db.insert(
      'terrain_cache',
      terrain.toMap(fieldId),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
