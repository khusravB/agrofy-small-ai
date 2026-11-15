import 'dart:convert';
import 'dart:math' as math;

import 'climate_summary.dart';
import 'crop_profile.dart';

/// Суточная история NASA POWER: минимальная и средняя температура по дням
/// за много лет. Из неё считаются даты заморозков с вероятностью и сроки
/// посева с точностью до декады.
///
/// День года — от 0 (1 января) до 364; 29 февраля пропускается.
class DailyClimate {
  static const int daysInYear = 365;

  /// Весенний заморозок ищется до конца июня, осенний — с июля.
  static const int midYear = 181;

  static const List<String> _monthsGenitive = [
    'января', 'февраля', 'марта', 'апреля', 'мая', 'июня', //
    'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
  ];

  final double latitude;
  final double longitude;
  final double? gridElevation;
  final DateTime fetchedAt;

  /// Год → 365 значений.
  final Map<int, List<double>> tMin;
  final Map<int, List<double>> tMean;

  /// Поправка температуры, °C (высота поля, сценарий). Применяется при
  /// расчётах, исходные данные не меняются.
  final double tempDelta;

  const DailyClimate({
    required this.latitude,
    required this.longitude,
    required this.tMin,
    required this.tMean,
    required this.fetchedAt,
    this.gridElevation,
    this.tempDelta = 0,
  });

  List<int> get years => tMin.keys.toList()..sort();

  int get firstYear => years.first;

  int get lastYear => years.last;

  DailyClimate withTempDelta(double delta) {
    if (delta == 0) {
      return this;
    }
    return DailyClimate(
      latitude: latitude,
      longitude: longitude,
      tMin: tMin,
      tMean: tMean,
      fetchedAt: fetchedAt,
      gridElevation: gridElevation,
      tempDelta: tempDelta + delta,
    );
  }

  bool _frost(int year, int day) => tMin[year]![day] + tempDelta <= 0;

  /// Последний день с заморозком весной (до июля); −1 — заморозков не было.
  int lastSpringFrost(int year) {
    for (var day = midYear; day >= 0; day--) {
      if (_frost(year, day)) {
        return day;
      }
    }
    return -1;
  }

  /// Первый день с заморозком осенью (с июля); 365 — заморозков не было.
  int firstAutumnFrost(int year) {
    for (var day = midYear + 1; day < daysInYear; day++) {
      if (_frost(year, day)) {
        return day;
      }
    }
    return daysInYear;
  }

  static int _quantile(List<int> values, double q) {
    final sorted = [...values]..sort();
    final index = ((sorted.length - 1) * q).round();
    return sorted[index.clamp(0, sorted.length - 1)];
  }

  /// День, после которого весенний заморозок случался не чаще чем в
  /// [risk] доле лет. −1 — весенних заморозков практически не бывает.
  int springFrostSafeDay({double risk = 0.1}) {
    final days = years.map(lastSpringFrost).toList();
    return _quantile(days, 1 - risk);
  }

  /// Обычная (медианная) дата последнего весеннего заморозка.
  int typicalLastSpringFrost() =>
      _quantile(years.map(lastSpringFrost).toList(), 0.5);

  /// День, до которого осенний заморозок случался не чаще чем в [risk]
  /// доле лет.
  int autumnFrostSafeDay({double risk = 0.1}) =>
      _quantile(years.map(firstAutumnFrost).toList(), risk);

  int typicalFirstAutumnFrost() =>
      _quantile(years.map(firstAutumnFrost).toList(), 0.5);

  /// Медианная длина безморозного периода, дней.
  int frostFreeDays() {
    final lengths = [
      for (final year in years) firstAutumnFrost(year) - lastSpringFrost(year) - 1,
    ];
    return _quantile(lengths, 0.5);
  }

  /// Многолетняя норма среднесуточной температуры по дням, сглаженная
  /// скользящим средним за 15 дней.
  List<double> normalMean() {
    final raw = List.generate(daysInYear, (day) {
      var sum = 0.0;
      for (final values in tMean.values) {
        sum += values[day];
      }
      return sum / tMean.length + tempDelta;
    });

    const half = 7;
    return List.generate(daysInYear, (day) {
      var sum = 0.0;
      for (var offset = -half; offset <= half; offset++) {
        sum += raw[(day + offset) % daysInYear];
      }
      return sum / (2 * half + 1);
    });
  }

  static DateTime dateOf(int day) => DateTime(2025).add(Duration(days: day));

  static String formatDay(int day) {
    final date = dateOf(day.clamp(0, daysInYear - 1));
    return '${date.day} ${_monthsGenitive[date.month - 1]}';
  }

  static String decadeOf(int day) {
    final date = dateOf(day.clamp(0, daysInYear - 1));
    final decade = date.day <= 10
        ? 1
        : date.day <= 20
            ? 2
            : 3;
    return '$decade-я декада ${_monthsGenitive[date.month - 1]}';
  }

  static int _firstDayOfMonth(int month) {
    var day = 0;
    for (var m = 0; m < month; m++) {
      day += ClimateSummary.daysInMonth[m];
    }
    return day;
  }

