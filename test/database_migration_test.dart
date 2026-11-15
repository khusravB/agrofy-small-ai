import 'package:agrofy_small_ai/models/climate_summary.dart';
import 'package:agrofy_small_ai/models/crop_season.dart';
import 'package:agrofy_small_ai/models/farmer_priorities.dart';
import 'package:agrofy_small_ai/models/field.dart';
import 'package:agrofy_small_ai/models/terrain_info.dart';
import 'package:agrofy_small_ai/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Схема версии 3 — в том виде, в каком она была до миграции.
Future<void> createV3(Database db, int version) async {
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
  await db.execute('''
    CREATE TABLE field_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      field_id INTEGER NOT NULL,
      type TEXT NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      date TEXT NOT NULL,
      quantity REAL,
      unit TEXT
    )
  ''');
}

Future<Set<String>> tableNames(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type = 'table'",
  );
  return rows.map((row) => row['name'] as String).toSet();
}

Future<Database> openCurrent(String path) {
  return databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: DatabaseService.schemaVersion,
      onCreate: DatabaseService.createSchema,
      onUpgrade: DatabaseService.upgradeSchema,
    ),
  );
}

void main() {
  sqfliteFfiInit();

  const advisorTables = {
    'crop_seasons',
    'climate_cache',
    'advisor_settings',
    'climate_history',
    'terrain_cache',
    'observations',
  };

  tearDown(() => DatabaseService.useDatabaseForTesting(null));

  test('чистая установка создаёт схему версии 6', () async {
    final db = await openCurrent(inMemoryDatabasePath);

    expect(await db.getVersion(), 6);
    expect(
      await tableNames(db),
      containsAll({'fields', 'field_events', ...advisorTables}),
    );

    await db.close();
  });

  test('обновление с версии 3 сохраняет данные и добавляет таблицы',
      () async {
    final path = '${await databaseFactoryFfi.getDatabasesPath()}/'
        'agrofy_migration_test.db';
    await databaseFactoryFfi.deleteDatabase(path);

    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 3, onCreate: createV3),
    );
    await old.insert('fields', {
      'name': 'Старое поле',
      'location': 'Тест',
      'area': 4.5,
      'crop': 'Хлопок',
    });
    await old.insert('field_events', {
      'field_id': 1,
      'type': 'planting',
      'title': 'Посев',
      'description': 'до миграции',
      'date': '2026-04-01T00:00:00.000',
    });
    await old.close();

    final upgraded = await openCurrent(path);

    expect(await upgraded.getVersion(), 6);
    expect(await tableNames(upgraded), containsAll(advisorTables));

    final fields = await upgraded.query('fields');
    expect(fields.single['name'], 'Старое поле');
    expect(fields.single['area'], 4.5);
    expect((await upgraded.query('field_events')).single['title'], 'Посев');
    await upgraded.close();

    // Повторный запуск: миграция не выполняется второй раз, данные на месте.
    final reopened = await openCurrent(path);
    expect(await reopened.getVersion(), 6);
    expect((await reopened.query('fields')).length, 1);
    await reopened.close();

    await databaseFactoryFfi.deleteDatabase(path);
  });

  test('обновление с версии 4 сохраняет историю культур', () async {
    final path = '${await databaseFactoryFfi.getDatabasesPath()}/'
        'agrofy_migration_v4_test.db';
    await databaseFactoryFfi.deleteDatabase(path);

    // Схема версии 4: crop_seasons без полей жизненного цикла.
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, version) async {
          await createV3(db, version);
          await db.execute('''
            CREATE TABLE crop_seasons (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              field_id INTEGER NOT NULL,
              year INTEGER NOT NULL,
              crop_id TEXT NOT NULL,
              note TEXT,
              UNIQUE (field_id, year)
            )
          ''');
          await db.execute(
            'CREATE TABLE climate_cache (field_id INTEGER PRIMARY KEY, '
            'payload TEXT NOT NULL, fetched_at TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE advisor_settings (field_id INTEGER PRIMARY KEY, '
            'priorities TEXT NOT NULL)',
          );
        },
      ),
    );
    await old.insert('crop_seasons', {
      'field_id': 1,
      'year': 2025,
      'crop_id': 'cotton',
    });
    await old.close();

    final upgraded = await openCurrent(path);
    DatabaseService.useDatabaseForTesting(upgraded);

    expect(await upgraded.getVersion(), 6);
    expect(await tableNames(upgraded), containsAll(advisorTables));

    final seasons = await DatabaseService.instance.getCropSeasons(1);
    expect(seasons.single.cropId, 'cotton');
    expect(seasons.single.stage, CropStage.completed);

    await DatabaseService.instance.saveCropSeason(
      seasons.single.copyWith(stage: CropStage.vegetative, yieldTHa: 3.2),
    );
    final updated = await DatabaseService.instance.getCropSeasons(1);
    expect(updated.single.stage, CropStage.vegetative);
    expect(updated.single.yieldTHa, 3.2);

    await upgraded.close();
    await databaseFactoryFfi.deleteDatabase(path);
  });

  test('данные советника сохраняются и удаляются вместе с участком',
      () async {
    final db = await openCurrent(inMemoryDatabasePath);
    DatabaseService.useDatabaseForTesting(db);
    final service = DatabaseService.instance;

    final fieldId = await service.insertField(
      const Field(name: 'Поле', location: 'Тест', area: 1, crop: 'Хлопок'),
    );

    await service.saveCropSeason(
      CropSeason(fieldId: fieldId, year: 2025, cropId: 'cotton'),
    );
    await service.saveCropSeason(
      CropSeason(fieldId: fieldId, year: 2024, cropId: 'wheat'),
    );
    // Запись за тот же год заменяется, а не дублируется.
    await service.saveCropSeason(
      CropSeason(fieldId: fieldId, year: 2025, cropId: 'mung'),
    );

    final seasons = await service.getCropSeasons(fieldId);
    expect(seasons.map((s) => s.cropId), ['wheat', 'mung']);

    expect(await service.getCachedClimate(fieldId), isNull);
    final climate = ClimateSummary(
      latitude: 40,
      longitude: 70,
      tMean: List.filled(12, 15),
      tRange: List.filled(12, 10),
      tMaxExtreme: List.filled(12, 30),
      precipMm: List.filled(12, 20),
      frostDays: List.filled(12, 0),
      period: 'test',
      fetchedAt: DateTime(2026, 11, 15),
    );
    await service.saveClimate(fieldId, climate);
    expect((await service.getCachedClimate(fieldId))!.precipMm[3], 20);

    expect((await service.getPriorities(fieldId)).water, 0.5);
    await service.savePriorities(
      fieldId,
      const FarmerPriorities(water: 0.9),
    );
    expect((await service.getPriorities(fieldId)).water, 0.9);

    await service.saveTerrain(
      fieldId,
      TerrainInfo(
        elevation: 340,
        slopePercent: 6.5,
        fetchedAt: DateTime(2026, 11, 15),
      ),
    );
    expect((await service.getTerrain(fieldId))!.slopePercent, 6.5);

    await service.deleteField(fieldId);
    expect(await service.getTerrain(fieldId), isNull);
    expect(await service.getCropSeasons(fieldId), isEmpty);
    expect(await service.getCachedClimate(fieldId), isNull);
    expect((await service.getPriorities(fieldId)).water, 0.5);

    await db.close();
  });
}
