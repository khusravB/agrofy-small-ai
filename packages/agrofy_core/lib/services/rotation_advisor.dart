import 'dart:math' as math;

import '../ai/climate_pattern_model.dart';
import '../data/crop_catalog.dart';
import '../data/region_profile.dart';
import '../models/climate_summary.dart';
import '../models/crop_economics.dart';
import '../models/crop_profile.dart';
import '../models/daily_climate.dart';
import '../models/elevation_correction.dart';
import '../models/farmer_priorities.dart';
import '../models/field.dart';
import '../models/site_conditions.dart';
import '../models/soil_profile.dart';
import '../remote/ndvi_summary.dart';
import '../models/terrain_info.dart';

/// Как культура вписывается в климат участка.
class CropFit {
  final CropProfile crop;

  /// Есть ли климатические данные; без них оценка идёт по справочнику.
  final bool climateKnown;

  /// Лучший месяц посева (0 — январь) и месяцы цикла.
  final int? startMonth;
  final List<int> months;

  /// Соответствие климату, 0–1.
  final double suitability;

  final double waterNeedMm;
  final double effectiveRainMm;

  /// Месяцы цикла жарче или холоднее допустимого и с заморозками.
  final int hotMonths;
  final int coldMonths;
  final int frostMonths;

  /// Абсолютный максимум температуры в период роста.
  final double? peakTemperature;

  const CropFit({
    required this.crop,
    required this.climateKnown,
    this.startMonth,
    this.months = const [],
    required this.suitability,
    required this.waterNeedMm,
    this.effectiveRainMm = 0,
    this.hotMonths = 0,
    this.coldMonths = 0,
    this.frostMonths = 0,
    this.peakTemperature,
  });

  /// Сколько воды нужно добавить поливом (или не хватит без полива), мм.
  double get deficitMm => math.max(waterNeedMm - effectiveRainMm, 0.0);

  /// Доля потребности, не покрытая осадками, 0–1.
  double get waterStress => waterNeedMm <= 0 ? 0 : deficitMm / waterNeedMm;
}

/// Один год севооборота: основная культура и, возможно, покровная.
class RotationYear {
  final CropFit main;
  final CropFit? cover;

  /// Многолетняя культура стоит с прошлого года (второй и далее год).
  final bool established;

  /// Многолетняя культура останется и на следующий год.
  final bool continues;

  const RotationYear({
    required this.main,
    this.cover,
    this.established = false,
    this.continues = false,
  });

  RotationYear withMain(CropFit value, {CropFit? cover}) {
    return RotationYear(
      main: value,
      cover: cover,
      established: established,
      continues: continues,
    );
  }

  /// Месяцев в году, когда поле остаётся без растительного покрова.
  int get bareMonths {
    final start = main.startMonth;
    final cycle = main.crop.cycleMonths;

    // Многолетняя культура зимует на поле и закрывает почву.
    if (established && continues) {
      return 0;
    }
    if (established) {
      return start == null ? (12 - cycle).clamp(0, 12) : (12 - math.min(12, start + cycle));
    }
    if (continues) {
      return start ?? 0;
    }

    final covered = cycle + (cover?.crop.cycleMonths ?? 0);
    return (12 - covered).clamp(0, 12);
  }

  double get deficitMm => main.deficitMm + (cover?.deficitMm ?? 0);
}

enum StrategyKind { current, waterSaving, soilBuilding, incomeResilience }

/// Оценки стратегии, 0–100.
class StrategyScores {
  final double water;
  final double soil;
  final double pestBreak;
  final double income;
  final double resilience;

  const StrategyScores({
    required this.water,
    required this.soil,
    required this.pestBreak,
    required this.income,
    required this.resilience,
  });

  double weighted(FarmerPriorities p) {
    // Небольшая база у каждого веса: при нулевых приоритетах
    // оценка остаётся определённой.
    final wWater = p.water + 0.05;
    final wSoil = p.soil + 0.05;
    final wIncome = p.income + 0.05;
    final wResilience = p.resilience + 0.05;
    final wPest = (wSoil + wResilience) / 4;

    final sum = wWater + wSoil + wIncome + wResilience + wPest;

    return (water * wWater +
            soil * wSoil +
            income * wIncome +
            resilience * wResilience +
            pestBreak * wPest) /
        sum;
  }
}

/// Как стратегия ведёт себя в годы определённого типа.
class YearTypeOutcome {
  final YearType type;
  final double irrigationMm;
  final double total;

  /// Культуры, которым в такие годы климат подходит хуже чем на 75%.
  final List<String> stressedCrops;

  const YearTypeOutcome({
    required this.type,
    required this.irrigationMm,
    required this.total,
    required this.stressedCrops,
  });
}

class RotationStrategy {
  final StrategyKind kind;
  final String title;
  final List<RotationYear> years;
  final StrategyScores scores;

  /// Итоговая оценка по приоритетам фермера, 0–100.
  final double total;

  final List<String> why;
  final List<String> evidence;
  final List<String> benefits;
  final List<String> gaps;
  final List<String> risks;

  /// КПД полива участка: поданная вода = дефицит / КПД.
  final double irrigationEfficiency;

  /// Поведение стратегии в засушливые, обычные и влажные годы
  /// (пусто, пока модель типов лет не обучена).
  final List<YearTypeOutcome> yearOutcomes;

  /// Средний доход (выручка минус затраты) с гектара в год, если для всех
  /// культур стратегии введены цена, урожайность и затраты.
  final double? marginPerHa;

  /// Культуры без экономических данных: для них доход — индекс 1–5.
  final List<String> missingEconomics;

  const RotationStrategy({
    required this.kind,
    required this.title,
    required this.years,
    required this.scores,
    required this.total,
    required this.why,
    required this.evidence,
    required this.benefits,
    required this.gaps,
    required this.risks,
    this.irrigationEfficiency = 1,
    this.yearOutcomes = const [],
    this.marginPerHa,
    this.missingEconomics = const [],
  });

  /// Сколько воды нужно подать на поле с учётом потерь при поливе, мм/год.
  double get avgIrrigationMm => avgDeficitMm / irrigationEfficiency;

  bool get isCurrent => kind == StrategyKind.current;

  double get avgDeficitMm =>
      years.map((y) => y.deficitMm).reduce((a, b) => a + b) / years.length;

  double get avgBareMonths =>
      years.map((y) => y.bareMonths).reduce((a, b) => a + b) / years.length;

  String get sequenceLabel {
    final parts = <String>[];

    for (var i = 0; i < years.length; i++) {
      final year = years[i];
      if (year.established && i > 0) {
        continue;
      }

      if (year.continues) {
        var length = 1;
        while (i + length < years.length && years[i + length].established) {
          length++;
        }
        parts.add('${year.main.crop.name} (${yearsLabel(length)})');
        continue;
      }

      final cover = year.cover;
      if (cover == null) {
        parts.add(year.main.crop.name);
      } else {
        parts.add(
          cover.crop.isCover
              ? '${year.main.crop.name} + ${cover.crop.name}'
              : '${year.main.crop.name} + ${cover.crop.name} повторно',
        );
      }
    }

    return parts.join(' → ');
  }

  static String yearsLabel(int count) {
    if (count % 10 == 1 && count % 100 != 11) {
      return '$count год';
    }
    if ([2, 3, 4].contains(count % 10) && !(count % 100 >= 12 && count % 100 <= 14)) {
      return '$count года';
    }
    return '$count лет';
  }
}

class AdvisorResult {
  /// Заполнено, если стратегии построить нельзя (нет текущей культуры).
  final String? blocker;

  /// Наблюдения по участку: водный баланс, заморозки, голое поле.
  final List<String> insights;

  /// Регион, под который подобран набор культур (если определён).
  final RegionProfile? region;

  /// Поправка температуры на высоту поля (если известны обе высоты).
  final ElevationCorrection? elevation;

  /// Суточный климат с поправками — для сроков посева и заморозков.
  final DailyClimate? daily;

  final String currency;

