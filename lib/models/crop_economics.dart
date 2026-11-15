import 'crop_season.dart';

/// Экономика культуры, которую вводит фермер: цена, урожайность, затраты.
/// Встроенных цен нет: без ввода советник считает доход условным индексом.
class CropEconomics {
  final String cropId;

  /// Цена реализации за тонну.
  final double? pricePerT;

  /// Урожайность, т/га.
  final double? yieldTHa;

  /// Затраты на гектар за сезон.
  final double? costPerHa;

  /// Урожайность взята из записей фермера по годам, а не введена вручную.
  final bool yieldFromRecords;

  /// По скольким годам посчитана урожайность из записей.
  final int recordYears;

  const CropEconomics({
    required this.cropId,
    this.pricePerT,
    this.yieldTHa,
    this.costPerHa,
    this.yieldFromRecords = false,
    this.recordYears = 0,
  });

  bool get complete =>
      pricePerT != null && yieldTHa != null && costPerHa != null;

  /// Выручка минус затраты на гектар при доле урожая [yieldShare].
  double? margin({double yieldShare = 1.0}) {
    if (!complete) {
      return null;
    }
    return pricePerT! * yieldTHa! * yieldShare - costPerHa!;
  }

  Map<String, dynamic> toMap() {
    return {
      'crop_id': cropId,
      'price_per_t': pricePerT,
      'yield_t_ha': yieldTHa,
      'cost_per_ha': costPerHa,
    };
  }

  factory CropEconomics.fromMap(Map<String, dynamic> map) {
    return CropEconomics(
      cropId: map['crop_id'] as String,
      pricePerT: (map['price_per_t'] as num?)?.toDouble(),
      yieldTHa: (map['yield_t_ha'] as num?)?.toDouble(),
      costPerHa: (map['cost_per_ha'] as num?)?.toDouble(),
    );
  }

  /// Подставляет среднюю урожайность из записей фермера вместо введённой
  /// вручную: собственные данные точнее справочных ожиданий.
  static Map<String, CropEconomics> withRecordedYields(
    Map<String, CropEconomics> entered,
    Iterable<CropSeason> seasons,
  ) {
    final yields = <String, List<double>>{};
    for (final season in seasons) {
      final value = season.yieldTHa;
      if (value != null && value > 0) {
        yields.putIfAbsent(season.cropId, () => []).add(value);
      }
    }

    final result = <String, CropEconomics>{...entered};

    yields.forEach((cropId, values) {
      final average = values.reduce((a, b) => a + b) / values.length;
      final base = entered[cropId];
      result[cropId] = CropEconomics(
        cropId: cropId,
        pricePerT: base?.pricePerT,
        costPerHa: base?.costPerHa,
        yieldTHa: average,
        yieldFromRecords: true,
        recordYears: values.length,
      );
    });

    return result;
  }
}
