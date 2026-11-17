import 'package:agrofy_core/data/crop_catalog.dart';
import 'package:agrofy_core/models/field.dart';
import 'package:agrofy_core/remote/field_code.dart';

import 'database_service.dart';
import 'package_importer.dart' show PackageImporter;

/// Что получится при вставке кода — показывается до сохранения.
class FieldCodePreview {
  final FieldCode code;
  final List<String> warnings;

  const FieldCodePreview(this.code, this.warnings);

  /// Рекомендованный сервером севооборот названиями культур.
  String get rotationLabel => code.rotation
      .map((id) => CropCatalog.byId(id)?.name ?? id)
      .join(' → ');
}

/// Код поля из SMS (последнее сообщение ответа на INFO): климат NASA по
/// месяцам и цель фермера сохраняются в базу, и советник считает без
/// интернета.
class FieldCodeImporter {
  final DatabaseService db;

  FieldCodeImporter(this.db);

  /// Разбирает код в тексте. Бросает [FormatException] с понятной причиной.
  FieldCodePreview preview(String text, Field field) {
    final code = FieldCode.find(text);
    final warnings = <String>[];
    final lat = field.latitude;
    final lon = field.longitude;
    if (lat != null && lon != null) {
      final km = PackageImporter.distanceKm(lat, lon, code.latitude, code.longitude);
      if (km > 1) {
        warnings.add('Код для точки в ${km.toStringAsFixed(1)} км от координат участка «${field.name}».');
      }
    } else {
      warnings.add('У участка нет координат — проверьте, что код для него.');
    }
    final codeCrop = code.cropId == null ? null : CropCatalog.byId(code.cropId);
    final fieldCrop = CropCatalog.fromFieldCrop(field.crop);
    if (codeCrop != null && fieldCrop != null && codeCrop.id != fieldCrop.id) {
      warnings.add('В коде культура «${codeCrop.name}», а у участка — «${field.crop}».');
    }
    return FieldCodePreview(code, warnings);
  }

  Future<void> apply(FieldCodePreview preview, Field field) async {
    final code = preview.code;
    await db.saveClimate(field.id!, code.climate);
    final goal = code.goal;
    if (goal != null) {
      final current = await db.getPriorities(field.id!);
      await db.savePriorities(
        field.id!,
        goal.priorities(rotationYears: current.rotationYears),
      );
    }
  }
}