  /// Первая — текущий севооборот, далее альтернативы по убыванию оценки.
  final List<RotationStrategy> strategies;

  const AdvisorResult({
    this.blocker,
    this.insights = const [],
    this.region,
    this.strategies = const [],
    this.elevation,
    this.daily,
    this.currency = 'у. е.',
  });

  RotationStrategy? get best {
    if (strategies.isEmpty) {
      return null;
    }
    return strategies.reduce((a, b) => b.total > a.total ? b : a);
  }
}

/// Офлайн-движок сравнения севооборотов.
///
/// Детерминированная объяснимая модель: каждая оценка выводится из
/// климатологии NASA POWER, свойств участка и справочника культур.
/// Это инструмент поддержки решения, а не замена агронома.
class RotationAdvisor {

  /// Полный перебор, пока вариантов не больше этого; дальше — лучевой поиск.
  static const int exhaustiveLimit = 6000;

  /// Сколько частичных вариантов хранит лучевой поиск на каждом шаге.
  static const int beamWidth = 40;

  /// Доля урожая повторной культуры от урожая основного посева.
  static const double secondCropYieldShare = 0.6;

  const RotationAdvisor();

  AdvisorResult advise({
    required Field field,
    required List<String> historyCropIds,
    ClimateSummary? climate,
    FarmerPriorities priorities = const FarmerPriorities(),
    ClimatePatterns? patterns,
    TerrainInfo? terrain,
    SoilProfile? soil,
    Map<String, CropEconomics> economics = const {},
    DailyClimate? daily,
    List<NdviPoint> ndvi = const [],
  }) {
    final current = _currentRotation(field, historyCropIds);
    final site = SiteConditions.of(field, terrain: terrain, soil: soil);
    final region = RegionProfile.detect(field);
    final currency = region?.currency ?? 'у. е.';

    if (current.isEmpty) {
      return AdvisorResult(
        blocker: 'Для этого участка не указана полевая культура из '
            'справочника. Добавьте историю культур за последние годы — '
            'и советник сравнит севообороты.',
        currency: currency,
      );
    }

    // Ячейка NASA около 50 км: в горах её средняя высота может сильно
    // отличаться от высоты поля. Температура поправляется на разницу.
    final elevation = ElevationCorrection.of(
      fieldElevation: terrain?.elevation ?? field.elevation,
      gridElevation: climate?.gridElevation ?? daily?.gridElevation,
    );
    if (elevation != null && elevation.significant) {
      climate = climate?.adjusted(tempDelta: elevation.deltaT);
      patterns = patterns?.withTempDelta(elevation.deltaT);
      daily = daily?.withTempDelta(elevation.deltaT);
    }

    final rainfed = field.irrigation == 'Без орошения';
    final fits = {
      for (final crop in CropCatalog.all)
        crop.id: evaluateCrop(
          crop,
          climate,
          preferRain: rainfed,
          site: site,
        ),
    };

    final money = _Money.of(economics);
    final currentYears = _yearsOf(current, fits);

    bool inRegion(CropProfile crop) =>
        region == null || region.cropIds.contains(crop.id);

    final anchor = current.last;
    final pool = CropCatalog.mainCrops.where((crop) {
      return inRegion(crop) &&
          _isViable(fits[crop.id]!, rainfed) &&
          site.siteFit(crop) >= 0.5;
    }).toList();
    if (!pool.contains(anchor)) {
      pool.add(anchor);
    }

    // Что можно посеять в свободные месяцы года: покровные культуры
    // и повторные (второй урожай после ранней уборки).
    final covers = CropCatalog.coverCrops
        .where((crop) => inRegion(crop) && site.siteFit(crop) >= 0.5)
        .toList();
    final seconds = CropCatalog.mainCrops
        .where(
          (crop) =>
              crop.secondCrop && inRegion(crop) && site.siteFit(crop) >= 0.5,
        )
        .toList();

    final length = priorities.rotationYears.clamp(3, 5);
    final exhaustive =
        math.pow(pool.length, length - 1) <= exhaustiveLimit;
    final all = exhaustive ? _enumerate(pool, anchor, length) : null;

    final picked = <StrategyKind, List<RotationYear>>{};
    final usedKeys = <String>{_key(current)};

    for (final kind in const [
      StrategyKind.waterSaving,
      StrategyKind.soilBuilding,
      StrategyKind.incomeResilience,
    ]) {
      final themed = _themeWeights(kind, priorities);
      final memo = <String, CropFit?>{};

      List<RotationYear> build(List<CropProfile> sequence) {
        final years = _yearsOf(sequence, fits);
        if (climate == null) {
          return years;
        }
        if (kind == StrategyKind.soilBuilding) {
          return _withCatchCrops(
            years,
            climate,
            [...covers, ...seconds.where((c) => c.nitrogenFixing)],
            rainfed: rainfed,
            site: site,
            forIncome: false,
            memo: memo,
          );
        }
        if (kind == StrategyKind.incomeResilience) {
          return _withCatchCrops(
            years,
            climate,
            seconds,
            rainfed: rainfed,
            site: site,
            forIncome: true,
            memo: memo,
          );
        }
        return years;
      }

      double score(List<CropProfile> sequence) =>
          _score(build(sequence), field, site, money).weighted(themed);

      // Культура не возвращается на поле раньше чем через три года —
      // это агрономическое правило, а не предпочтение, поэтому варианты
      // с нарушением не предлагаются.
      bool allowed(List<CropProfile> sequence, {bool complete = true}) =>
          _shortReturns(_yearsOf(sequence, fits), cyclic: complete).isEmpty;

      final candidates = all ??
          _beamSearch(
            pool,
            anchor,
            length,
            score: score,
            exclude: usedKeys,
            allowed: (sequence) => allowed(sequence, complete: false),
          );

      List<CropProfile>? best;
      var bestScore = -1.0;
      String? bestKey;

      for (final sequence in candidates) {
        final key = _key(sequence);
        if (usedKeys.contains(key) || !allowed(sequence)) {
          continue;
        }
        if (_shortReturns(build(sequence)).isNotEmpty) {
          continue;
        }
        final value = score(sequence);
        if (value > bestScore) {
          bestScore = value;
          best = sequence;
          bestKey = key;
        }
      }

      if (best != null) {
        picked[kind] = build(best);
        usedKeys.add(bestKey!);
      }
    }

    RotationStrategy describe(
      StrategyKind kind,
      List<RotationYear> years,
      RotationStrategy? baseline,
    ) {
      return _describe(
        kind: kind,
        years: years,
        field: field,
        climate: climate,
        rainfed: rainfed,
        priorities: priorities,
        baseline: baseline,
        region: region,
        site: site,
        patterns: patterns,
        money: money,
        currency: currency,
        daily: daily,
        elevation: elevation,
      );
    }

    final currentStrategy =
        describe(StrategyKind.current, currentYears, null);

    final alternatives = [
      for (final entry in picked.entries)
        describe(entry.key, entry.value, currentStrategy),
    ]..sort((a, b) => b.total.compareTo(a.total));

    return AdvisorResult(
      insights: [
        ..._insights(
          field,
          climate,
          currentYears,
          site,
          patterns,
          daily: daily,
          elevation: elevation,
        ),
        // Импортированный спутниковый ряд — контекст, а не решение.
        if (NdviSummary.of(ndvi) case final summary?) summary.describe(),
      ],
      region: region,
      strategies: [currentStrategy, ...alternatives],
      elevation: elevation,
      daily: daily,
      currency: currency,
    );
  }

  /// Годы севооборота с отметками многолетних культур.
  List<RotationYear> _yearsOf(
    List<CropProfile> sequence,
    Map<String, CropFit> fits,
  ) {
    return [
      for (var i = 0; i < sequence.length; i++)
        RotationYear(
          main: fits[sequence[i].id]!,
          established: sequence[i].isPerennial &&
              i > 0 &&
              sequence[i - 1].id == sequence[i].id,
          continues: sequence[i].isPerennial &&
              i + 1 < sequence.length &&
              sequence[i + 1].id == sequence[i].id,
        ),
    ];
  }

