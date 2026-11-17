import 'dart:convert';

import 'package:agrofy_core/models/field.dart';
import 'package:agrofy_core/remote/data_package.dart';
import 'package:agrofy_core/remote/ndvi_summary.dart';
import 'package:agrofy_core/services/rotation_advisor.dart';
import 'package:agrofy_core/remote/field_code.dart';
import 'package:agrofy_small_ai/services/database_service.dart';
import 'package:agrofy_small_ai/services/field_code_importer.dart';
import 'package:agrofy_small_ai/services/package_importer.dart';
import 'package:agrofy_small_ai/services/sms_launcher.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sughd_region_test.dart' show khujandClimate, khujandCotton;

DataPackage package({
  String requestId = 'REQ-2026-000001',
  String? fieldId = 'F1',
  double latitude = 40.28,
  double longitude = 69.62,
  List<double> values = const [0.15, 0.62, 0.21],
}) {
  final dates = [DateTime.utc(2026, 3, 6), DateTime.utc(2026, 8, 13), DateTime.utc(2026, 9, 30)];
  return DataPackage(
    requestId: requestId,
    createdAt: DateTime.utc(2026, 11, 15),
    field: PackageField(fieldId: fieldId, latitude: latitude, longitude: longitude),
    periodStart: DateTime.utc(2026, 1, 1),
    periodEnd: DateTime.utc(2026, 11, 15),
    datasets: [
      PackageDataset(
        source: 'NASA_MODIS_MOD13Q1',
        product: '250m_16_days_NDVI',
        provider: 'ORNL DAAC',
        resolution: '250 m',
        units: const {'ndvi': '1'},
        observations: [
          for (var i = 0; i < values.length; i++)
            PackageObservation(date: dates[i], variable: 'ndvi', value: values[i], quality: 'good'),
        ],
      ),
    ],
    quality: const PackageQuality(status: PackageStatus.ready),
  );
}

const field = Field(
  id: 1,
  name: 'Участок',
  location: 'Худжанд',
  area: 2,
  crop: 'Хлопок',
  latitude: 40.28,
  longitude: 69.62,
);

