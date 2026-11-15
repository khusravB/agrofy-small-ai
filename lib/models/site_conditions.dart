import 'crop_profile.dart';
import 'field.dart';
import 'terrain_info.dart';

/// Условия участка, которые меняют расчёт воды и почвы: способ полива,
/// механический состав почвы и уклон.
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

  const SiteConditions({
    this.rainfed = false,
    this.irrigationEfficiency = 0.65,
    this.irrigationKnown = false,
    this.irrigationLabel = 'способ полива не указан',
    this.rainShare = 0.75,
    this.needFactor = 1.0,
    this.soilType,
    this.terrain,
  });

  static const _lightSoilCrops = {'potato', 'carrot', 'peanut', 'melon', 'onion'};

  factory SiteConditions.of(Field field, {TerrainInfo? terrain}) {
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
}
