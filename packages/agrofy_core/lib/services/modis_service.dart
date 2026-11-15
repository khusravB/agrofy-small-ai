import 'dart:convert';

import 'package:http/http.dart' as http;

/// Одно наблюдение NDVI MODIS.
class NdviObservation {
  final DateTime date;
  final double ndvi;

  /// Надёжность пикселя MOD13Q1: good, marginal, snow, cloudy, unknown.
  final String reliability;

  const NdviObservation({
    required this.date,
    required this.ndvi,
    required this.reliability,
  });

  bool get usable => reliability == 'good' || reliability == 'marginal';
}

/// Ряд NDVI MODIS Terra (MOD13Q1, 250 м, 16 дней) для точки через открытый
/// веб-сервис NASA ORNL DAAC. Регистрация не нужна.
class ModisService {
  static const String _host = 'modis.ornl.gov';
  static const String product = 'MOD13Q1';
  static const String ndviBand = '250m_16_days_NDVI';
  static const String reliabilityBand = '250m_16_days_pixel_reliability';

  /// Сервис отдаёт не больше 10 дат за запрос.
  static const int datesPerRequest = 10;

  static const Map<int, String> _reliability = {
    0: 'good',
    1: 'marginal',
    2: 'snow',
    3: 'cloudy',
  };

  final http.Client _client;

  ModisService({http.Client? client}) : _client = client ?? http.Client();

  Future<Map<String, dynamic>> _get(String path, Map<String, String> query) async {
    final response = await _client
        .get(
          Uri.https(_host, '/rst/api/v1/$product/$path', query),
          headers: {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw Exception('MODIS ORNL ответил с кодом ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<NdviObservation>> fetchNdvi({
    required double latitude,
    required double longitude,
    required DateTime start,
    required DateTime end,
  }) async {
    final point = {
      'latitude': latitude.toStringAsFixed(4),
      'longitude': longitude.toStringAsFixed(4),
    };

    final dates = (await _get('dates', point))['dates'] as List;
    final wanted = [
      for (final item in dates)
        if (_inRange(item['calendar_date'] as String, start, end))
          item['modis_date'] as String,
    ];

    final result = <NdviObservation>[];
    for (var i = 0; i < wanted.length; i += datesPerRequest) {
      final chunk = wanted.sublist(i, (i + datesPerRequest).clamp(0, wanted.length));
      final query = {
        ...point,
        'startDate': chunk.first,
        'endDate': chunk.last,
        'kmAboveBelow': '0',
        'kmLeftRight': '0',
      };

      final ndvi = await _get('subset', {...query, 'band': ndviBand});
      final reliability = await _get('subset', {...query, 'band': reliabilityBand});
      final scale = double.tryParse('${ndvi['scale']}') ?? 0.0001;

      final flags = {
        for (final item in reliability['subset'] as List)
          item['calendar_date'] as String: (item['data'] as List).first as int,
      };

      for (final item in ndvi['subset'] as List) {
        final raw = (item['data'] as List).first as int;
        if (raw <= -3000) {
          continue; // значение-заглушка: наблюдения нет
        }
        final date = item['calendar_date'] as String;
        result.add(
          NdviObservation(
            date: DateTime.parse(date),
            ndvi: raw * scale,
            reliability: _reliability[flags[date]] ?? 'unknown',
          ),
        );
      }
    }

    result.sort((a, b) => a.date.compareTo(b.date));
    return result;
  }

  static bool _inRange(String date, DateTime start, DateTime end) {
    final value = DateTime.parse(date);
    return !value.isBefore(start) && !value.isAfter(end);
  }
}
