import 'dart:convert';

import 'climate_summary.dart';

/// Один год наблюдений: 12 месячных значений, индекс 0 — январь.
class ClimateYear {
  final int year;
  final List<double> tMean;
  final List<double> tRange;
  final List<double> precipMm;
  final List<double> frostDays;
  final List<double>? rootWetness;

  const ClimateYear({
    required this.year,
    required this.tMean,
    required this.tRange,
    required this.precipMm,
    required this.frostDays,
    this.rootWetness,
  });

  Map<String, dynamic> toJson() {
    return {
      'year': year,
      'tMean': tMean,
      'tRange': tRange,
      'precipMm': precipMm,
      'frostDays': frostDays,
      'rootWetness': rootWetness,
    };
  }

  factory ClimateYear.fromJson(Map<String, dynamic> json) {
    List<double> list(String key) {
      return (json[key] as List).map((v) => (v as num).toDouble()).toList();
    }

    return ClimateYear(
      year: json['year'] as int,
      tMean: list('tMean'),
      tRange: list('tRange'),
      precipMm: list('precipMm'),
      frostDays: list('frostDays'),
      rootWetness: json['rootWetness'] == null ? null : list('rootWetness'),
    );
  }
}

/// Погодная история точки по годам (NASA POWER, помесячно).
///
/// На ней на устройстве обучается модель типов лет и считаются тренды.
class ClimateHistory {
  final double latitude;
  final double longitude;
  final List<ClimateYear> years;
  final DateTime fetchedAt;

  /// Средняя высота ячейки NASA POWER, м.
  final double? gridElevation;

  const ClimateHistory({
    required this.latitude,
    required this.longitude,
    required this.years,
    required this.fetchedAt,
    this.gridElevation,
  });

  int get firstYear => years.first.year;

  int get lastYear => years.last.year;

  /// Сводка одного года в том же виде, что и многолетняя климатология:
  /// так движок может «прожить» конкретный год.
  ClimateSummary summaryOf(Iterable<ClimateYear> selection, {String? label}) {
    final list = selection.toList();

    List<double> mean(List<double> Function(ClimateYear year) pick) {
      return List.generate(12, (month) {
        return list.map((y) => pick(y)[month]).reduce((a, b) => a + b) /
            list.length;
      });
    }

    final hasWetness = list.every((y) => y.rootWetness != null);

    return ClimateSummary(
      latitude: latitude,
      longitude: longitude,
      tMean: mean((y) => y.tMean),
      tRange: mean((y) => y.tRange),
      // Абсолютные максимумы по годам не запрашиваются: берём оценку
      // «средняя + размах», достаточную для предупреждения о жаре.
      tMaxExtreme: List.generate(12, (month) {
        return list
            .map((y) => y.tMean[month] + y.tRange[month])
            .reduce((a, b) => a > b ? a : b);
      }),
      precipMm: mean((y) => y.precipMm),
      frostDays: mean((y) => y.frostDays),
      rootWetness: hasWetness ? mean((y) => y.rootWetness!) : null,
      period: label ?? '$firstYear–$lastYear',
      fetchedAt: fetchedAt,
      gridElevation: gridElevation,
    );
  }

  /// Разбирает ответ NASA POWER Monthly API (ключи вида `202405`).
  factory ClimateHistory.fromPowerJson(
    Map<String, dynamic> json, {
    required double latitude,
    required double longitude,
    required DateTime fetchedAt,
  }) {
    final parameters = (json['properties'] as Map<String, dynamic>)['parameter']
        as Map<String, dynamic>;
    final header = json['header'] as Map<String, dynamic>?;
    final fill = (header?['fill_value'] as num?)?.toDouble() ?? -999.0;

    Map<String, dynamic> raw(String name) {
      final values = parameters[name] as Map<String, dynamic>?;
      if (values == null) {
        throw FormatException('NASA POWER: нет данных параметра $name');
      }
      return values;
    }

    final temperature = raw('T2M');
    final range = raw('T2M_RANGE');
    final precip = raw('PRECTOTCORR');
    final frost = raw('FROST_DAYS');
    final wetness = parameters['GWETROOT'] as Map<String, dynamic>?;

    final yearNumbers = temperature.keys
        .map((key) => int.parse(key.substring(0, 4)))
        .toSet()
        .toList()
      ..sort();

    List<double>? series(Map<String, dynamic>? source, int year) {
      if (source == null) {
        return null;
      }

      final values = <double>[];
      for (var month = 1; month <= 12; month++) {
        final key = '$year${month.toString().padLeft(2, '0')}';
        final value = (source[key] as num?)?.toDouble();
        if (value == null || value == fill) {
          return null;
        }
        values.add(value);
      }
      return values;
    }

    final years = <ClimateYear>[];
    for (final year in yearNumbers) {
      final t = series(temperature, year);
      final r = series(range, year);
      final p = series(precip, year);
      final f = series(frost, year);

      // Неполные годы (например, текущий) пропускаются.
      if (t == null || r == null || p == null || f == null) {
        continue;
      }

      years.add(
        ClimateYear(
          year: year,
          tMean: t,
          tRange: r,
          precipMm: List.generate(
            12,
            (month) => p[month] * ClimateSummary.daysInMonth[month],
          ),
          frostDays: f,
          rootWetness: series(wetness, year),
        ),
      );
    }

    if (years.length < 10) {
      throw const FormatException(
        'NASA POWER: слишком короткая история для анализа',
      );
    }

    return ClimateHistory(
      latitude: latitude,
      longitude: longitude,
      years: years,
      fetchedAt: fetchedAt,
      gridElevation: ClimateSummary.gridElevationOf(json),
    );
  }

  ClimateYear? yearOf(int year) {
    for (final item in years) {
      if (item.year == year) {
        return item;
      }
    }
    return null;
  }

  String encode() {
    return jsonEncode({
      'latitude': latitude,
      'longitude': longitude,
      'fetchedAt': fetchedAt.toIso8601String(),
      'gridElevation': gridElevation,
      'years': years.map((y) => y.toJson()).toList(),
    });
  }

  factory ClimateHistory.decode(String payload) {
    final json = jsonDecode(payload) as Map<String, dynamic>;

    return ClimateHistory(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      fetchedAt: DateTime.parse(json['fetchedAt'] as String),
      gridElevation: (json['gridElevation'] as num?)?.toDouble(),
      years: (json['years'] as List)
          .map((y) => ClimateYear.fromJson(y as Map<String, dynamic>))
          .toList(),
    );
  }
}
