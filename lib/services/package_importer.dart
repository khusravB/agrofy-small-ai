import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agrofy_core/models/field.dart';
import 'package:agrofy_core/remote/data_package.dart';
import 'package:agrofy_core/remote/sms_command.dart';
import 'package:archive/archive.dart';

import 'database_service.dart';

/// Что произойдёт при импорте — показывается пользователю до сохранения.
class ImportPreview {
  final DataPackage package;
  final List<String> warnings;
  final bool alreadyImported;
  final int newCount;
  final int duplicateCount;
  final int conflictCount;

  /// Сколько первых предупреждений — о несовпадении поля или координат.
  final int mismatchWarnings;

  /// Пакет относится к другому полю или точка далеко от участка.
  bool get fieldMismatch => mismatchWarnings > 0;

  const ImportPreview({
    required this.package,
    required this.warnings,
    required this.alreadyImported,
    required this.newCount,
    required this.duplicateCount,
    required this.conflictCount,
    required this.mismatchWarnings,
  });
}

class ImportFailure implements Exception {
  final List<String> errors;
  const ImportFailure(this.errors);
}

/// Импортёр пакетов данных (JSON или ZIP с JSON-манифестом). Файл проверяет
/// [DataPackageReader]; здесь — привязка к полю и сверка с уже сохранённым.
class PackageImporter {
  static const int maxBytes = 20 * 1024 * 1024;

  final DatabaseService db;

  PackageImporter(this.db);

  /// Содержимое JSON из файла: сам JSON или манифест из ZIP.
  static String readPayload(List<int> bytes, String name) {
    if (bytes.length > maxBytes) {
      throw const ImportFailure(['Файл больше 20 МБ.']);
    }
    final isZip = name.toLowerCase().endsWith('.zip') ||
        (bytes.length > 3 && bytes[0] == 0x50 && bytes[1] == 0x4B);
    if (!isZip) {
      return utf8.decode(bytes, allowMalformed: false);
    }

    final archive = ZipDecoder().decodeBytes(bytes);
    final candidates = [
      for (final file in archive.files)
        if (file.isFile && file.name.toLowerCase().endsWith('.json')) file,
    ];
    if (candidates.isEmpty) {
      throw const ImportFailure(['В архиве нет JSON-манифеста.']);
    }
    candidates.sort((a, b) {
      int rank(ArchiveFile f) {
        final n = f.name.toLowerCase();
        return n.endsWith('manifest.json') || n.endsWith('package.json') ? 0 : 1;
      }

      return rank(a).compareTo(rank(b));
    });
    return utf8.decode(candidates.first.content);
  }

  /// Расстояние между точками, км.
  static double distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1);
    final dLon = rad(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
    return 2 * r * math.asin(math.sqrt(a));
  }

  Future<ImportPreview> preview(File file, Field field) async {
    final bytes = await file.readAsBytes();
    return previewBytes(bytes, file.path, field);
  }

  Future<ImportPreview> previewBytes(List<int> bytes, String name, Field field) async {
    final String payload;
    try {
      payload = readPayload(bytes, name);
    } on ImportFailure {
      rethrow;
    } on Object {
      throw const ImportFailure(['Файл не удалось прочитать как JSON или ZIP.']);
    }

    final check = DataPackageReader.read(payload);
    if (!check.ok) {
      throw ImportFailure(check.errors);
    }
    final package = check.package!;
    final warnings = [
      ...check.warnings,
      ...package.quality.missingData,
      ...package.quality.warnings,
    ];

    var mismatch = 0;
    final expectedId = SmsCommand.fieldIdForLocal(field.id!);
    final packageId = package.field.fieldId;
    if (packageId != null && packageId != expectedId) {
      mismatch++;
      warnings.insert(
        0,
        'Пакет для поля $packageId, а выбран участок «${field.name}» ($expectedId).',
      );
    }
    final lat = field.latitude;
    final lon = field.longitude;
    if (lat != null && lon != null) {
      final km = distanceKm(lat, lon, package.field.latitude, package.field.longitude);
      if (km > 1) {
        mismatch++;
        warnings.insert(
          0,
          'Точка пакета в ${km.toStringAsFixed(1)} км от координат участка.',
        );
      }
    }

    final existing = await db.remoteObservationIndex(field.id!);
    var fresh = 0;
    var duplicates = 0;
    var conflicts = 0;
    for (final dataset in package.datasets) {
      for (final o in dataset.observations) {
        final key = '${dataset.source}|${o.variable}|'
            '${o.date.toIso8601String().substring(0, 10)}';
        final old = existing[key];
        if (old == null) {
          fresh++;
        } else if ((old - o.value).abs() < 1e-9) {
          duplicates++;
        } else {
          conflicts++;
        }
      }
    }

    return ImportPreview(
      package: package,
      warnings: warnings,
      alreadyImported: await db.hasDataPackage(package.requestId),
      newCount: fresh,
      duplicateCount: duplicates,
      conflictCount: conflicts,
      mismatchWarnings: mismatch,
    );
  }

  Future<void> commit(
    ImportPreview preview,
    Field field, {
    required bool overwriteConflicts,
  }) {
    return db.importDataPackage(
      field.id!,
      preview.package,
      overwriteConflicts: overwriteConflicts,
      importedAt: DateTime.now(),
    );
  }
}