  /// Шаги, которыми можно продолжить последовательность: одна культура на
  /// год или многолетняя культура блоком на 2…её срок лет.
  Iterable<List<CropProfile>> _steps(
    List<CropProfile> pool,
    int remaining,
  ) sync* {
    for (final crop in pool) {
      if (!crop.isPerennial) {
        yield [crop];
        continue;
      }
      final longest = math.min(crop.perennialYears, remaining);
      for (var block = 2; block <= longest; block++) {
        yield List.filled(block, crop);
      }
    }
  }

  /// Все последовательности длины [length], начинающиеся с культуры
  /// фермера: предлагаем доработать его севооборот, а не отказаться от него.
  List<List<CropProfile>> _enumerate(
    List<CropProfile> pool,
    CropProfile anchor,
    int length,
  ) {
    var partial = <List<CropProfile>>[
      [anchor],
    ];
    final complete = <List<CropProfile>>[];

    while (partial.isNotEmpty) {
      final next = <List<CropProfile>>[];
      for (final sequence in partial) {
        for (final step in _steps(pool, length - sequence.length)) {
          final extended = [...sequence, ...step];
          if (extended.length == length) {
            complete.add(extended);
          } else {
            next.add(extended);
          }
        }
      }
      partial = next;
    }

    return complete;
  }

  /// Лучевой поиск для длинных севооборотов: на каждом шаге остаются
  /// [beamWidth] лучших частичных вариантов по оценке темы.
  List<List<CropProfile>> _beamSearch(
    List<CropProfile> pool,
    CropProfile anchor,
    int length, {
    required double Function(List<CropProfile>) score,
    required Set<String> exclude,
    required bool Function(List<CropProfile>) allowed,
  }) {
    var beam = <List<CropProfile>>[
      [anchor],
    ];
    final complete = <List<CropProfile>>[];

    while (beam.isNotEmpty) {
      final scored = <(List<CropProfile>, double)>[];
      for (final sequence in beam) {
        for (final step in _steps(pool, length - sequence.length)) {
          final extended = [...sequence, ...step];
          if (extended.length == length) {
            if (!exclude.contains(_key(extended))) {
              complete.add(extended);
            }
          } else if (allowed(extended)) {
            scored.add((extended, score(extended)));
          }
        }
      }
      scored.sort((a, b) => b.$2.compareTo(a.$2));
      beam = [for (final item in scored.take(beamWidth)) item.$1];
    }

    return complete;
  }

  // ----------------------------------------
  // Климатическое соответствие культуры
  // ----------------------------------------

  /// Подбирает лучшее окно посева и считает водный баланс культуры.
  /// [allowedMonths] ограничивает окно (для покровных культур).
  ///
  /// Среди окон без неподходящих месяцев выбирается самое солнечное —
  /// основной сезон культуры. При [preferRain] (богара, покровные культуры)
  /// выбирается окно с наименьшим дефицитом воды.
  CropFit evaluateCrop(
    CropProfile crop,
    ClimateSummary? climate, {
    Set<int>? allowedMonths,
    bool preferRain = false,
    SiteConditions site = const SiteConditions(),
  }) {
    if (climate == null) {
      return CropFit(
        crop: crop,
        climateKnown: false,
        suitability: 1,
        waterNeedMm: crop.waterNeedMm,
      );
    }

    final et0 = climate.et0Mm;
    CropFit? best;
    var bestRank = double.negativeInfinity;

    for (var start = 0; start < 12; start++) {
      final months = [
        for (var i = 0; i < crop.cycleMonths; i++) (start + i) % 12,
      ];

      if (allowedMonths != null && !months.every(allowedMonths.contains)) {
        continue;
      }

      var good = 0;
      var hot = 0;
      var cold = 0;
      var frost = 0;
      var need = 0.0;
      var rain = 0.0;
      var peak = -100.0;
      var sunshine = 0.0;

      for (final month in months) {
        // Доля ET0 без температурного множителя — мера солнечной энергии.
        sunshine += et0[month] / math.max(climate.tMean[month] + 17.8, 1.0);

        final t = climate.tMean[month];
        final frosty = climate.frostDays[month] > 3;
        final dormant = crop.overwinters && t < crop.tMin && t > -12;

        if (dormant) {
          // В покое культура почти не расходует воду.
          need += 0.3 * et0[month] * site.needFactor;
        } else {
          need += crop.kc * et0[month] * site.needFactor;

          if (t > crop.tMax) {
            hot++;
          } else if (t < crop.tMin) {
            cold++;
          } else if (frosty && !crop.frostTolerant) {
            frost++;
          } else {
            good++;
          }

          peak = math.max(peak, climate.tMaxExtreme[month]);
        }

        rain += site.rainShare * climate.precipMm[month];
      }

      final bad = hot + cold + frost;
      final suitability =
          ((good - bad) / crop.requiredActiveMonths).clamp(0.0, 1.0);

      final fit = CropFit(
        crop: crop,
        climateKnown: true,
        startMonth: start,
        months: months,
        suitability: suitability,
        waterNeedMm: need,
        effectiveRainMm: math.min(rain, need),
        hotMonths: hot,
        coldMonths: cold,
        frostMonths: frost,
        peakTemperature: peak > -100 ? peak : null,
      );

      // Сначала — меньше неподходящих месяцев и больше подходящих,
      // затем — сезон: солнце или (на богаре) наименьший дефицит воды.
      final season = preferRain ? -fit.deficitMm / 10000 : sunshine / 10000;
      final rank = -bad * 100.0 +
          math.min(good, crop.requiredActiveMonths) +
          season.clamp(-0.9, 0.9);

      if (rank > bestRank) {
        bestRank = rank;
        best = fit;
      }
    }

    return best ??
        CropFit(
          crop: crop,
          climateKnown: true,
          suitability: 0,
          waterNeedMm: crop.waterNeedMm,
        );
  }

  bool _isViable(CropFit fit, bool rainfed) {
    if (!fit.climateKnown) {
      return true;
    }
    if (fit.suitability < 0.75) {
      return false;
    }
    if (rainfed) {
      return fit.waterStress <= 0.25 + 0.07 * fit.crop.droughtTolerance;
    }
    return true;
  }

  // ----------------------------------------
  // Построение вариантов
  // ----------------------------------------

  List<CropProfile> _currentRotation(Field field, List<String> history) {
    final fromHistory = <CropProfile>[];
    for (final id in history) {
      final crop = CropCatalog.byId(id);
      if (crop != null && !crop.isCover) {
        fromHistory.add(crop);
      }
    }

    if (fromHistory.isNotEmpty) {
      return fromHistory.length > 4
          ? fromHistory.sublist(fromHistory.length - 4)
          : fromHistory;
    }

    final fromField = CropCatalog.fromFieldCrop(field.crop);
    return fromField == null ? const [] : [fromField];
  }

  /// Ключ, одинаковый для циклических сдвигов одной последовательности.
  String _key(List<CropProfile> sequence) {
    final ids = sequence.map((crop) => crop.id).toList();
    String? smallest;

    for (var shift = 0; shift < ids.length; shift++) {
      final rotated = [...ids.sublist(shift), ...ids.sublist(0, shift)];
      final key = rotated.join('>');
      if (smallest == null || key.compareTo(smallest) < 0) {
        smallest = key;
      }
    }

    return smallest ?? '';
  }

  FarmerPriorities _themeWeights(StrategyKind kind, FarmerPriorities p) {
    double mix(double farmer, double theme) => 0.4 * farmer + theme;

    switch (kind) {
      case StrategyKind.waterSaving:
        return FarmerPriorities(
          water: mix(p.water, 1.0),
          soil: mix(p.soil, 0.25),
          income: mix(p.income, 0.25),
          resilience: mix(p.resilience, 0.5),
        );
      case StrategyKind.soilBuilding:
        return FarmerPriorities(
          water: mix(p.water, 0.25),
          soil: mix(p.soil, 1.0),
          income: mix(p.income, 0.25),
          resilience: mix(p.resilience, 0.25),
        );
      case StrategyKind.incomeResilience:
        return FarmerPriorities(
          water: mix(p.water, 0.25),
          soil: mix(p.soil, 0.25),
          income: mix(p.income, 1.0),
          resilience: mix(p.resilience, 0.6),
        );
      case StrategyKind.current:
        return p;
    }
  }

