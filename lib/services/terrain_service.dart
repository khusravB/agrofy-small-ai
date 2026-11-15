import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../models/terrain_info.dart';

/// Получает высоту и уклон участка по модели рельефа NASA SRTM (30 м)
/// через открытый сервис OpenTopoData. Результат кэшируется в локальной БД.
class TerrainService {
  static const String _host = 'api.opentopodata.org';
  static const String _path = '/v1/srtm30m';

  /// Шаг между точками замера, метров.
  static const double stepMeters = 90;

  final http.Client _client;

  TerrainService({http.Client? client}) : _client = client ?? http.Client();

  Future<TerrainInfo> fetch({
    required double latitude,
    required double longitude,
  }) async {
    final dLat = stepMeters / 111320;
    final dLon =
        stepMeters / (111320 * math.cos(latitude * math.pi / 180).abs());

    // Центр и четыре соседа: север, юг, восток, запад.
    final points = [
      [latitude, longitude],
      [latitude + dLat, longitude],
      [latitude - dLat, longitude],
      [latitude, longitude + dLon],
      [latitude, longitude - dLon],
    ];

    final uri = Uri.https(_host, _path, {
      'locations': points
          .map((p) => '${p[0].toStringAsFixed(5)},${p[1].toStringAsFixed(5)}')
          .join('|'),
    });

    final response =
        await _client.get(uri).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception('Сервис рельефа ответил с кодом ${response.statusCode}');
    }

    return parse(
      jsonDecode(response.body) as Map<String, dynamic>,
      fetchedAt: DateTime.now(),
    );
  }

  /// Считает уклон по центральным разностям высот.
  static TerrainInfo parse(
    Map<String, dynamic> json, {
    required DateTime fetchedAt,
  }) {
    final results = json['results'] as List?;
    if (results == null || results.length < 5) {
      throw const FormatException('Сервис рельефа: неполный ответ');
    }

    final heights = results.map((item) {
      final value = (item as Map<String, dynamic>)['elevation'] as num?;
      if (value == null) {
        throw const FormatException('Сервис рельефа: нет высоты для точки');
      }
      return value.toDouble();
    }).toList();

    final northSouth = (heights[1] - heights[2]) / (2 * stepMeters);
    final eastWest = (heights[3] - heights[4]) / (2 * stepMeters);
    final slope =
        math.sqrt(northSouth * northSouth + eastWest * eastWest) * 100;

    return TerrainInfo(
      elevation: heights[0],
      slopePercent: slope,
      fetchedAt: fetchedAt,
    );
  }
}
