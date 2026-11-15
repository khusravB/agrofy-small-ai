import '../models/climate_summary.dart';

/// Наблюдение NDVI, импортированное из пакета данных.
class NdviPoint {
  final DateTime date;
  final double value;

  /// Надёжность пикселя: good, marginal, snow, cloudy, unknown.
  final String? quality;

  const NdviPoint({required this.date, required this.value, this.quality});

  bool get usable => quality == null || quality == 'good' || quality == 'marginal';
}

/// Сводка ряда NDVI для объяснений советника. Индекс — косвенный
/// показатель зелени: он не доказывает азот, pH, влажность или болезнь.
class NdviSummary {
  /// Ниже этого значения поверхность обычно почти без растительности.
  static const double bareThreshold = 0.2;

  final NdviPoint? latest;
  final NdviPoint? peak;
  final int usableCount;
  final int totalCount;

  /// Месяцы (0 — январь), в которые все надёжные наблюдения ниже порога.
  final List<int> bareMonths;

  const NdviSummary({
    this.latest,
    this.peak,
    required this.usableCount,
    required this.totalCount,
    required this.bareMonths,
  });

  static NdviSummary? of(List<NdviPoint> points) {
    if (points.isEmpty) {
      return null;
    }
    final usable = [for (final p in points) if (p.usable) p]
      ..sort((a, b) => a.date.compareTo(b.date));

    final byMonth = <int, List<double>>{};
    for (final p in usable) {
      byMonth.putIfAbsent(p.date.month - 1, () => []).add(p.value);
    }

    return NdviSummary(
      latest: usable.isEmpty ? null : usable.last,
      peak: usable.isEmpty
          ? null
          : usable.reduce((a, b) => b.value > a.value ? b : a),
      usableCount: usable.length,
      totalCount: points.length,
      bareMonths: [
        for (final entry in byMonth.entries)
          if (entry.value.every((v) => v < bareThreshold)) entry.key,
      ]..sort(),
    );
  }

  static String _day(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  String describe() {
    final parts = <String>[
      'NDVI MODIS (импорт, $usableCount надёжных из $totalCount снимков)',
    ];
    final last = latest;
    final top = peak;
    if (last != null) {
      parts.add('последнее ${last.value.toStringAsFixed(2)} на ${_day(last.date)}');
    }
    if (top != null && !identical(top, last)) {
      parts.add('максимум ${top.value.toStringAsFixed(2)} на ${_day(top.date)}');
    }
    var text = '${parts.first}: ${parts.skip(1).join(', ')}.';
    if (bareMonths.isNotEmpty) {
      text += ' Почти без растительности (NDVI < ${bareThreshold.toStringAsFixed(1)}): '
          '${bareMonths.map((m) => ClimateSummary.monthNames[m]).join(', ')}.';
    }
    return '$text Индекс — косвенный показатель зелени, не диагноз и не '
        'измерение азота, pH или влажности.';
  }
}