  /// Добавляет в свободные месяцы каждого года покровную или повторную
  /// культуру из [options]. При [forIncome] выбирается самая ценная,
  /// иначе — самая полезная для почвы.
  List<RotationYear> _withCatchCrops(
    List<RotationYear> years,
    ClimateSummary climate,
    List<CropProfile> options, {
    required bool rainfed,
    required SiteConditions site,
    required bool forIncome,
    Map<String, CropFit?>? memo,
  }) {
    final result = <RotationYear>[];

    for (var i = 0; i < years.length; i++) {
      final year = years[i];
      final next = years[(i + 1) % years.length];

      // Многолетняя культура занимает поле весь год.
      if (year.main.crop.isPerennial) {
        result.add(year);
        continue;
      }

      // Культуры в пределах двух лет от этого: повторная культура не должна
      // совпадать с ними, иначе вернётся на поле слишком рано.
      final nearby = <String>{
        for (var offset = -(minReturnYears - 1);
            offset <= minReturnYears - 1;
            offset++)
          years[(i + offset) % years.length].main.crop.id,
        for (var offset = 1; offset < minReturnYears && i - offset >= 0; offset++)
          if (result[i - offset].cover != null &&
              !result[i - offset].cover!.crop.isCover)
            result[i - offset].cover!.crop.id,
      };

      // Выбор зависит только от культур вокруг этого года.
      final key = '${year.main.crop.id}>${next.main.crop.id}|'
          '${(nearby.toList()..sort()).join(',')}';
      if (memo != null && memo.containsKey(key)) {
        result.add(year.withMain(year.main, cover: memo[key]));
        continue;
      }

      final free = {
        for (var month = 0; month < 12; month++)
          if (!year.main.months.contains(month)) month,
      };

      CropFit? bestCover;
      var bestRank = -1.0;

      for (final cover in options) {
        // Повторная культура того же семейства, что и основная, не даёт
        // разрыва для вредителей — такие пары не предлагаем.
        final sameFamilySecond =
            !cover.isCover && cover.family == year.main.crop.family;
        if (cover.cycleMonths > free.length || sameFamilySecond) {
          continue;
        }
        if (!cover.isCover &&
            (nearby.contains(cover.id) ||
                cover.family == next.main.crop.family)) {
          continue;
        }

        final fit = evaluateCrop(
          cover,
          climate,
          allowedMonths: free,
          preferRain: true,
          site: site,
        );
        if (fit.startMonth == null || fit.suitability < 0.99) {
          continue;
        }
        // Повторной культуре летом нужна вода: на богаре проверяем,
        // что осадков хватает.
        if (!cover.isCover && !_isViable(fit, rainfed)) {
          continue;
        }

        // Предпочитаем покровную культуру другого семейства, чем соседние
        // основные; бобовую — перед требовательной к азоту культурой.
        var rank = 1.0;
        if (cover.family != year.main.crop.family) {
          rank += 1;
        }
        if (cover.family != next.main.crop.family) {
          rank += 1;
        }
        if (cover.nitrogenFixing && next.main.crop.nitrogenDemand >= 4) {
          rank += 1.5;
        }
        rank += cover.residue / 10;
        if (forIncome) {
          rank += cover.marketValue * 2;
        }

        if (rank > bestRank) {
          bestRank = rank;
          bestCover = fit;
        }
      }

      memo?[key] = bestCover;
      result.add(year.withMain(year.main, cover: bestCover));
    }

    return result;
  }

  // ----------------------------------------
  // Оценки
  // ----------------------------------------

  StrategyScores _score(
    List<RotationYear> years,
    Field field,
    SiteConditions site,
    _Money money,
  ) {
    final rainfed = site.rainfed;
    final n = years.length;

    double mean(double Function(RotationYear year) value) {
      return years.map(value).reduce((a, b) => a + b) / n;
    }

    // Вода: сколько нужно подать на поле с учётом потерь при поливе.
    final irrigation = mean((y) => y.deficitMm) / site.irrigationEfficiency;
    final water = 100 * (1 - (irrigation / 1500).clamp(0.0, 1.0));

    // Почва.
    final nitrogen = mean((y) {
      var balance = y.main.crop.nitrogenFixing
          ? 1.0
          : -y.main.crop.nitrogenDemand / 5;
      if (y.cover?.crop.nitrogenFixing ?? false) {
        balance += 0.5;
      }
      return (balance.clamp(-1.0, 1.0) + 1) / 2;
    });

    final organic = mean((y) {
      return ((y.main.crop.residue + (y.cover?.crop.residue ?? 0) / 2) / 5)
          .clamp(0.0, 1.0);
    });

    final cover = mean((y) {
      final groundCover = math.max(
        y.main.crop.groundCover,
        y.cover?.crop.groundCover ?? 0,
      );
      return 0.5 * (1 - y.bareMonths / 12) + 0.5 * groundCover / 5;
    });

    final roots = years.map((y) => y.main.crop.rootDepth).toSet().length / 3;

    final ph = field.soilPh;
    final phFit = ph == null
        ? 1.0
        : mean((y) => _phOk(y.main.crop, ph) ? 1.0 : 0.0);

    final siteFit = mean((y) => site.siteFit(y.main.crop));

    // На склоне голое поле смывается: штраф растёт с уклоном.
    final erosion = site.erosionFactor * mean((y) => y.bareMonths / 12);

    // При бедной азотом или гумусом почве (по данным фермера) азот
    // и органика весят больше.
    final nWeight = site.nitrogenWeight;
    final oWeight = site.organicWeight;
    final weightSum = nWeight + oWeight + 0.25 + 0.1 + 0.05 + 0.05;

    final soil = (100 *
                (nWeight * nitrogen +
                    oWeight * organic +
                    0.25 * cover +
                    0.1 * roots +
                    0.05 * phFit +
                    0.05 * siteFit) /
                weightSum -
            25 * erosion)
        .clamp(0.0, 100.0);

    // Разрыв циклов вредителей: одно семейство подряд — плохо. Годы одной
    // посадки многолетней культуры повтором не считаются.
    final repeats = _familyRepeats(years);
    final families = years.map((y) => y.main.crop.family).toSet().length;
    final diversity = n > 1 ? (families - 1) / (n - 1) : 0.0;
    final returns = _shortReturns(years).length;
    final pestBreak = 100 *
        (0.6 * (1 - repeats / n) +
            0.25 * diversity +
            0.15 * (1 - (returns / n).clamp(0.0, 1.0)));

    // Устойчивость: соответствие климату, участку и засухоустойчивость.
    double climateFit(RotationYear y) {
      final fit = y.main;
      final local = site.siteFit(fit.crop);
      if (!rainfed) {
        return fit.suitability * local;
      }
      final penalty = fit.waterStress * (6 - fit.crop.droughtTolerance) / 5;
      return fit.suitability * local * (1 - penalty).clamp(0.0, 1.0);
    }

    final resilience = 100 *
        (0.7 * mean(climateFit) +
            0.3 * mean((y) => y.main.crop.droughtTolerance / 5));

    // Доход: если фермер ввёл цену, урожайность и затраты — маржа
    // в деньгах относительно лучшей культуры; иначе — рыночный индекс 1–5.
    // В обоих случаях урожай снижается, если культуре не подходит климат
    // или участок.
    final income = 100 *
        mean((y) {
          var value = money.yearValue(y.main.crop, climateFit(y));

          final second = y.cover;
          if (second != null && !second.crop.isCover) {
            value += money.yearValue(
              second.crop,
              second.suitability * site.siteFit(second.crop),
              share: secondCropYieldShare,
            );
          }
          return value.clamp(0.0, 1.0);
        });

    return StrategyScores(
      water: water,
      soil: soil,
      pestBreak: pestBreak,
      income: income,
      resilience: resilience,
    );
  }

