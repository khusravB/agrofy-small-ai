import 'crop_profile.dart';
import 'field.dart';
import 'soil_profile.dart';
import 'terrain_info.dart';

/// Условия участка, которые меняют расчёт воды и почвы: способ полива,
/// механический состав почвы, уклон, засоление, грунтовые воды и питание.
class SiteConditions {
  final bool rainfed;

  /// КПД способа полива: какая доля поданной воды доходит до растений.
  final double irrigationEfficiency;
  final bool irrigationKnown;
  final String irrigationLabel;

  /// Доля осадков, которую удерживает почва для растений.
  final double rainShare;

  /// Поправка к потребности в воде (лёгкие почвы быстрее пересыхают).
  final double needFactor;

  final String? soilType;
  final TerrainInfo? terrain;

  /// Почва со слов фермера или по анализу; null — ничего не известно.
  final SoilProfile? soil;

  const SiteConditions({
    this.rainfed = false,
    this.irrigationEfficiency = 0.65,
    this.irrigationKnown = false,
    this.irrigationLabel = 'способ полива не указан',
    this.rainShare = 0.75,
    this.needFactor = 1.0,
    this.soilType,
    this.terrain,
    this.soil,
  });

  static const _lightSoilCrops = {'potato', 'carrot', 'peanut', 'melon', 'onion'};

  factory SiteConditions.of(
    Field field, {
    TerrainInfo? terrain,
    SoilProfile? soil,
  }) {
    var efficiency = 0.65;
    var known = true;
    var label = 'способ полива не указан';

    switch (field.irrigation) {
      case 'Капельное':
        efficiency = 0.9;
        label = 'капельный полив';
      case 'Дождевальное':
        efficiency = 0.75;
        label = 'дождевание';
      case 'Поверхностное':
        efficiency = 0.6;
        label = 'полив по бороздам';
      case 'Без орошения':
        efficiency = 1.0;
        label = 'без орошения';
      default:
        known = false;
    }

    var rainShare = 0.75;
    var needFactor = 1.0;

    switch (field.soilType) {
      case 'Песчаная':
        rainShare = 0.6;
        needFactor = 1.1;
      case 'Супесчаная':
        rainShare = 0.7;
        needFactor = 1.05;
    }

    return SiteConditions(
      rainfed: field.irrigation == 'Без орошения',
      irrigationEfficiency: efficiency,
      irrigationKnown: known,
      irrigationLabel: label,
      rainShare: rainShare,
      needFactor: needFactor,
      soilType: field.soilType,
      terrain: terrain,
      soil: soil,
    );
  }

  double get erosionFactor => terrain?.erosionFactor ?? 0;

  /// Насколько механический состав почвы подходит культуре, 0–1.
  double textureFit(CropProfile crop) {
    switch (soilType) {
      case 'Глинистая':
        // Корнеплоды и бахчевые плохо переносят тяжёлые плотные почвы.
        return _lightSoilCrops.contains(crop.id) ? 0.4 : 1.0;
      case 'Песчаная':
        // Рис не удержит слой воды на песке.
        return crop.id == 'rice' ? 0.2 : 1.0;
      default:
        return 1.0;
    }
  }

  /// Доля урожая при засолении по модели Маасса — Хоффмана: до порога
  /// культуры потерь нет, выше — около 10% на каждый дС/м. Наклон 10% —
  /// усреднение; у разных культур он от 5 до 20%.
  double salinityFit(CropProfile crop) {
    final salinity = soil?.salinity;
    final threshold = crop.saltThreshold;
    if (salinity == null || threshold == null || salinity.ece <= threshold) {
      return 1.0;
    }
    return (1 - 0.1 * (salinity.ece - threshold)).clamp(0.0, 1.0);
  }

  /// Близкие грунтовые воды угнетают культуры, не переносящие
  /// переувлажнения.
  double waterloggingFit(CropProfile crop) {
    final depth = soil?.groundwaterM;
    if (depth == null || !crop.waterloggingSensitive) {
      return 1.0;
    }
    if (depth < 1.0) {
      return 0.6;
    }
    if (depth < 1.5) {
      return 0.85;
    }
    return 1.0;
  }

  /// Насколько участок в целом подходит культуре, 0–1.
  double siteFit(CropProfile crop) =>
      textureFit(crop) * salinityFit(crop) * waterloggingFit(crop);

  /// Грунтовые воды ближе 2 м при поливе по бороздам или дождевании
  /// поднимают соли к поверхности.
  bool get secondarySalinizationRisk {
    final depth = soil?.groundwaterM;
    return depth != null &&
        depth < 2.0 &&
        !rainfed &&
        irrigationLabel != 'капельный полив';
  }

  /// Вес азотного баланса в оценке почвы: при бедной азотом почве
  /// бобовые ценнее.
  double get nitrogenWeight =>
      soil?.nitrogen == NutrientLevel.low ? 0.4 : 0.3;

  /// Вес органического вещества: при низком гумусе остатки ценнее.
  double get organicWeight {
    final humus = soil?.humusPct;
    return humus != null && humus < 1.0 ? 0.35 : 0.25;
  }
}
