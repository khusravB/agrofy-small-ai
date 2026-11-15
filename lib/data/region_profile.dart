import '../models/field.dart';

/// Региональная настройка советника: какие культуры типичны для района
/// и о каких местных рисках нужно напомнить.
class RegionProfile {
  final String name;

  final double latMin;
  final double latMax;
  final double lonMin;
  final double lonMax;

  /// Названия мест — запасной способ определить регион без координат.
  final List<String> placeNames;

  /// Основные и покровные культуры, типичные для региона.
  final Set<String> cropIds;

  /// Местные ограничения, которые советник не видит в данных.
  final List<String> notes;

  /// Валюта для расчёта дохода.
  final String currency;

  const RegionProfile({
    required this.name,
    required this.latMin,
    required this.latMax,
    required this.lonMin,
    required this.lonMax,
    required this.placeNames,
    required this.cropIds,
    required this.notes,
    this.currency = 'у. е.',
  });

  /// Согдийская область Таджикистана. Рамка координат приблизительная и
  /// захватывает соседние районы Ферганской долины со схожими условиями.
  static const sughd = RegionProfile(
    name: 'Согдийская область',
    currency: 'сомони',
    latMin: 39.0,
    latMax: 41.1,
    lonMin: 67.3,
    lonMax: 70.9,
    placeNames: [
      'согд',
      'худжанд',
      'хуҷанд',
      'истаравшан',
      'исфара',
      'канибадам',
      'конибодом',
      'пенджикент',
      'панҷакент',
      'бустон',
      'гулистон',
      'зафаробод',
      'матча',
      'мастчо',
      'ашт',
      'спитамен',
      'гафуров',
    ],
    cropIds: {
      // Основные.
      'cotton', 'wheat', 'barley', 'maize', 'sorghum', 'rice', //
      'potato', 'vegetables', 'onion', 'carrot', 'melon', //
      'sunflower', 'safflower', //
      'alfalfa', 'mung', 'chickpea', 'beans', 'peanut',
      // Покровные.
      'rye', 'pea', 'rapeseed', 'mustard',
    },
    notes: [
      'На орошаемых землях региона встречаются засоление и близкие '
          'грунтовые воды — в данных советника их нет, нужен анализ почвы.',
      'Часть земель орошается насосами: расход воды стоит сверять с '
          'лимитом и графиком подачи вашей ассоциации водопользователей.',
    ],
  );

  static const List<RegionProfile> all = [sughd];

  bool contains(double latitude, double longitude) {
    return latitude >= latMin &&
        latitude <= latMax &&
        longitude >= lonMin &&
        longitude <= lonMax;
  }

  /// Определяет регион участка по координатам, а без них — по названию места.
  static RegionProfile? detect(Field field) {
    final latitude = field.latitude;
    final longitude = field.longitude;

    for (final region in all) {
      if (latitude != null && longitude != null) {
        if (region.contains(latitude, longitude)) {
          return region;
        }
        continue;
      }

      final location = field.location.toLowerCase();
      if (region.placeNames.any(location.contains)) {
        return region;
      }
    }

    return null;
  }
}
