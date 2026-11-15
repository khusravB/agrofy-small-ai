import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/climate_history.dart';
import '../models/climate_summary.dart';
import '../models/daily_climate.dart';

/// Загружает многолетнюю климатическую сводку точки из NASA POWER.
///
/// Сеть нужна только для первой загрузки: результат кэшируется в локальной
/// БД, и советник дальше работает офлайн.
class NasaPowerService {
  static const String _host = 'power.larc.nasa.gov';
  static const String _path = '/api/temporal/climatology/point';

  static const List<String> parameters = [
    'T2M',
    'T2M_RANGE',
    'T2M_MAX',
    'PRECTOTCORR',
    'FROST_DAYS',
    'GWETROOT',
  ];

  final http.Client _client;

  NasaPowerService({http.Client? client}) : _client = client ?? http.Client();

  Future<ClimateSummary> fetchClimatology({
    required double latitude,
    required double longitude,
  }) async {
    final uri = Uri.https(_host, _path, {
      'parameters': parameters.join(','),
      'community': 'AG',
      'latitude': latitude.toStringAsFixed(4),
      'longitude': longitude.toStringAsFixed(4),
      'format': 'JSON',
    });

    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception(
        'NASA POWER ответил с кодом ${response.statusCode}',
      );
    }

    return ClimateSummary.fromPowerJson(
      jsonDecode(response.body) as Map<String, dynamic>,
      latitude: latitude,
      longitude: longitude,
      fetchedAt: DateTime.now(),
    );
  }

  static const String _monthlyPath = '/api/temporal/monthly/point';

  /// Первый год истории: с него доступны все нужные параметры.
  static const int historyStartYear = 1991;

  /// Загружает помесячную историю по годам — на ней обучается модель
  /// типов лет и считаются тренды.
  Future<ClimateHistory> fetchHistory({
    required double latitude,
    required double longitude,
  }) async {
    final now = DateTime.now();

    final uri = Uri.https(_host, _monthlyPath, {
      'parameters': 'T2M,T2M_RANGE,PRECTOTCORR,FROST_DAYS,GWETROOT',
      'community': 'AG',
      'latitude': latitude.toStringAsFixed(4),
      'longitude': longitude.toStringAsFixed(4),
      'start': '$historyStartYear',
      'end': '${now.year - 1}',
      'format': 'JSON',
    });

    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 45));

    if (response.statusCode != 200) {
      throw Exception(
        'NASA POWER ответил с кодом ${response.statusCode}',
      );
    }

    return ClimateHistory.fromPowerJson(
      jsonDecode(response.body) as Map<String, dynamic>,
      latitude: latitude,
      longitude: longitude,
      fetchedAt: now,
    );
  }

  static const String _dailyPath = '/api/temporal/daily/point';

  /// Загружает суточные температуры за [historyStartYear]…прошлый год —
  /// для дат заморозков и сроков посева по декадам.
  Future<DailyClimate> fetchDaily({
    required double latitude,
    required double longitude,
  }) async {
    final now = DateTime.now();

    final uri = Uri.https(_host, _dailyPath, {
      'parameters': 'T2M,T2M_MIN',
      'community': 'AG',
      'latitude': latitude.toStringAsFixed(4),
      'longitude': longitude.toStringAsFixed(4),
      'start': '${historyStartYear}0101',
      'end': '${now.year - 1}1231',
      'format': 'JSON',
    });

    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception(
        'NASA POWER ответил с кодом ${response.statusCode}',
      );
    }

    return DailyClimate.fromPowerJson(
      jsonDecode(response.body) as Map<String, dynamic>,
      latitude: latitude,
      longitude: longitude,
      fetchedAt: now,
    );
  }
}