  bool _phOk(CropProfile crop, double ph) =>
      ph >= crop.phMin && ph <= crop.phMax;

  /// Минимальный перерыв, лет, прежде чем культура вернётся на поле.
  static const int minReturnYears = 3;

  /// Культуры, которые возвращаются на поле раньше [minReturnYears] лет
  /// (по кругу севооборота). Учитываются и повторные посевы; годы одной
  /// посадки многолетней культуры не считаются.
  List<CropProfile> _shortReturns(
    List<RotationYear> years, {
    bool cyclic = true,
  }) {
    final n = years.length;
    if (n == 1) {
      return cyclic ? [years.first.main.crop] : const [];
    }

    final occurrences = <(int, CropProfile, bool)>[
      for (var i = 0; i < n; i++) ...[
        (i, years[i].main.crop, true),
        if (years[i].cover != null && !years[i].cover!.crop.isCover)
          (i, years[i].cover!.crop, false),
      ],
    ];

    final result = <CropProfile>[];
    for (var a = 0; a < occurrences.length; a++) {
      for (var b = a + 1; b < occurrences.length; b++) {
        final (i, crop, mainA) = occurrences[a];
        final (j, other, mainB) = occurrences[b];
        if (crop.id != other.id) {
          continue;
        }

        if (mainA && mainB && crop.isPerennial) {
          var sameBlock = true;
          for (var k = i + 1; k <= j && sameBlock; k++) {
            sameBlock = years[k].established;
          }
          if (sameBlock) {
            continue;
          }
        }

        final gap = j - i;
        final distance = cyclic ? math.min(gap, n - gap) : gap;
        if (distance < minReturnYears) {
          result.add(crop);
        }
      }
    }
    return result;
  }

  /// Сколько раз подряд идут культуры одного семейства (по кругу).
  int _familyRepeats(List<RotationYear> years) {
    final n = years.length;
    var repeats = 0;
    for (var i = 0; i < n; i++) {
      final next = years[(i + 1) % n];
      if (next.established) {
        continue;
      }
      // Повторная культура стоит на поле прямо перед следующей основной.
      final second = years[i].cover;
      final before = second != null && !second.crop.isCover
          ? second.crop
          : years[i].main.crop;
      if (before.family == next.main.crop.family ||
          years[i].main.crop.family == next.main.crop.family) {
        repeats++;
      }
    }
    return repeats;
  }

  // ----------------------------------------
  // Объяснения
  // ----------------------------------------

  RotationStrategy _describe({
    required StrategyKind kind,
    required List<RotationYear> years,
    required Field field,
    required ClimateSummary? climate,
    required bool rainfed,
    required FarmerPriorities priorities,
    required RotationStrategy? baseline,
    required RegionProfile? region,
    required SiteConditions site,
    required ClimatePatterns? patterns,
    required _Money money,
    required String currency,
    required DailyClimate? daily,
    required ElevationCorrection? elevation,
  }) {
    // Если модель типов лет обучена, стратегия «проживает» засушливый,
    // обычный и влажный год, а оценки усредняются с весами типов лет.
    final outcomes = <YearTypeOutcome>[];
    var scores = _score(years, field, site, money);

    if (patterns != null && climate != null) {
      var water = 0.0;
      var soil = 0.0;
      var pest = 0.0;
      var income = 0.0;
      var resilience = 0.0;
      var weightSum = 0.0;

      for (final type in patterns.yearTypes) {
        final replayed = _replay(years, type.climate, site);
        final typeScores = _score(replayed, field, site, money);
        final weight = type.weight;

        water += weight * typeScores.water;
        soil += weight * typeScores.soil;
        pest += weight * typeScores.pestBreak;
        income += weight * typeScores.income;
        resilience += weight * typeScores.resilience;
        weightSum += weight;

        outcomes.add(
          YearTypeOutcome(
            type: type,
            irrigationMm:
                replayed.map((y) => y.deficitMm).reduce((a, b) => a + b) /
                    replayed.length /
                    site.irrigationEfficiency,
            total: typeScores.weighted(priorities),
            stressedCrops: {
              for (final y in replayed)
                if (y.main.suitability < 0.75) y.main.crop.name,
            }.toList(),
          ),
        );
      }

      if (weightSum > 0) {
        scores = StrategyScores(
          water: water / weightSum,
          soil: soil / weightSum,
          pestBreak: pest / weightSum,
          income: income / weightSum,
          resilience: resilience / weightSum,
        );
      }
    }

    final crops = years.map((y) => y.main.crop).toList();
    final distinct = <String, CropProfile>{
      for (final crop in crops) crop.id: crop,
    }.values.toList();

    String names(Iterable<CropProfile> list) =>
        list.map((crop) => crop.name).join(', ');

    final legumes = distinct.where((c) => c.nitrogenFixing).toList();
    final deepRooted = distinct.where((c) => c.rootDepth == 3).toList();
    final droughtHardy = distinct.where((c) => c.droughtTolerance >= 4).toList();
    final covers = [
      for (final y in years)
        if (y.cover != null && y.cover!.crop.isCover) y.cover!.crop,
    ];
    final secondCrops = [
      for (final y in years)
        if (y.cover != null && !y.cover!.crop.isCover) y.cover!.crop,
    ];

    final repeats = _familyRepeats(years);

    // Доход в деньгах — только если для всех культур есть цена,
    // урожайность и затраты.
    final missingEconomics = <String>{};
    final margins = <double>[];
    for (final year in years) {
      final crop = year.main.crop;
      final fit = year.main.suitability * site.siteFit(crop);
      final main = money.margin(crop, fit);
      if (main == null) {
        missingEconomics.add(crop.name);
      }

      var value = main ?? 0;
      final second = year.cover;
      if (second != null && !second.crop.isCover) {
        final extra = money.margin(
          second.crop,
          second.suitability * site.siteFit(second.crop),
          share: secondCropYieldShare,
        );
        if (extra == null) {
          missingEconomics.add(second.crop.name);
        }
        value += extra ?? 0;
      }
      margins.add(value);
    }
    final marginPerHa = missingEconomics.isEmpty
        ? margins.reduce((a, b) => a + b) / margins.length
        : null;

    String moneyLabel(double value) =>
        '${_thousands(value.round())} $currency';

    // --- Почему предложено ---
    final why = <String>[];
    switch (kind) {
      case StrategyKind.current:
        why.add(
          years.length == 1
              ? 'Это ваш текущий вариант: одна культура из года в год. '
                  'Он показан как точка отсчёта для сравнения.'
              : 'Это ваш текущий севооборот по истории участка. '
                  'Он показан как точка отсчёта для сравнения.',
        );
      case StrategyKind.waterSaving:
        why.add(
          'Подобран, чтобы снизить потребность в поливе: в приоритете '
          'культуры с меньшим расходом воды и высокой засухоустойчивостью.',
        );
      case StrategyKind.soilBuilding:
        why.add(
          'Подобран, чтобы восстановить почву: азотфиксация, больше '
          'растительных остатков и меньше месяцев с голым полем.',
        );
      case StrategyKind.incomeResilience:
        why.add(
          'Подобран, чтобы сохранить доход: культуры с более высокой '
          'рыночной ценностью, которые подходят климату участка.',
        );
    }

    if (legumes.isNotEmpty) {
      why.add(
        'Бобовые (${names(legumes)}) фиксируют азот из воздуха и оставляют '
        'его следующей культуре'
        '${site.soil?.nitrogen == NutrientLevel.low ? ' — при низком азоте '
            'в почве (${site.soil!.sourceLabel}) это особенно ценно' : ''}.',
      );
    }
    final perennials = distinct.where((c) => c.isPerennial).toList();
    if (perennials.isNotEmpty) {
      why.add(
        '${names(perennials)} — многолетняя культура: несколько лет подряд '
        'закрывает поле круглый год и накапливает азот и органику.',
      );
    }
    if (deepRooted.isNotEmpty && kind != StrategyKind.current) {
      why.add(
        'Глубокие корни (${names(deepRooted)}) разрыхляют почву и улучшают '
        'впитывание воды.',
      );
    }
    if (droughtHardy.isNotEmpty && kind == StrategyKind.waterSaving) {
      why.add('Засухоустойчивые культуры: ${names(droughtHardy)}.');
    }
    if (covers.isNotEmpty) {
      why.add(
        'Покровные культуры (${names(covers.toSet())}) закрывают почву '
        'между основными, защищая её от эрозии и пересыхания.',
      );
    }
    if (secondCrops.isNotEmpty) {
      why.add(
        'Повторный посев (${names(secondCrops.toSet())}) после ранней '
        'уборки даёт второй урожай с того же поля за год.',
      );
    }
    if (repeats == 0 && years.length > 1) {
      why.add(
        'Культуры одного семейства не идут подряд — это прерывает циклы '
        'вредителей и болезней.',
      );
    }

