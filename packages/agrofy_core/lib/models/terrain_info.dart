/// Рельеф участка по данным SRTM: высота и уклон.
class TerrainInfo {
  final double elevation;

  /// Уклон в процентах (подъём на 100 м по горизонтали).
  final double slopePercent;

  final DateTime fetchedAt;

  const TerrainInfo({
    required this.elevation,
    required this.slopePercent,
    required this.fetchedAt,
  });

  /// Риск водной эрозии от уклона, 0–1.
  double get erosionFactor {
    if (slopePercent < 2) {
      return 0;
    }
    return ((slopePercent - 2) / 10).clamp(0.0, 1.0);
  }

  String get slopeLabel {
    if (slopePercent < 2) {
      return 'ровный участок';
    }
    if (slopePercent < 5) {
      return 'слабый уклон';
    }
    if (slopePercent < 10) {
      return 'заметный уклон';
    }
    return 'крутой склон';
  }

  Map<String, dynamic> toMap(int fieldId) {
    return {
      'field_id': fieldId,
      'elevation': elevation,
      'slope_percent': slopePercent,
      'fetched_at': fetchedAt.toIso8601String(),
    };
  }

  factory TerrainInfo.fromMap(Map<String, dynamic> map) {
    return TerrainInfo(
      elevation: (map['elevation'] as num).toDouble(),
      slopePercent: (map['slope_percent'] as num).toDouble(),
      fetchedAt: DateTime.parse(map['fetched_at'] as String),
    );
  }
}
