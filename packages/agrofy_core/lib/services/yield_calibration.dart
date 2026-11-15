import 'dart:math' as math;

import '../data/crop_catalog.dart';
import '../models/climate_history.dart';
import '../models/crop_profile.dart';
import '../models/crop_season.dart';
import '../models/site_conditions.dart';
import 'rotation_advisor.dart';

/// Один год: фактический урожай фермера и климатическая оценка советника
/// для той же культуры в погоде того же года.
class YieldCheck {
  final int year;
  final CropProfile crop;
  final double yieldTHa;

  /// Соответствие погоде года по модели советника, 0–1; null — истории
  /// погоды за этот год нет.
  final double? climateFit;

  /// Урожай относительно среднего урожая этой культуры у фермера.
  final double relativeYield;

  const YieldCheck({
    required this.year,
    required this.crop,
    required this.yieldTHa,
    required this.climateFit,
    required this.relativeYield,
  });
}

/// Сверка оценок советника с урожаями фермера. Это проверка, а не
/// автоматическая подстройка: при малом числе лет связь случайна.
class YieldCalibration {
  /// Меньше этого числа лет связь не оценивается.
  static const int minimumPairs = 3;

  final List<YieldCheck> checks;

  /// Коэффициент корреляции Пирсона между оценкой и относительным
  /// урожаем; null — данных мало.
  final double? correlation;

  const YieldCalibration({required this.checks, this.correlation});

  int get pairs => checks.where((c) => c.climateFit != null).length;

  String get verdict {
    final r = correlation;
    if (r == null) {
      return 'Для сравнения нужно минимум $minimumPairs года с урожаем и '
          'загруженной историей погоды. Сейчас: $pairs.';
    }
    final strength = r >= 0.5
        ? 'оценка климата согласуется с вашими урожаями'
        : r > 0
            ? 'связь оценки с урожаями слабая'
            : 'оценка климата пока не подтверждается вашими урожаями — '
                'покажите записи агроному';
    return 'r = ${r.toStringAsFixed(2)} по $pairs годам: $strength. '
        'При малом числе лет это может быть случайностью; на урожай '
        'влияют и уход, и сорт, и цены на воду.';
  }

  static YieldCalibration compute({
    required Iterable<CropSeason> seasons,
    required ClimateHistory? history,
    required SiteConditions site,
    RotationAdvisor advisor = const RotationAdvisor(),
    double tempDelta = 0,
  }) {
    final recorded = [
      for (final season in seasons)
        if ((season.yieldTHa ?? 0) > 0 && CropCatalog.byId(season.cropId) != null)
          season,
    ]..sort((a, b) => a.year.compareTo(b.year));

    final averages = <String, double>{};
    for (final cropId in recorded.map((s) => s.cropId).toSet()) {
      final values = [
        for (final s in recorded)
          if (s.cropId == cropId) s.yieldTHa!,
      ];
      averages[cropId] = values.reduce((a, b) => a + b) / values.length;
    }

    final checks = <YieldCheck>[];
    for (final season in recorded) {
      final crop = CropCatalog.byId(season.cropId)!;
      final weather = history?.yearOf(season.year);

      double? fit;
      if (weather != null) {
        final climate = history!
            .summaryOf([weather])
            .adjusted(tempDelta: tempDelta);
        final result = advisor.evaluateCrop(
          crop,
          climate,
          preferRain: site.rainfed,
          site: site,
        );
        fit = result.suitability * site.siteFit(crop);
        if (site.rainfed) {
          fit *= (1 - result.waterStress * (6 - crop.droughtTolerance) / 5)
              .clamp(0.0, 1.0);
        }
      }

      checks.add(
        YieldCheck(
          year: season.year,
          crop: crop,
          yieldTHa: season.yieldTHa!,
          climateFit: fit,
          relativeYield: season.yieldTHa! / averages[season.cropId]!,
        ),
      );
    }

    final paired = checks.where((c) => c.climateFit != null).toList();
    double? correlation;
    if (paired.length >= minimumPairs) {
      correlation = pearson(
        paired.map((c) => c.climateFit!).toList(),
        paired.map((c) => c.relativeYield).toList(),
      );
    }

    return YieldCalibration(checks: checks, correlation: correlation);
  }

  /// Коэффициент Пирсона; null, если у одного из рядов нет разброса.
  static double? pearson(List<double> xs, List<double> ys) {
    final n = xs.length;
    final mx = xs.reduce((a, b) => a + b) / n;
    final my = ys.reduce((a, b) => a + b) / n;

    var sxy = 0.0;
    var sxx = 0.0;
    var syy = 0.0;
    for (var i = 0; i < n; i++) {
      sxy += (xs[i] - mx) * (ys[i] - my);
      sxx += (xs[i] - mx) * (xs[i] - mx);
      syy += (ys[i] - my) * (ys[i] - my);
    }

    if (sxx < 1e-12 || syy < 1e-12) {
      return null;
    }
    return sxy / math.sqrt(sxx * syy);
  }
}
