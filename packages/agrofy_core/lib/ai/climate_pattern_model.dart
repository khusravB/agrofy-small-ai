import 'dart:math' as math;

import '../models/climate_history.dart';
import '../models/climate_summary.dart';

enum YearKind { dry, normal, wet }

/// Тип года, найденный моделью: группа похожих лет и их «средний» климат.
class YearType {
  final YearKind kind;
  final List<int> years;

  /// Доля таких лет за всю историю и за последние 10 лет, 0–1.
  final double share;
  final double recentShare;

  /// Средний климат лет этого типа — на нём проверяются севообороты.
  final ClimateSummary climate;

  /// Агрономический критерий: отношение осадков к испаряемости (P/ET0)
  /// за тёплый сезон, в среднем по годам этого типа.
  final double seasonAridity;

  const YearType({
    required this.kind,
    required this.years,
    required this.share,
    required this.recentShare,
    required this.climate,
    this.seasonAridity = 0,
  });

  YearType withClimate(ClimateSummary value) {
    return YearType(
      kind: kind,
      years: years,
      share: share,
      recentShare: recentShare,
      climate: value,
      seasonAridity: seasonAridity,
    );
  }

  /// Класс сухости по индексу UNEP (P/ET0), применённому к тёплому сезону.
  String get aridityClass => ClimatePatterns.aridityClassOf(seasonAridity);

  String get label {
    switch (kind) {
      case YearKind.dry:
        return 'Засушливый год';
      case YearKind.normal:
        return 'Обычный год';
      case YearKind.wet:
        return 'Влажный год';
    }
  }

  /// Вес типа года в итоговой оценке: история и последние годы поровну.
  double get weight => 0.5 * share + 0.5 * recentShare;
}

/// Многолетний тренд показателя.
class ClimateTrend {
  final String name;
  final String unit;

  /// Изменение за 10 лет (оценка Тейла — Сена).
  final double perDecade;

  /// Тренд статистически значим (критерий Манна — Кендалла, 95%).
  final bool significant;

  const ClimateTrend({
    required this.name,
    required this.unit,
    required this.perDecade,
    required this.significant,
  });

  String describe() {
    final sign = perDecade >= 0 ? '+' : '−';
    final digits = unit == '°C' ? 2 : 0;
    final value = perDecade.abs().toStringAsFixed(digits);
    return '$name: $sign$value $unit за 10 лет'
        '${significant ? '' : ' (тренд не подтверждён статистически)'}';
  }
}

/// Результат обучения модели на истории участка.
class ClimatePatterns {
  final int firstYear;
  final int lastYear;

  /// Типы лет: засушливый, обычный, влажный.
  final List<YearType> yearTypes;

  final List<ClimateTrend> trends;

  /// Годы, засушливые по водному балансу: дефицит влаги тёплого сезона
  /// (испаряемость минус осадки) больше медианы на [ClimatePatternModel.
  /// dryDeficitExtraMm] и более. Это агрономический критерий в миллиметрах
  /// полива, в отличие от статистической группы кластеризации.
  final List<int> waterBalanceDryYears;

  /// Медианный дефицит влаги тёплого сезона, мм.
  final double medianSeasonDeficitMm;

  const ClimatePatterns({
    required this.firstYear,
    required this.lastYear,
    required this.yearTypes,
    required this.trends,
    this.waterBalanceDryYears = const [],
    this.medianSeasonDeficitMm = 0,
  });

  static String aridityClassOf(double ratio) {
    if (ratio < 0.05) {
      return 'гипераридный';
    }
    if (ratio < 0.2) {
      return 'аридный';
    }
    if (ratio < 0.5) {
      return 'полуаридный';
    }
    if (ratio < 0.65) {
      return 'сухой субгумидный';
    }
    return 'гумидный';
  }

  /// Сколько засушливых по модели лет засушливы и по водному балансу.
  int get dryAgreement =>
      dry.years.where(waterBalanceDryYears.contains).length;

  /// Те же типы лет, но с поправкой температуры (высота поля, сценарий).
  ClimatePatterns withTempDelta(double delta) {
    if (delta == 0) {
      return this;
    }
    return ClimatePatterns(
      firstYear: firstYear,
      lastYear: lastYear,
      yearTypes: [
        for (final type in yearTypes)
          type.withClimate(type.climate.adjusted(tempDelta: delta)),
      ],
      trends: trends,
      waterBalanceDryYears: waterBalanceDryYears,
      medianSeasonDeficitMm: medianSeasonDeficitMm,
    );
  }

  int get yearCount => lastYear - firstYear + 1;

  YearType get dry => yearTypes.firstWhere((t) => t.kind == YearKind.dry);

  YearType? typeOf(int year) {
    for (final type in yearTypes) {
      if (type.years.contains(year)) {
        return type;
      }
    }
    return null;
  }
}