    // --- На каких данных ---
    final evidence = <String>[];
    if (climate != null) {
      for (final year in years) {
        if (year.established) {
          continue;
        }
        for (final fit in [year.main, ?year.cover]) {
          final start = fit.startMonth;
          if (start == null) {
            continue;
          }
          final window = identical(fit, year.main)
              ? daily?.sowingWindow(fit.crop, start)
              : null;
          final sowing = window == null
              ? 'посев — ${ClimateSummary.monthNames[start]}'
              : 'посев — с ${window.decade} (${window.reason})';
          evidence.add(
            '${fit.crop.name}: $sowing, '
            'потребность ${fit.waterNeedMm.round()} мм, осадки покрывают '
            '${fit.effectiveRainMm.round()} мм, дефицит '
            '${fit.deficitMm.round()} мм; соответствие климату '
            '${(fit.suitability * 100).round()}%.',
          );
        }
      }
      if (daily != null) {
        evidence.add(
          'Сроки посева и заморозки: суточные данные NASA POWER '
          '(${daily.firstYear}–${daily.lastYear}).',
        );
      }
      evidence.add(
        'Климат: NASA POWER'
        '${climate.period.isEmpty ? '' : ' (${_shortPeriod(climate.period)})'}'
        ' — осадки ${climate.annualPrecipMm.round()} мм/год, эталонное '
        'испарение ${climate.annualEt0Mm.round()} мм/год (формула Харгривса).',
      );
    } else {
      evidence.add(
        'Климатические данные не загружены: оценка построена только на '
        'справочных свойствах культур.',
      );
    }
    evidence.add(
      'Свойства культур — встроенный справочник (ориентиры FAO-56 и '
      'типовые агрономические нормы).',
    );
    if (elevation != null && elevation.significant) {
      evidence.add(elevation.describe());
    }
    final soil = site.soil;
    if (soil != null && !soil.isEmpty) {
      evidence.add(
        'Почва (${soil.sourceLabel}): ${soil.summary().join(', ')}.',
      );
      if (soil.salinity != null) {
        evidence.add(
          'Солеустойчивость культур — ориентиры FAO (Ayers & Westcot, 1985; '
          'Maas–Hoffman), потеря около 10% урожая на 1 дС/м выше порога.',
        );
      }
    }
    if (marginPerHa != null) {
      evidence.add(
        'Доход: ваши цены, урожайность и затраты; урожай снижен, если '
        'культуре не подходит климат или участок. Повторный посев — '
        '${(secondCropYieldShare * 100).round()}% урожая основного.',
      );
    }

    // --- Выгоды ---
    final benefits = <String>[];
    final avgDeficit =
        years.map((y) => y.deficitMm).reduce((a, b) => a + b) / years.length;
    final avgBare =
        years.map((y) => y.bareMonths).reduce((a, b) => a + b) / years.length;

    if (baseline != null) {
      final waterDelta =
          baseline.avgIrrigationMm - avgDeficit / site.irrigationEfficiency;
      if (waterDelta >= 20) {
        benefits.add(
          'Воды на полив нужно меньше примерно на ${waterDelta.round()} мм '
          'в год (${(waterDelta * 10).round()} м³ на гектар) с учётом '
          'потерь: ${site.irrigationLabel}.',
        );
      }
      final dryNow = outcomes.where((o) => o.type.kind == YearKind.dry);
      final dryBase =
          baseline.yearOutcomes.where((o) => o.type.kind == YearKind.dry);
      if (dryNow.isNotEmpty && dryBase.isNotEmpty) {
        final dryDelta = dryNow.first.total - dryBase.first.total;
        if (dryDelta >= 3) {
          benefits.add(
            'В засушливые годы оценка выше на ${dryDelta.round()} из 100 — '
            'севооборот устойчивее к засухе.',
          );
        }
      }
      final soilDelta = scores.soil - baseline.scores.soil;
      if (soilDelta >= 3) {
        benefits.add(
          'Оценка здоровья почвы выше на ${soilDelta.round()} из 100.',
        );
      }
      final pestDelta = scores.pestBreak - baseline.scores.pestBreak;
      if (pestDelta >= 5) {
        benefits.add(
          'Лучше прерываются циклы вредителей и болезней '
          '(+${pestDelta.round()} из 100).',
        );
      }
      final baseMargin = baseline.marginPerHa;
      if (marginPerHa != null && baseMargin != null) {
        final delta = marginPerHa - baseMargin;
        if (delta > 0) {
          benefits.add(
            'Доход выше примерно на ${moneyLabel(delta)} с гектара в год '
            '(по вашим ценам и затратам).',
          );
        }
      } else {
        final incomeDelta = scores.income - baseline.scores.income;
        if (incomeDelta >= 3) {
          benefits.add(
            'Выше относительная рыночная ценность '
            '(+${incomeDelta.round()} из 100).',
          );
        }
      }
      final bareDelta = baseline.avgBareMonths - avgBare;
      if (bareDelta >= 0.5) {
        benefits.add(
          'Поле без покрова в среднем на ${bareDelta.toStringAsFixed(1)} '
          'мес. в году меньше.',
        );
      }
      if (distinct.any((c) => c.forage)) {
        benefits.add(
          'Есть кормовая ценность: '
          '${names(distinct.where((c) => c.forage))}.',
        );
      }
      if (benefits.isEmpty) {
        benefits.add(
          'По выбранным приоритетам заметного выигрыша перед текущим '
          'севооборотом нет.',
        );
      }
    } else {
      benefits.add('Привычная технология, техника и каналы сбыта.');
      if (legumes.isNotEmpty) {
        benefits.add('В севообороте уже есть азотфиксирующая культура.');
      }
    }

