/// Ботаническое семейство. Культуры одного семейства подряд
/// накапливают общих вредителей и болезни.
enum CropFamily {
  cereal('Злаковые'),
  legume('Бобовые'),
  malvaceae('Мальвовые'),
  solanaceae('Паслёновые'),
  asteraceae('Астровые'),
  brassica('Капустные'),
  allium('Луковые'),
  cucurbit('Тыквенные'),
  apiaceae('Зонтичные'),
  borage('Бурачниковые');

  final String label;

  const CropFamily(this.label);
}

/// Агрономический профиль культуры из встроенного справочника.
///
/// Значения — обобщённые ориентиры (FAO-56 и типовые агрономические
/// справочники), а не местные нормы: их должен сверять агроном.
class CropProfile {
  final String id;
  final String name;
  final CropFamily family;

  /// Длина цикла от посева до уборки, месяцев.
  final int cycleMonths;

  /// Для озимых: сколько месяцев цикла должно приходиться на активный рост.
  final int activeMonths;

  /// Озимая культура: переносит холодный период в состоянии покоя.
  final bool overwinters;

  /// Допустимый диапазон среднемесячной температуры в период роста, °C.
  final double tMin;
  final double tMax;

  /// Переносит заморозки в период роста.
  final bool frostTolerant;

  /// Средний за сезон коэффициент культуры Kc (доля от эталонного испарения).
  final double kc;

  /// Типовая потребность в воде за сезон, мм — используется без данных климата.
  final double waterNeedMm;

  /// Оценки 1–5.
  final int droughtTolerance;
  final int nitrogenDemand;
  final int residue;
  final int groundCover;
  final int marketValue;

  /// Глубина корней: 1 — мелкая, 2 — средняя, 3 — глубокая.
  final int rootDepth;

  final bool nitrogenFixing;
  final bool forage;

  final double phMin;
  final double phMax;

  /// Покровная (промежуточная) культура, а не основная.
  final bool isCover;

  /// Подходит как повторная культура: второй урожай после ранней уборки.
  final bool secondCrop;

  /// Порог солеустойчивости: электропроводность почвенной вытяжки ECe,
  /// дС/м, до которой урожай не снижается. Ориентиры FAO (Ayers & Westcot,
  /// 1985) и Maas–Hoffman; null — в справочнике нет надёжного значения.
  final double? saltThreshold;

  /// Плохо переносит переувлажнение и близкие грунтовые воды.
  final bool waterloggingSensitive;

  /// Сколько лет подряд культура может занимать поле (многолетние).
  final int perennialYears;

  const CropProfile({
    required this.id,
    required this.name,
    required this.family,
    required this.cycleMonths,
    this.activeMonths = 0,
    this.overwinters = false,
    required this.tMin,
    required this.tMax,
    this.frostTolerant = false,
    required this.kc,
    required this.waterNeedMm,
    required this.droughtTolerance,
    required this.nitrogenDemand,
    required this.residue,
    required this.groundCover,
    required this.marketValue,
    required this.rootDepth,
    this.nitrogenFixing = false,
    this.forage = false,
    this.phMin = 6.0,
    this.phMax = 7.5,
    this.isCover = false,
    this.secondCrop = false,
    this.saltThreshold,
    this.waterloggingSensitive = false,
    this.perennialYears = 1,
  });

  bool get isPerennial => perennialYears > 1;

  /// Сколько месяцев активного роста нужно культуре.
  int get requiredActiveMonths => overwinters ? activeMonths : cycleMonths;
}
