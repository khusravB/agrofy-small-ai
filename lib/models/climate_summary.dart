import 'dart:convert';
import 'dart:math' as math;

/// Многолетняя помесячная климатическая сводка для точки (NASA POWER).
///
/// Все списки содержат 12 значений, индекс 0 — январь.
class ClimateSummary {
  static const List<int> daysInMonth = [
    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, //
  ];

  static const List<String> monthNames = [
    'янв', 'фев', 'мар', 'апр', 'май', 'июн', //
    'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
  ];

  final double latitude;
  final double longitude;

  /// Средняя температура воздуха, °C.
  final List<double> tMean;

  /// Средний суточный размах температуры, °C.
  final List<double> tRange;

  /// Абсолютный максимум температуры за период, °C.
  final List<double> tMaxExtreme;

  /// Осадки, мм в месяц.
  final List<double> precipMm;

  /// Среднее число дней с заморозками.
  final List<double> frostDays;

  /// Влажность корнеобитаемого слоя, 0–1. Может отсутствовать.
  final List<double>? rootWetness;

  /// Период климатологии, как его описывает источник.
  final String period;

  final DateTime fetchedAt;

  const ClimateSummary({
    required this.latitude,
    required this.longitude,
    required this.tMean,
    required this.tRange,
    required this.tMaxExtreme,
    required this.precipMm,
    required this.frostDays,
    this.rootWetness,
    required this.period,
    required this.fetchedAt,
  });

  double get annualPrecipMm => precipMm.reduce((a, b) => a + b);

  double get annualEt0Mm => et0Mm.reduce((a, b) => a + b);

  double get annualFrostDays => frostDays.reduce((a, b) => a + b);

  /// Эталонное испарение ET0, мм в месяц, по формуле Харгривса:
  /// считается на устройстве из температуры и широты.
  List<double> get et0Mm {
    return List.generate(12, (month) {
      final ra = _extraterrestrialRadiationMm(month);
      final range = math.max(tRange[month], 0.0);
      final perDay =
          0.0023 * (tMean[month] + 17.8) * math.sqrt(range) * ra;
      return math.max(perDay, 0.0) * daysInMonth[month];
    });
  }

  /// Внеземная радиация в эквиваленте испарения, мм/сутки (FAO-56).
  double _extraterrestrialRadiationMm(int month) {
    const midMonthDay = [
      15, 46, 75, 105, 135, 162, 198, 228, 258, 288, 318, 344, //
    ];

    final day = midMonthDay[month];
    final phi = latitude * math.pi / 180;
    final dr = 1 + 0.033 * math.cos(2 * math.pi * day / 365);
    final delta = 0.409 * math.sin(2 * math.pi * day / 365 - 1.39);
    final x = (-math.tan(phi) * math.tan(delta)).clamp(-1.0, 1.0);
    final ws = math.acos(x);

    final raMj = (24 * 60 / math.pi) *
        0.0820 *
        dr *
        (ws * math.sin(phi) * math.sin(delta) +
            math.cos(phi) * math.cos(delta) * math.sin(ws));

    return math.max(raMj, 0.0) * 0.408;
  }

  /// Сценарий «что если»: осадки умножаются на [rainFactor],
  /// температура сдвигается на [tempDelta] °C.
  ClimateSummary adjusted({
    double rainFactor = 1.0,
    double tempDelta = 0.0,
  }) {
    if (rainFactor == 1.0 && tempDelta == 0.0) {
      return this;
    }

    return ClimateSummary(
      latitude: latitude,
      longitude: longitude,
      tMean: tMean.map((t) => t + tempDelta).toList(),
      tRange: tRange,
      tMaxExtreme: tMaxExtreme.map((t) => t + tempDelta).toList(),
      precipMm: precipMm.map((p) => p * rainFactor).toList(),
      // Грубая поправка: потепление на 1 °C убирает около 15% дней
      // с заморозками. Это допущение сценария, а не прогноз.
      frostDays: frostDays
          .map((d) => math.max(d * (1 - 0.15 * tempDelta), 0.0))
          .toList(),
      rootWetness: rootWetness,
      period: period,
      fetchedAt: fetchedAt,
    );
  }

  /// Разбирает ответ NASA POWER Climatology API.
  factory ClimateSummary.fromPowerJson(
    Map<String, dynamic> json, {
    required double latitude,
    required double longitude,
    required DateTime fetchedAt,
  }) {
    const keys = [
      'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', //
      'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
    ];

    final parameters = (json['properties'] as Map<String, dynamic>)['parameter']
        as Map<String, dynamic>;
    final header = json['header'] as Map<String, dynamic>?;
    final fill = (header?['fill_value'] as num?)?.toDouble() ?? -999.0;

    List<double>? series(String name) {
      final raw = parameters[name] as Map<String, dynamic>?;
      if (raw == null) {
        return null;
      }

      final values = <double>[];
      for (final key in keys) {
        final value = (raw[key] as num?)?.toDouble();
        if (value == null || value == fill) {
          return null;
        }
        values.add(value);
      }
      return values;
    }

    List<double> required(String name) {
      final values = series(name);
      if (values == null) {
        throw FormatException('NASA POWER: нет данных параметра $name');
      }
      return values;
    }

    final precipPerDay = required('PRECTOTCORR');

    return ClimateSummary(
      latitude: latitude,
      longitude: longitude,
      tMean: required('T2M'),
      tRange: required('T2M_RANGE'),
      tMaxExtreme: required('T2M_MAX'),
      precipMm: List.generate(
        12,
        (month) => precipPerDay[month] * daysInMonth[month],
      ),
      frostDays: required('FROST_DAYS'),
      rootWetness: series('GWETROOT'),
      period: header?['range'] as String? ?? '',
      fetchedAt: fetchedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'tMean': tMean,
      'tRange': tRange,
      'tMaxExtreme': tMaxExtreme,
      'precipMm': precipMm,
      'frostDays': frostDays,
      'rootWetness': rootWetness,
      'period': period,
      'fetchedAt': fetchedAt.toIso8601String(),
    };
  }

  factory ClimateSummary.fromJson(Map<String, dynamic> json) {
    List<double> list(String key) {
      return (json[key] as List).map((v) => (v as num).toDouble()).toList();
    }

    return ClimateSummary(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      tMean: list('tMean'),
      tRange: list('tRange'),
      tMaxExtreme: list('tMaxExtreme'),
      precipMm: list('precipMm'),
      frostDays: list('frostDays'),
      rootWetness: json['rootWetness'] == null ? null : list('rootWetness'),
      period: json['period'] as String? ?? '',
      fetchedAt: DateTime.parse(json['fetchedAt'] as String),
    );
  }

  String encode() => jsonEncode(toJson());

  factory ClimateSummary.decode(String payload) {
    return ClimateSummary.fromJson(
      jsonDecode(payload) as Map<String, dynamic>,
    );
  }
}