    // --- Пробелы в данных ---
    final gaps = <String>[
      if (climate == null)
        'Нет климатических данных: загрузите их при наличии сети.'
      else
        'Климатология NASA POWER — среднее за много лет по ячейке около '
            '50 км; ${elevation != null && elevation.significant ? 'высота '
                'поля учтена, но' : 'высота поля не учтена,'} склон, '
            'долина и другой микроклимат поля — нет.',
      if (climate != null && daily == null)
        'Суточные данные не загружены — сроки посева указаны с точностью '
            'до месяца.',
      if (field.soilPh == null)
        'Не указан pH почвы — совместимость культур с почвой не проверена.',
      if (field.irrigation == null || field.irrigation == 'Нет данных')
        'Не указан тип орошения — принято, что дефицит воды можно '
            'закрыть поливом.',
      if (patterns == null && climate != null)
        'История погоды по годам не загружена — устойчивость к засушливым '
            'годам не проверена.',
      if (site.terrain == null)
        'Уклон участка не определён — риск эрозии не оценён.',
      if (site.soilType == null || site.soilType == 'Другое')
        'Не указан тип почвы — влагоёмкость принята средней.',
      if (soil == null || soil.salinity == null)
        'Засоление не указано — солеустойчивость культур не проверена.',
      if (soil == null || soil.groundwaterM == null)
        'Глубина грунтовых вод не указана.',
      if (soil == null || !soil.nutrientsKnown)
        'Нет данных анализа почвы (азот, фосфор, калий).',
      if (soil != null && !soil.isEmpty && !soil.fromLabTest)
        'Данные о почве — со слов фермера, без лабораторного анализа.',
      if (missingEconomics.isNotEmpty)
        'Нет цены, урожайности или затрат для: '
            '${missingEconomics.join(', ')} — для них доход оценён '
            'условным индексом 1–5.',
      if (region != null)
        ...region.notes
      else
        'Регион участка не определён: культуры взяты из общего '
            'справочника без местной настройки.',
    ];

    // --- Риски ---
    final risks = <String>[];
    for (final year in years) {
      final fit = year.main;
      final crop = fit.crop;

      if (fit.climateKnown) {
        if (fit.hotMonths > 0) {
          risks.add(
            '${crop.name}: ${fit.hotMonths} мес. цикла жарче допустимого '
            '(${crop.tMax.round()} °C) — риск теплового стресса.',
          );
        } else if (fit.peakTemperature != null &&
            fit.peakTemperature! >= crop.tMax + 9) {
          risks.add(
            '${crop.name}: в период роста бывали пики до '
            '${fit.peakTemperature!.round()} °C — возможен тепловой стресс.',
          );
        }
        if (fit.coldMonths > 0) {
          risks.add(
            '${crop.name}: ${fit.coldMonths} мес. цикла холоднее '
            'допустимого — сезон может оказаться коротким.',
          );
        }
        if (fit.frostMonths > 0) {
          risks.add(
            '${crop.name}: заморозки в ${fit.frostMonths} мес. цикла — '
            'нужно сверить сроки посева.',
          );
        }
        if (rainfed && fit.waterStress > 0.3) {
          risks.add(
            '${crop.name}: без орошения осадки не покрывают '
            '${(fit.waterStress * 100).round()}% потребности в воде.',
          );
        }
      }

      final ph = field.soilPh;
      if (ph != null && !_phOk(crop, ph)) {
        risks.add(
          '${crop.name}: pH почвы $ph вне оптимума '
          '${crop.phMin}–${crop.phMax}.',
        );
      }
    }

    if (repeats > 0) {
      risks.add(
        'Культуры одного семейства идут подряд — накапливаются общие '
        'вредители и болезни.',
      );
    }
    final returning = _shortReturns(years).toSet();
    if (years.length > 1 && returning.isNotEmpty) {
      risks.add(
        '${names(returning)} возвращается на поле раньше чем через '
        '$minReturnYears года — копятся вредители и болезни этой культуры.',
      );
    }
    if (secondCrops.isNotEmpty) {
      risks.add(
        'Повторный посев требует быстрой уборки предшественника и полива '
        'в самые жаркие месяцы — проверьте, хватит ли воды и времени.',
      );
    }
    if (covers.isNotEmpty) {
      risks.add(
        'Сроки покровных культур подобраны по климату внутри года и могут '
        'пересекаться с посевом следующей основной — уточните календарь.',
      );
    }
    for (final crop in perennials) {
      risks.add(
        '${crop.name} занимает поле несколько лет подряд: распашка и '
        'перевод на другую культуру требуют отдельного планирования.',
      );
    }
    if (kind != StrategyKind.current) {
      final currentIds = baseline?.years.map((y) => y.main.crop.id).toSet();
      final fresh = distinct
          .where((c) => !(currentIds?.contains(c.id) ?? false))
          .toList();
      if (fresh.isNotEmpty) {
        risks.add(
          'Новые для участка культуры (${names(fresh)}): проверьте с '
          'агрономом семена, технику, сроки и наличие сбыта.',
        );
      }
    }

    final salinity = soil?.salinity;
    final groundwater = soil?.groundwaterM;
    for (final crop in {
      ...crops,
      ...secondCrops,
      ...covers,
    }) {
      if (site.textureFit(crop) < 1) {
        risks.add(
          '${crop.name}: тип почвы «${site.soilType}» подходит плохо — '
          'нужна проверка на месте.',
        );
      }
      if (salinity != null && salinity != Salinity.none) {
        final threshold = crop.saltThreshold;
        if (threshold == null) {
          risks.add(
            '${crop.name}: солеустойчивость в справочнике не указана, а '
            'засоление ${salinity.label} — уточните у агронома.',
          );
        } else if (salinity.ece > threshold) {
          final loss = ((1 - site.salinityFit(crop)) * 100).round();
          risks.add(
            '${crop.name}: засоление ${salinity.label} (около '
            '${salinity.ece.round()} дС/м) выше порога культуры '
            '(${threshold.toStringAsFixed(1)} дС/м) — урожай может быть '
            'ниже примерно на $loss%.',
          );
        }
      }
      if (groundwater != null && site.waterloggingFit(crop) < 1) {
        risks.add(
          '${crop.name} плохо переносит близкие грунтовые воды '
          '(${groundwater.toStringAsFixed(1)} м).',
        );
      }
    }
    if (site.secondarySalinizationRisk) {
      risks.add(
        'Грунтовые воды ближе 2 м при поливе «${site.irrigationLabel}» — '
        'риск вторичного засоления; помогают дренаж и экономный полив.',
      );
    }
    final hungry = distinct.where((c) => c.nitrogenDemand >= 4).toList();
    for (final (nutrient, level) in [
      ('фосфора', soil?.phosphorus),
      ('калия', soil?.potassium),
    ]) {
      if (level == NutrientLevel.low && hungry.isNotEmpty) {
        risks.add(
          'По данным о почве мало $nutrient: культуры с высоким выносом '
          '(${names(hungry)}) без подкормки могут недобрать урожай — норму '
          'определяет агроном.',
        );
      }
    }

    final terrain = site.terrain;
    final avgBareMonths =
        years.map((y) => y.bareMonths).reduce((a, b) => a + b) / years.length;
    if (terrain != null && terrain.slopePercent >= 5 && avgBareMonths >= 4) {
      risks.add(
        'Уклон участка около ${terrain.slopePercent.toStringAsFixed(1)}% '
        '(SRTM), а поле ${avgBareMonths.toStringAsFixed(1)} мес. в году без '
        'покрова — риск смыва почвы.',
      );
    }

    for (final outcome in outcomes) {
      if (outcome.type.kind == YearKind.dry &&
          outcome.stressedCrops.isNotEmpty) {
        risks.add(
          'В засушливые годы (${(outcome.type.share * 100).round()}% лет) '
          'хуже подходят: ${outcome.stressedCrops.join(', ')}.',
        );
      }
    }

    if (patterns != null && climate != null) {
      evidence.add(
        'Модель типов лет обучена на устройстве по ${patterns.yearCount} '
        'годам NASA POWER (${patterns.firstYear}–${patterns.lastYear}): '
        'оценки усреднены по засушливым, обычным и влажным годам.',
      );
    }
    if (terrain != null) {
      evidence.add(
        'Рельеф: NASA SRTM — высота ${terrain.elevation.round()} м, уклон '
        '${terrain.slopePercent.toStringAsFixed(1)}% (${terrain.slopeLabel}).',
      );
    }

    final uniqueRisks = risks.toSet().toList();

    return RotationStrategy(
      kind: kind,
      title: _title(kind),
      years: years,
      scores: scores,
      total: scores.weighted(priorities),
      why: why,
      evidence: evidence,
      benefits: benefits,
      gaps: gaps,
      risks: uniqueRisks.isEmpty
          ? const ['Явных климатических рисков по имеющимся данным не видно.']
          : uniqueRisks,
      irrigationEfficiency: site.irrigationEfficiency,
      yearOutcomes: outcomes,
      marginPerHa: marginPerHa,
      missingEconomics: missingEconomics.toList(),
    );
  }

  static String _thousands(int value) {
    final digits = value.abs().toString();
    final buffer = StringBuffer(value < 0 ? '−' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        buffer.write(' ');
      }
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  static String formatMoney(double value, String currency) =>
      '${_thousands(value.round())} $currency';

  /// Пересчитывает севооборот для другого климата (типа года): сроки
  /// и водный баланс культур подбираются заново.
  List<RotationYear> _replay(
    List<RotationYear> years,
    ClimateSummary climate,
    SiteConditions site,
  ) {
    return [
      for (final year in years)
        () {
          final main = evaluateCrop(
            year.main.crop,
            climate,
            preferRain: site.rainfed,
            site: site,
          );

          CropFit? cover;
          final planned = year.cover;
          if (planned != null) {
            final free = {
              for (var month = 0; month < 12; month++)
                if (!main.months.contains(month)) month,
            };
            final fit = evaluateCrop(
              planned.crop,
              climate,
              allowedMonths: free,
              preferRain: true,
              site: site,
            );
            if (fit.startMonth != null && fit.suitability >= 0.75) {
              cover = fit;
            }
          }

          return year.withMain(main, cover: cover);
        }(),
    ];
  }

  String _title(StrategyKind kind) {
    switch (kind) {
      case StrategyKind.current:
        return 'Текущий севооборот';
      case StrategyKind.waterSaving:
        return 'Экономия воды';
      case StrategyKind.soilBuilding:
        return 'Восстановление почвы';
      case StrategyKind.incomeResilience:
        return 'Доход и устойчивость';
    }
  }

  String _shortPeriod(String period) {
    final years = RegExp(r'(19|20)\d{2}')
        .allMatches(period)
        .map((m) => m.group(0)!)
        .toList();
    return years.length >= 2 ? '${years.first}–${years.last}' : period;
  }

  List<String> _insights(
    Field field,
    ClimateSummary? climate,
    List<RotationYear> currentYears,
    SiteConditions site,
    ClimatePatterns? patterns, {
    DailyClimate? daily,
    ElevationCorrection? elevation,
  }) {
    if (climate == null) {
      return const [];
    }

    final insights = <String>[];

    if (elevation != null && elevation.significant) {
      insights.add(elevation.describe());
    }

    if (patterns != null) {
      final dry = patterns.dry;
      insights.add(
        'Модель типов лет (${patterns.firstYear}–${patterns.lastYear}): '
        'засушливых лет ${(dry.share * 100).round()}%, а за последние '
        '10 лет — ${(dry.recentShare * 100).round()}%.',
      );
      insights.add(
        'По водному балансу тёплого сезона засушливых лет '
        '${patterns.waterBalanceDryYears.length} из ${patterns.yearCount} '
        '(дефицит влаги на ${ClimatePatternModel.dryDeficitExtraMm.round()} мм '
        'больше обычных ${patterns.medianSeasonDeficitMm.round()} мм — это '
        '${(ClimatePatternModel.dryDeficitExtraMm * 10).round()} м³/га полива сверх нормы); из '
        '${dry.years.length} засушливых по модели совпадают '
        '${patterns.dryAgreement}. Индекс P/ET0 сезона в засушливые годы — '
        '${dry.seasonAridity.toStringAsFixed(2)} (${dry.aridityClass}).',
      );
      for (final trend in patterns.trends) {
        if (trend.significant) {
          insights.add('Тренд — ${trend.describe()}.');
        }
      }
    }

    final terrain = site.terrain;
    if (terrain != null) {
      insights.add(
        'Рельеф (SRTM): высота ${terrain.elevation.round()} м, уклон '
        '${terrain.slopePercent.toStringAsFixed(1)}% — '
        '${terrain.slopeLabel}.',
      );
    }

    final et0 = climate.et0Mm;
    final names = ClimateSummary.monthNames;

    final precip = climate.annualPrecipMm;
    final demand = climate.annualEt0Mm;
    insights.add(
      'Водный баланс: осадки ${precip.round()} мм в год против '
      '${demand.round()} мм эталонного испарения — '
      '${precip >= demand ? 'влаги в целом хватает' : 'осадки покрывают '
          '${(precip / demand * 100).round()}% испарения'}.',
    );

    final dry = [
      for (var m = 0; m < 12; m++)
        if (et0[m] > 30 && climate.precipMm[m] < 0.3 * et0[m]) names[m],
    ];
    if (dry.isNotEmpty) {
      insights.add('Самые засушливые месяцы: ${dry.join(', ')}.');
    }

    if (daily != null) {
      final safe = daily.springFrostSafeDay();
      final typical = daily.typicalLastSpringFrost();
      final autumn = daily.autumnFrostSafeDay();
      insights.add(
        safe < 0
            ? 'Весенних заморозков по суточным данным практически не бывает.'
            : 'Последний весенний заморозок обычно до '
                '${DailyClimate.formatDay(typical)}; после '
                '${DailyClimate.formatDay(safe)} риск не выше 10%. Первый '
                'осенний — с ${DailyClimate.formatDay(autumn)} с риском 10%; '
                'безморозный период около ${daily.frostFreeDays()} дней.',
      );
    } else {
      final frosty = [
        for (var m = 0; m < 12; m++)
          if (climate.frostDays[m] > 3) names[m],
      ];
      insights.add(
        frosty.isEmpty
            ? 'Месяцев с частыми заморозками нет.'
            : 'Заморозки вероятны: ${frosty.join(', ')} '
                '(около ${climate.annualFrostDays.round()} дней в год).',
      );
    }

    if (site.secondarySalinizationRisk) {
      insights.add(
        'Грунтовые воды ${site.soil!.groundwaterM!.toStringAsFixed(1)} м: '
        'при поливе «${site.irrigationLabel}» возможен подъём солей.',
      );
    }

    final lastYear = currentYears.last;
    final months = lastYear.main.months;
    if (months.isNotEmpty && lastYear.bareMonths > 0) {
      final bare = [
        for (var m = 0; m < 12; m++)
          if (!months.contains(m)) names[m],
      ];
      insights.add(
        'При культуре «${lastYear.main.crop.name}» поле без покрова '
        '${lastYear.bareMonths} мес.: ${bare.join(', ')} — окно для '
        'покровной культуры.',
      );
    }

    final wetness = climate.rootWetness;
    if (wetness != null) {
      var driest = 0;
      for (var m = 1; m < 12; m++) {
        if (wetness[m] < wetness[driest]) {
          driest = m;
        }
      }
      insights.add(
        'Влажность корнеобитаемого слоя минимальна в месяце '
        '«${names[driest]}» (${(wetness[driest] * 100).round()}% от '
        'насыщения, модельная оценка).',
      );
    }

    return insights;
  }
}

/// Экономика культур для оценки дохода.
class _Money {
  final Map<String, CropEconomics> economics;

  /// Лучшая маржа среди культур с полными данными — шкала для оценки 0–1.
  final double reference;

  const _Money(this.economics, this.reference);

  factory _Money.of(Map<String, CropEconomics> economics) {
    var best = 0.0;
    for (final item in economics.values) {
      final margin = item.margin();
      if (margin != null && margin > best) {
        best = margin;
      }
    }
    return _Money(economics, best);
  }

  bool known(CropProfile crop) =>
      reference > 0 && (economics[crop.id]?.complete ?? false);

  /// Вклад культуры в оценку дохода, 0–1.
  double yearValue(CropProfile crop, double fit, {double share = 1.0}) {
    final item = economics[crop.id];
    if (known(crop)) {
      return (item!.margin(yieldShare: fit * share)! / reference)
          .clamp(0.0, 1.0);
    }
    return share * crop.marketValue / 5 * fit;
  }

  /// Маржа в деньгах с гектара за год; null — данных хватает не для всех.
  double? margin(CropProfile crop, double fit, {double share = 1.0}) {
    return economics[crop.id]?.margin(yieldShare: fit * share);
  }
}
