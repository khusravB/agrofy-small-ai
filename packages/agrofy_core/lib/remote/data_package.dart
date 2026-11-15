import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Пакет данных поля, который сервер AGROFY готовит по SMS-запросу,
/// а приложение импортирует. Формат JSON, схема 1.x.
///
/// Только реальные наблюдения из источников: пустой список — честное
/// «данных нет», а не повод подставить значения.
class DataPackage {
  static const String currentSchema = '1.0';
  static const String packageType = 'agrofy_field_data';

  /// Единицы, которые приложение умеет хранить без преобразования.
  static const Set<String> knownUnits = {'1', '°C', 'mm/day'};

  final String schemaVersion;
  final String requestId;
  final DateTime createdAt;
  final PackageField field;
  final DateTime periodStart;
  final DateTime periodEnd;
  final List<PackageDataset> datasets;
  final PackageQuality quality;

  const DataPackage({
    this.schemaVersion = currentSchema,
    required this.requestId,
    required this.createdAt,
    required this.field,
    required this.periodStart,
    required this.periodEnd,
    required this.datasets,
    required this.quality,
  });

  int get observationCount =>
      datasets.fold(0, (sum, d) => sum + d.observations.length);

  /// SHA-256 содержимого наборов данных — защита от порчи и подмены.
  String get checksum => sha256
      .convert(utf8.encode(jsonEncode(datasets.map((d) => d.toJson()).toList())))
      .toString();

  Map<String, dynamic> toJson() {
    return {
      'schema_version': schemaVersion,
      'package_type': packageType,
      'request_id': requestId,
      'created_at': createdAt.toUtc().toIso8601String(),
      'field': field.toJson(),
      'period': {
        'start': _date(periodStart),
        'end': _date(periodEnd),
      },
      'datasets': datasets.map((d) => d.toJson()).toList(),
      'quality': quality.toJson(),
      'checksum': {'algorithm': 'sha256', 'value': checksum},
    };
  }

  String encode() => const JsonEncoder.withIndent(' ').convert(toJson());

  static String _date(DateTime date) =>
      date.toIso8601String().substring(0, 10);
}

class PackageField {
  final String? fieldId;
  final double latitude;
  final double longitude;

  /// Как сервер понимает геометрию: точка — один пиксель MODIS около 250 м.
  final String geometryNote;

  const PackageField({
    this.fieldId,
    required this.latitude,
    required this.longitude,
    this.geometryNote = 'point',
  });

  Map<String, dynamic> toJson() => {
        'field_id': fieldId,
        'geometry': {
          'type': 'Point',
          'coordinates': [longitude, latitude],
        },
        'geometry_note': geometryNote,
      };
}

class PackageObservation {
  final DateTime date;
  final String variable;
  final double value;

  /// Качество наблюдения от источника (например, надёжность пикселя).
  final String? quality;

  const PackageObservation({
    required this.date,
    required this.variable,
    required this.value,
    this.quality,
  });

  Map<String, dynamic> toJson() => {
        'date': DataPackage._date(date),
        'variable': variable,
        'value': value,
        if (quality != null) 'quality': quality,
      };
}

class PackageDataset {
  final String source;
  final String product;
  final String provider;
  final String resolution;

  /// Переменная → единица измерения.
  final Map<String, String> units;

  final List<PackageObservation> observations;
  final List<String> notes;

  const PackageDataset({
    required this.source,
    required this.product,
    required this.provider,
    required this.resolution,
    required this.units,
    required this.observations,
    this.notes = const [],
  });

  Map<String, dynamic> toJson() => {
        'source': source,
        'product': product,
        'provider': provider,
        'resolution': resolution,
        'units': units,
        'observations': observations.map((o) => o.toJson()).toList(),
        'notes': notes,
      };
}

enum PackageStatus { ready, partial, unavailable }

class PackageQuality {
  final PackageStatus status;
  final List<String> missingData;
  final List<String> warnings;

  const PackageQuality({
    required this.status,
    this.missingData = const [],
    this.warnings = const [],
  });

  String get statusLabel => status.name.toUpperCase();

  Map<String, dynamic> toJson() => {
        'status': statusLabel,
        'missing_data': missingData,
        'warnings': warnings,
      };
}

/// Результат проверки пакета при импорте.
class PackageCheck {
  final DataPackage? package;
  final List<String> errors;
  final List<String> warnings;

  const PackageCheck({this.package, this.errors = const [], this.warnings = const []});

  bool get ok => package != null && errors.isEmpty;
}