  /// Уточняет срок посева культуры до декады.
  ///
  /// Яровые: первый день вокруг выбранного месяца, когда норма
  /// среднесуточной температуры достигает минимума культуры и (для
  /// теплолюбивых) риск весеннего заморозка не выше 10%.
  /// Озимые: осенний день, когда норма опускается до середины их
  /// температурного диапазона. Правила упрощённые, сроки — ориентир.
  SowingWindow? sowingWindow(CropProfile crop, int startMonth) {
    final normals = normalMean();
    final monthStart = _firstDayOfMonth(startMonth);

    if (crop.overwinters) {
      final target = (crop.tMin + crop.tMax) / 2;
      for (var day = 213; day < daysInYear; day++) {
        if (normals[day] <= target) {
          return SowingWindow(
            day: day,
            reason: 'норма среднесуточной температуры опускается до '
                '${target.round()} °C',
          );
        }
      }
      return null;
    }

    // Посев позже середины лета (повторные, покровные) — по месяцу.
    if (startMonth > 6) {
      return null;
    }

    final frostSafe = crop.frostTolerant ? -1 : springFrostSafeDay();
    final from = math.max(monthStart - 30, 0);
    final to = math.min(monthStart + ClimateSummary.daysInMonth[startMonth] + 30,
        daysInYear - 1);

    for (var day = from; day <= to; day++) {
      if (normals[day] >= crop.tMin && day > frostSafe) {
        final reasons = [
          'норма среднесуточной температуры достигает ${crop.tMin.round()} °C',
          if (!crop.frostTolerant && frostSafe >= 0)
            'риск заморозка после ${formatDay(frostSafe)} — не выше 10%',
        ];
        return SowingWindow(day: day, reason: reasons.join('; '));
      }
    }
    return null;
  }

  // ----------------------------------------
  // Хранение
  // ----------------------------------------

  /// Разбирает ответ NASA POWER Daily API (ключи вида `20240315`).
  factory DailyClimate.fromPowerJson(
    Map<String, dynamic> json, {
    required double latitude,
    required double longitude,
    required DateTime fetchedAt,
  }) {
    final parameters = (json['properties'] as Map<String, dynamic>)['parameter']
        as Map<String, dynamic>;
    final header = json['header'] as Map<String, dynamic>?;
    final fill = (header?['fill_value'] as num?)?.toDouble() ?? -999.0;

    final minRaw = parameters['T2M_MIN'] as Map<String, dynamic>?;
    final meanRaw = parameters['T2M'] as Map<String, dynamic>?;
    if (minRaw == null || meanRaw == null) {
      throw const FormatException('NASA POWER: нет суточных температур');
    }

    final tMin = <int, List<double>>{};
    final tMean = <int, List<double>>{};
    final byYear = <int, List<String>>{};

    for (final key in minRaw.keys) {
      if (key.length != 8 || key.endsWith('0229')) {
        continue;
      }
      byYear.putIfAbsent(int.parse(key.substring(0, 4)), () => []).add(key);
    }

    byYear.forEach((year, keys) {
      if (keys.length != daysInYear) {
        return;
      }
      keys.sort();
      final mins = <double>[];
      final means = <double>[];
      for (final key in keys) {
        final low = (minRaw[key] as num?)?.toDouble();
        final mean = (meanRaw[key] as num?)?.toDouble();
        if (low == null || mean == null || low == fill || mean == fill) {
          return;
        }
        mins.add(low);
        means.add(mean);
      }
      tMin[year] = mins;
      tMean[year] = means;
    });

    if (tMin.length < 10) {
      throw const FormatException(
        'NASA POWER: слишком короткая суточная история',
      );
    }

    return DailyClimate(
      latitude: latitude,
      longitude: longitude,
      tMin: tMin,
      tMean: tMean,
      fetchedAt: fetchedAt,
      gridElevation: ClimateSummary.gridElevationOf(json),
    );
  }

  String encode() {
    List<num> round(List<double> values) =>
        values.map((v) => (v * 10).round() / 10).toList();

    return jsonEncode({
      'latitude': latitude,
      'longitude': longitude,
      'gridElevation': gridElevation,
      'fetchedAt': fetchedAt.toIso8601String(),
      'tMin': {for (final e in tMin.entries) '${e.key}': round(e.value)},
      'tMean': {for (final e in tMean.entries) '${e.key}': round(e.value)},
    });
  }

  factory DailyClimate.decode(String payload) {
    final json = jsonDecode(payload) as Map<String, dynamic>;

    Map<int, List<double>> series(String key) {
      return {
        for (final e in (json[key] as Map<String, dynamic>).entries)
          int.parse(e.key):
              (e.value as List).map((v) => (v as num).toDouble()).toList(),
      };
    }

    return DailyClimate(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      gridElevation: (json['gridElevation'] as num?)?.toDouble(),
      fetchedAt: DateTime.parse(json['fetchedAt'] as String),
      tMin: series('tMin'),
      tMean: series('tMean'),
    );
  }
}

/// Рекомендуемое начало посева и правило, по которому оно найдено.
class SowingWindow {
  final int day;
  final String reason;

  const SowingWindow({required this.day, required this.reason});

  String get decade => DailyClimate.decadeOf(day);
}
