import 'data_package.dart';

/// Пакет данных в виде короткого текста для SMS — для тех, у кого нет
/// интернета, чтобы скачать файл. Значения те же, что в пакете.
class PackageText {
  static const List<String> _months = [
    'янв', 'фев', 'мар', 'апр', 'май', 'июн',
    'июл', 'авг', 'сен', 'окт', 'ноя', 'дек',
  ];

  static String _day(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

  static String _num(double v, int digits) =>
      v.toStringAsFixed(digits).replaceFirst('-', '−');

  /// Предложения с данными пакета, по порядку важности.
  static List<String> describe(DataPackage package) {
    final lines = <String>[];
    for (final dataset in package.datasets) {
      final ndvi = dataset.observations.where((o) => o.variable == 'ndvi').toList()
        ..sort((a, b) => a.date.compareTo(b.date));
      if (ndvi.isNotEmpty) {
        lines.addAll(_ndvi(ndvi));
      }
      final climate = dataset.observations.where((o) => o.variable != 'ndvi').toList();
      if (climate.isNotEmpty) {
        lines.addAll(_climate(climate));
      }
    }
    return lines;
  }

  static List<String> _ndvi(List<PackageObservation> points) {
    bool usable(PackageObservation o) =>
        o.quality == null || o.quality == 'good' || o.quality == 'marginal';
    final good = points.where(usable).toList();
    final lines = <String>[];
    if (good.isNotEmpty) {
      final last = good.last;
      final peak = good.reduce((a, b) => b.value > a.value ? b : a);
      lines.add('NDVI MODIS (250 м): последнее ${_num(last.value, 2)} на ${_day(last.date)}, '
          'максимум ${_num(peak.value, 2)} на ${_day(peak.date)}.');
    }

    // Длинные ряды (HISTORY) — средние по месяцам, короткие — каждая дата.
    if (points.length > 12) {
      final byMonth = <String, List<double>>{};
      for (final o in good) {
        final key = '${o.date.month.toString().padLeft(2, '0')}.${(o.date.year % 100).toString().padLeft(2, '0')}';
        byMonth.putIfAbsent(key, () => []).add(o.value);
      }
      final entries = [
        for (final e in byMonth.entries)
          '${e.key} ${_num(e.value.reduce((a, b) => a + b) / e.value.length, 2)}',
      ];
      lines.add('По месяцам: ${entries.join('; ')}.');
    } else {
      final entries = [
        for (final o in points) '${_day(o.date)} ${_num(o.value, 2)}${usable(o) ? '' : ' обл.'}',
      ];
      lines.add('Снимки: ${entries.join('; ')}.');
    }
    if (points.any((o) => !usable(o))) {
      lines.add('«обл.» — облачность или снег, значение ненадёжно.');
    }
    lines.add('NDVI ниже 0.2 — почти без растительности. Это не диагноз.');
    return lines;
  }

  static List<String> _climate(List<PackageObservation> observations) {
    final months = <DateTime, Map<String, List<double>>>{};
    for (final o in observations) {
      final key = DateTime.utc(o.date.year, o.date.month);
      months.putIfAbsent(key, () => {}).putIfAbsent(o.variable, () => []).add(o.value);
    }
    final keys = months.keys.toList()..sort();
    final entries = <String>[];
    for (final key in keys) {
      final m = months[key]!;
      final t = m['t2m'];
      final tMin = m['t2m_min'];
      final rain = m['precipitation'];
      final parts = <String>[
        if (t != null) '${_num(t.reduce((a, b) => a + b) / t.length, 0)}°',
        if (tMin != null) 'мин ${_num(tMin.reduce((a, b) => a < b ? a : b), 0)}°',
        if (rain != null) '${rain.reduce((a, b) => a + b).round()} мм',
      ];
      final label = keys.length > 12
          ? '${_months[key.month - 1]}${(key.year % 100).toString().padLeft(2, '0')}'
          : _months[key.month - 1];
      entries.add('$label ${parts.join(' ')}');
    }
    return [
      'Климат NASA POWER по месяцам (средняя t, минимум, осадки): ${entries.join('; ')}.',
    ];
  }
}