/// Small AI №1: модель погодных закономерностей участка.
///
/// Обучается прямо на устройстве на истории NASA POWER конкретной точки:
/// кластеризация k-средних делит годы на три типа, а робастная статистика
/// (Тейл — Сен, Манн — Кендалл) оценивает тренды. Модель занимает считаные
/// килобайты и не требует сети после загрузки истории.
class ClimatePatternModel {
  static const int clusters = 3;
  static const int recentYears = 10;

  /// Год засушлив по водному балансу, если дефицит влаги тёплого сезона
  /// больше медианы на столько миллиметров: 50 мм — это 500 м³ воды на
  /// гектар сверх обычного года.
  static const double dryDeficitExtraMm = 50;

  const ClimatePatternModel();

  ClimatePatterns train(ClimateHistory history) {
    final years = history.years;
    final features = years.map((y) => _features(history, y)).toList();
    final scaled = _standardize(features);

    // Индекс сухости: жарче и суше среднего — больше.
    // Признаки: [осадки за год, осадки тёплого сезона, температура тёплого
    // сезона, отношение осадков к испарению].
    final dryness = scaled.map((f) => f[2] - (f[0] + f[1] + f[3]) / 3).toList();

    final assignment = _kMeans(scaled, dryness);

    // Кластеры упорядочиваются от самого сухого к самому влажному.
    final order = List.generate(clusters, (c) => c)
      ..sort((a, b) {
        double meanDryness(int cluster) {
          final members = [
            for (var i = 0; i < years.length; i++)
              if (assignment[i] == cluster) dryness[i],
          ];
          return members.reduce((x, y) => x + y) / members.length;
        }

        return meanDryness(b).compareTo(meanDryness(a));
      });

    final recentFrom =
        years.length - math.min<int>(recentYears, years.length);
    final types = <YearType>[];

    for (var rank = 0; rank < clusters; rank++) {
      final cluster = order[rank];
      final members = [
        for (var i = 0; i < years.length; i++)
          if (assignment[i] == cluster) years[i],
      ];
      final recentCount = [
        for (var i = recentFrom; i < years.length; i++)
          if (assignment[i] == cluster) i,
      ].length;
      final kind = YearKind.values[rank];

      types.add(
        YearType(
          kind: kind,
          years: members.map((y) => y.year).toList(),
          share: members.length / years.length,
          recentShare: recentCount / (years.length - recentFrom),
          climate: history.summaryOf(members, label: kind.name),
          seasonAridity: members
                  .map((y) => _seasonBalance(history, y).aridity)
                  .reduce((a, b) => a + b) /
              members.length,
        ),
      );
    }

    final deficits = {
      for (final year in years) year.year: _seasonBalance(history, year).deficit,
    };
    final sortedDeficits = deficits.values.toList()..sort();
    final median = sortedDeficits[sortedDeficits.length ~/ 2];
    final waterBalanceDry = [
      for (final entry in deficits.entries)
        if (entry.value >= median + dryDeficitExtraMm) entry.key,
    ];

    final xs = years.map((y) => y.year.toDouble()).toList();

    ClimateTrend trend(String name, String unit, List<double> values) {
      return ClimateTrend(
        name: name,
        unit: unit,
        perDecade: theilSenSlope(xs, values) * 10,
        significant: mannKendallZ(values).abs() > 1.96,
      );
    }

    return ClimatePatterns(
      firstYear: history.firstYear,
      lastYear: history.lastYear,
      yearTypes: types,
      trends: [
        trend(
          'Средняя температура',
          '°C',
          years.map((y) => _mean(y.tMean)).toList(),
        ),
        trend(
          'Осадки за год',
          'мм',
          years.map((y) => _sum(y.precipMm)).toList(),
        ),
        trend(
          'Испаряемость',
          'мм',
          years.map((y) => history.summaryOf([y]).annualEt0Mm).toList(),
        ),
        trend(
          'Дни с заморозками',
          'дн.',
          years.map((y) => _sum(y.frostDays)).toList(),
        ),
      ],
      waterBalanceDryYears: waterBalanceDry,
      medianSeasonDeficitMm: median,
    );
  }

  /// Водный баланс тёплого сезона (шесть самых тёплых месяцев года):
  /// дефицит влаги ET0 − P, мм, и индекс P/ET0.
  ({double deficit, double aridity}) _seasonBalance(
    ClimateHistory history,
    ClimateYear year,
  ) {
    final warm = List.generate(12, (m) => m)
      ..sort((a, b) => year.tMean[b].compareTo(year.tMean[a]));
    final et0 = history.summaryOf([year]).et0Mm;

    var demand = 0.0;
    var rain = 0.0;
    for (final month in warm.take(6)) {
      demand += et0[month];
      rain += year.precipMm[month];
    }

    return (
      deficit: demand - rain,
      aridity: demand <= 0 ? 0 : rain / demand,
    );
  }