void main() {
  sqfliteFfiInit();

  late Database db;
  late PackageImporter importer;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: DatabaseService.schemaVersion,
        onCreate: DatabaseService.createSchema,
        singleInstance: false,
      ),
    );
    DatabaseService.useDatabaseForTesting(db);
    await DatabaseService.instance.insertField(field);
    importer = PackageImporter(DatabaseService.instance);
  });

  tearDown(() async {
    await db.close();
    DatabaseService.useDatabaseForTesting(null);
  });

  List<int> bytes(DataPackage p) => utf8.encode(p.encode());

  group('Открытие SMS', () {
    test('iOS и Android получают разные разделители текста', () {
      expect(
        SmsLauncher.composeUri('+992 900 00-00-01', 'FIELD F1 NDVI 3M', ios: false).toString(),
        'sms:+992900000001?body=FIELD%20F1%20NDVI%203M',
      );
      expect(
        SmsLauncher.composeUri('+992900000001', 'Привет', ios: true).toString(),
        startsWith('sms:+992900000001&body=%D0%9F'),
      );
    });

    test('проверка номера', () {
      expect(SmsLauncher.validNumber('+992 900 00 00 01'), isTrue);
      expect(SmsLauncher.validNumber('1234'), isTrue);
      expect(SmsLauncher.validNumber('abc'), isFalse);
    });
  });

  group('Импорт пакета', () {
    test('новый пакет: сводка, сохранение и NDVI для советника', () async {
      final preview = await importer.previewBytes(bytes(package()), 'p.json', field);
      expect(preview.newCount, 3);
      expect(preview.fieldMismatch, isFalse);
      expect(preview.alreadyImported, isFalse);

      await importer.commit(preview, field, overwriteConflicts: false);
      final ndvi = await DatabaseService.instance.getNdvi(1);
      expect(ndvi.map((p) => p.value), [0.15, 0.62, 0.21]);
      expect((await DatabaseService.instance.getDataPackages(1)).single['status'], 'READY');
    });

    test('повторный импорт не создаёт дубликатов', () async {
      final first = await importer.previewBytes(bytes(package()), 'p.json', field);
      await importer.commit(first, field, overwriteConflicts: false);

      final again = await importer.previewBytes(bytes(package()), 'p.json', field);
      expect(again.alreadyImported, isTrue);
      expect(again.newCount, 0);
      expect(again.duplicateCount, 3);
      await importer.commit(again, field, overwriteConflicts: false);
      expect((await DatabaseService.instance.getNdvi(1)).length, 3);
    });

    test('отличающиеся значения не заменяются без подтверждения', () async {
      await importer.commit(
        await importer.previewBytes(bytes(package()), 'p.json', field),
        field,
        overwriteConflicts: false,
      );
      final changed = package(requestId: 'REQ-2', values: const [0.15, 0.70, 0.21]);

      final preview = await importer.previewBytes(bytes(changed), 'p.json', field);
      expect(preview.conflictCount, 1);
      await importer.commit(preview, field, overwriteConflicts: false);
      expect((await DatabaseService.instance.getNdvi(1))[1].value, 0.62);

      await importer.commit(preview, field, overwriteConflicts: true);
      expect((await DatabaseService.instance.getNdvi(1))[1].value, 0.70);
    });

    test('другое поле или далёкая точка — предупреждение', () async {
      final other = await importer.previewBytes(bytes(package(fieldId: 'F9')), 'p.json', field);
      expect(other.fieldMismatch, isTrue);
      expect(other.warnings.first, contains('F9'));

      final far = await importer.previewBytes(bytes(package(latitude: 40.5)), 'p.json', field);
      expect(far.fieldMismatch, isTrue);
      expect(far.warnings.first, contains('км'));
    });

    test('ZIP с манифестом читается, испорченный файл — нет', () async {
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('readme.txt', utf8.encode('x')))
        ..addFile(ArchiveFile.bytes('package.json', bytes(package())));
      final zip = ZipEncoder().encode(archive);

      final preview = await importer.previewBytes(zip, 'p.zip', field);
      expect(preview.newCount, 3);

      expect(
        () => importer.previewBytes(utf8.encode('{"broken": '), 'p.json', field),
        throwsA(isA<ImportFailure>()),
      );
      final tampered = package().encode().replaceFirst('"value": 0.62', '"value": 0.99');
      expect(
        () => importer.previewBytes(utf8.encode(tampered), 'p.json', field),
        throwsA(isA<ImportFailure>()),
      );
    });
  });

  group('NDVI в советнике', () {
    test('сводка: последний, максимум, месяцы без растительности', () {
      final summary = NdviSummary.of([
        NdviPoint(date: DateTime(2026, 3, 6), value: 0.15, quality: 'good'),
        NdviPoint(date: DateTime(2026, 8, 13), value: 0.62, quality: 'good'),
        NdviPoint(date: DateTime(2026, 9, 30), value: 0.21, quality: 'good'),
        NdviPoint(date: DateTime(2026, 10, 16), value: 0.05, quality: 'cloudy'),
      ])!;

      expect(summary.latest!.value, 0.21);
      expect(summary.peak!.value, 0.62);
      expect(summary.usableCount, 3);
      expect(summary.bareMonths, [2]);
      expect(summary.describe(), contains('не диагноз'));
    });

    test('импортированный NDVI появляется в наблюдениях советника', () {
      final result = const RotationAdvisor().advise(
        field: khujandCotton,
        historyCropIds: const [],
        climate: khujandClimate(),
        ndvi: [NdviPoint(date: DateTime(2026, 8, 13), value: 0.62, quality: 'good')],
      );

      expect(result.insights.last, contains('NDVI MODIS'));
    });
  });

  group('Код поля из SMS', () {
    FieldCode code({double latitude = 40.28, String crop = 'cotton', FarmerGoal goal = FarmerGoal.water}) =>
        FieldCode(
          fieldId: 'F1',
          latitude: latitude,
          longitude: 69.62,
          cropId: crop,
          goal: goal,
          climate: khujandClimate(),
          rotation: const ['cotton', 'chickpea', 'wheat'],
        );

    test('вставка сохраняет климат NASA и цель — советник считает без сети', () async {
      final importer = FieldCodeImporter(DatabaseService.instance);
      final sms = 'AGROFY прислал код:\n${code().encode()}';
      final preview = importer.preview(sms, field);
      expect(preview.warnings, isEmpty);
      expect(preview.rotationLabel, 'Хлопок → Нут → Пшеница озимая');

      await importer.apply(preview, field);
      final climate = await DatabaseService.instance.getCachedClimate(1);
      expect(climate, isNotNull);
      expect(climate!.annualPrecipMm, closeTo(khujandClimate().annualPrecipMm, 6));
      final priorities = await DatabaseService.instance.getPriorities(1);
      expect(priorities.water, 1.0);
      expect(priorities.income, 0.3);

      final result = const RotationAdvisor().advise(
        field: field,
        historyCropIds: const ['cotton'],
        climate: climate,
        priorities: priorities,
      );
      expect(result.blocker, isNull);
      expect(result.best, isNotNull);
    });

    test('чужая точка и другая культура — предупреждения', () {
      final importer = FieldCodeImporter(DatabaseService.instance);
      final preview = importer.preview(code(latitude: 41.0, crop: 'wheat').encode(), field);
      expect(preview.warnings.join(' '), contains('км от координат'));
      expect(preview.warnings.join(' '), contains('Пшеница'));
    });

    test('обрезанный код не принимается', () {
      final importer = FieldCodeImporter(DatabaseService.instance);
      final text = code().encode();
      expect(() => importer.preview(text.substring(0, text.length - 30), field), throwsFormatException);
    });
  });
}