/// Проверка пакета перед импортом: версия схемы, обязательные поля,
/// единицы, даты, значения и контрольная сумма. Наборы с неизвестными
/// единицами не принимаются.
class DataPackageReader {
  static PackageCheck read(String payload) {
    final errors = <String>[];
    final warnings = <String>[];

    Object? json;
    try {
      json = jsonDecode(payload);
    } on FormatException {
      return const PackageCheck(errors: ['Файл не является JSON.']);
    }
    if (json is! Map<String, dynamic>) {
      return const PackageCheck(errors: ['Неверная структура пакета.']);
    }

    final version = json['schema_version'];
    if (version is! String || !version.startsWith('1.')) {
      return PackageCheck(
        errors: ['Версия схемы «$version» не поддерживается (нужна 1.x).'],
      );
    }
    if (json['package_type'] != DataPackage.packageType) {
      return const PackageCheck(errors: ['Это не пакет данных поля AGROFY.']);
    }

    String? string(Map<String, dynamic> map, String key) {
      final value = map[key];
      if (value is String && value.isNotEmpty) {
        return value;
      }
      errors.add('Нет обязательного поля «$key».');
      return null;
    }

    DateTime? date(Object? value, String what) {
      final parsed = value is String ? DateTime.tryParse(value) : null;
      if (parsed == null) {
        errors.add('Неверная дата: $what.');
      }
      return parsed;
    }

    final requestId = string(json, 'request_id');
    final createdAt = date(json['created_at'], 'created_at');

    final fieldJson = json['field'];
    PackageField? field;
    if (fieldJson is Map<String, dynamic>) {
      final coordinates = (fieldJson['geometry'] as Map?)?['coordinates'];
      if (coordinates is List &&
          coordinates.length == 2 &&
          coordinates.every((c) => c is num)) {
        field = PackageField(
          fieldId: fieldJson['field_id'] as String?,
          longitude: (coordinates[0] as num).toDouble(),
          latitude: (coordinates[1] as num).toDouble(),
          geometryNote: fieldJson['geometry_note'] as String? ?? 'point',
        );
      } else {
        errors.add('Нет координат поля.');
      }
    } else {
      errors.add('Нет описания поля.');
    }

    final period = json['period'];
    final start = date(period is Map ? period['start'] : null, 'начало периода');
    final end = date(period is Map ? period['end'] : null, 'конец периода');

    final rawDatasets = json['datasets'];
    final datasets = <PackageDataset>[];
    if (rawDatasets is! List) {
      errors.add('Нет списка наборов данных.');
    } else {
      for (final raw in rawDatasets) {
        if (raw is! Map<String, dynamic>) {
          errors.add('Неверный набор данных.');
          continue;
        }
        final source = raw['source'];
        final units = raw['units'];
        if (source is! String || units is! Map) {
          errors.add('У набора данных нет источника или единиц.');
          continue;
        }
        final unknown = units.values
            .where((u) => !DataPackage.knownUnits.contains(u))
            .toList();
        if (unknown.isNotEmpty) {
          warnings.add(
            'Набор «$source» пропущен: неизвестные единицы ${unknown.join(', ')}.',
          );
          continue;
        }

        final observations = <PackageObservation>[];
        var rejected = 0;
        for (final item in (raw['observations'] as List? ?? const [])) {
          final when = item is Map ? DateTime.tryParse('${item['date']}') : null;
          final value = item is Map ? item['value'] : null;
          final variable = item is Map ? item['variable'] : null;
          if (when == null ||
              value is! num ||
              !value.isFinite ||
              variable is! String ||
              !units.containsKey(variable)) {
            rejected++;
            continue;
          }
          observations.add(
            PackageObservation(
              date: when,
              variable: variable,
              value: value.toDouble(),
              quality: item['quality'] as String?,
            ),
          );
        }
        if (rejected > 0) {
          warnings.add('«$source»: отброшено $rejected неверных наблюдений.');
        }

        datasets.add(
          PackageDataset(
            source: source,
            product: '${raw['product'] ?? ''}',
            provider: '${raw['provider'] ?? ''}',
            resolution: '${raw['resolution'] ?? ''}',
            units: units.map((k, v) => MapEntry('$k', '$v')),
            observations: observations,
            notes: [for (final n in (raw['notes'] as List? ?? const [])) '$n'],
          ),
        );
      }
    }

    final qualityJson = json['quality'];
    final statusName = qualityJson is Map ? '${qualityJson['status']}' : '';
    final status = PackageStatus.values.where(
      (s) => s.name.toUpperCase() == statusName,
    );
    if (status.isEmpty) {
      errors.add('Неизвестный статус качества «$statusName».');
    }

    if (errors.isNotEmpty) {
      return PackageCheck(errors: errors, warnings: warnings);
    }

    final package = DataPackage(
      schemaVersion: version,
      requestId: requestId!,
      createdAt: createdAt!,
      field: field!,
      periodStart: start!,
      periodEnd: end!,
      datasets: datasets,
      quality: PackageQuality(
        status: status.first,
        missingData: [
          for (final m in ((qualityJson as Map)['missing_data'] as List? ?? const []))
            '$m',
        ],
        warnings: [
          for (final w in (qualityJson['warnings'] as List? ?? const [])) '$w',
        ],
      ),
    );

    // Контрольную сумму сверяем, только если все наборы приняты: иначе
    // пересчёт по неполному списку не совпадёт по определению.
    final declared = (json['checksum'] as Map?)?['value'];
    if (declared is! String) {
      warnings.add('В пакете нет контрольной суммы — целостность не проверена.');
    } else if (warnings.every((w) => !w.contains('пропущен') && !w.contains('отброшено')) &&
        declared != package.checksum) {
      return PackageCheck(
        errors: ['Контрольная сумма не совпала — файл повреждён или изменён.'],
        warnings: warnings,
      );
    }

    return PackageCheck(package: package, warnings: warnings);
  }
}