  List<double> _features(ClimateHistory history, ClimateYear year) {
    // Тёплый сезон — шесть самых тёплых месяцев года (работает
    // в обоих полушариях).
    final warm = List.generate(12, (m) => m)
      ..sort((a, b) => year.tMean[b].compareTo(year.tMean[a]));
    final warmMonths = warm.take(6).toList();

    final precip = _sum(year.precipMm);
    final et0 = history.summaryOf([year]).annualEt0Mm;

    return [
      precip,
      warmMonths.map((m) => year.precipMm[m]).reduce((a, b) => a + b),
      warmMonths.map((m) => year.tMean[m]).reduce((a, b) => a + b) / 6,
      et0 <= 0 ? 0 : precip / et0,
    ];
  }

  List<List<double>> _standardize(List<List<double>> rows) {
    final width = rows.first.length;
    final means = List.generate(width, (j) {
      return rows.map((r) => r[j]).reduce((a, b) => a + b) / rows.length;
    });
    final deviations = List.generate(width, (j) {
      final variance = rows
              .map((r) => math.pow(r[j] - means[j], 2).toDouble())
              .reduce((a, b) => a + b) /
          rows.length;
      return math.sqrt(variance);
    });

    return rows.map((r) {
      return List.generate(width, (j) {
        return deviations[j] < 1e-9 ? 0.0 : (r[j] - means[j]) / deviations[j];
      });
    }).toList();
  }

  /// Алгоритм Ллойда. Начальные центры детерминированы: годы сортируются
  /// по индексу сухости и делятся на три равные группы — поэтому результат
  /// воспроизводим и не зависит от случайности.
  List<int> _kMeans(List<List<double>> rows, List<double> dryness) {
    final n = rows.length;
    final sorted = List.generate(n, (i) => i)
      ..sort((a, b) => dryness[a].compareTo(dryness[b]));

    var assignment = List.filled(n, 0);
    for (var position = 0; position < n; position++) {
      assignment[sorted[position]] =
          math.min(position * clusters ~/ n, clusters - 1);
    }

    for (var iteration = 0; iteration < 50; iteration++) {
      final centers = <List<double>?>[];
      for (var c = 0; c < clusters; c++) {
        final members = [
          for (var i = 0; i < n; i++)
            if (assignment[i] == c) rows[i],
        ];
        centers.add(
          members.isEmpty
              ? null
              : List.generate(rows.first.length, (j) {
                  return members.map((m) => m[j]).reduce((a, b) => a + b) /
                      members.length;
                }),
        );
      }

      final next = List.generate(n, (i) {
        var best = assignment[i];
        var bestDistance = double.infinity;
        for (var c = 0; c < clusters; c++) {
          final center = centers[c];
          if (center == null) {
            continue;
          }
          var distance = 0.0;
          for (var j = 0; j < center.length; j++) {
            distance += math.pow(rows[i][j] - center[j], 2);
          }
          if (distance < bestDistance) {
            bestDistance = distance;
            best = c;
          }
        }
        return best;
      });

      // Пустой кластер недопустим: тогда остаёмся на прошлом разбиении.
      final sizes = List.filled(clusters, 0);
      for (final c in next) {
        sizes[c]++;
      }
      if (sizes.contains(0)) {
        break;
      }

      var changed = false;
      for (var i = 0; i < n; i++) {
        if (next[i] != assignment[i]) {
          changed = true;
        }
      }
      assignment = next;
      if (!changed) {
        break;
      }
    }

    return assignment;
  }

  /// Оценка наклона Тейла — Сена: медиана наклонов по всем парам точек.
  static double theilSenSlope(List<double> xs, List<double> ys) {
    final slopes = <double>[];
    for (var i = 0; i < xs.length; i++) {
      for (var j = i + 1; j < xs.length; j++) {
        if (xs[j] != xs[i]) {
          slopes.add((ys[j] - ys[i]) / (xs[j] - xs[i]));
        }
      }
    }
    if (slopes.isEmpty) {
      return 0;
    }
    slopes.sort();
    final middle = slopes.length ~/ 2;
    return slopes.length.isOdd
        ? slopes[middle]
        : (slopes[middle - 1] + slopes[middle]) / 2;
  }

  /// Статистика Z критерия Манна — Кендалла (без поправки на связки).
  static double mannKendallZ(List<double> values) {
    final n = values.length;
    if (n < 4) {
      return 0;
    }

    var s = 0;
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        s += (values[j] - values[i]).sign.toInt();
      }
    }

    final variance = n * (n - 1) * (2 * n + 5) / 18;
    if (s > 0) {
      return (s - 1) / math.sqrt(variance);
    }
    if (s < 0) {
      return (s + 1) / math.sqrt(variance);
    }
    return 0;
  }

  static double _sum(List<double> values) => values.reduce((a, b) => a + b);

  static double _mean(List<double> values) => _sum(values) / values.length;
}
