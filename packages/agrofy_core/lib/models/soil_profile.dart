/// Засоление почвы по классам. [ece] — середина класса, дС/м.
enum Salinity {
  none('нет', 1.0),
  slight('слабое', 3.0),
  moderate('среднее', 6.0),
  strong('сильное', 10.0);

  final String label;
  final double ece;

  const Salinity(this.label, this.ece);
}

enum NutrientLevel {
  low('низкий'),
  medium('средний'),
  high('высокий');

  final String label;

  const NutrientLevel(this.label);
}

/// Почва участка со слов фермера или по анализу. Со спутника эти
/// показатели не определить, поэтому все поля необязательны: пустое
/// значение — «неизвестно», а не «в норме».
class SoilProfile {
  final Salinity? salinity;

  /// Глубина грунтовых вод, м.
  final double? groundwaterM;

  /// Гумус, %.
  final double? humusPct;

  final NutrientLevel? nitrogen;
  final NutrientLevel? phosphorus;
  final NutrientLevel? potassium;

  /// Данные из лабораторного анализа, а не на глаз.
  final bool fromLabTest;

  final DateTime updatedAt;

  const SoilProfile({
    this.salinity,
    this.groundwaterM,
    this.humusPct,
    this.nitrogen,
    this.phosphorus,
    this.potassium,
    this.fromLabTest = false,
    required this.updatedAt,
  });

  bool get isEmpty =>
      salinity == null &&
      groundwaterM == null &&
      humusPct == null &&
      nitrogen == null &&
      phosphorus == null &&
      potassium == null;

  bool get nutrientsKnown =>
      nitrogen != null || phosphorus != null || potassium != null;

  String get sourceLabel => fromLabTest ? 'анализ почвы' : 'со слов фермера';

  /// Короткое описание для объяснений.
  List<String> summary() {
    return [
      if (salinity != null) 'засоление ${salinity!.label}',
      if (groundwaterM != null)
        'грунтовые воды ${groundwaterM!.toStringAsFixed(1)} м',
      if (humusPct != null) 'гумус ${humusPct!.toStringAsFixed(1)}%',
      if (nitrogen != null) 'азот ${nitrogen!.label}',
      if (phosphorus != null) 'фосфор ${phosphorus!.label}',
      if (potassium != null) 'калий ${potassium!.label}',
    ];
  }

  static T? _enum<T extends Enum>(List<T> values, Object? name) {
    for (final value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return null;
  }

  Map<String, dynamic> toMap(int fieldId) {
    return {
      'field_id': fieldId,
      'salinity': salinity?.name,
      'groundwater_m': groundwaterM,
      'humus_pct': humusPct,
      'nitrogen': nitrogen?.name,
      'phosphorus': phosphorus?.name,
      'potassium': potassium?.name,
      'from_lab': fromLabTest ? 1 : 0,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory SoilProfile.fromMap(Map<String, dynamic> map) {
    return SoilProfile(
      salinity: _enum(Salinity.values, map['salinity']),
      groundwaterM: (map['groundwater_m'] as num?)?.toDouble(),
      humusPct: (map['humus_pct'] as num?)?.toDouble(),
      nitrogen: _enum(NutrientLevel.values, map['nitrogen']),
      phosphorus: _enum(NutrientLevel.values, map['phosphorus']),
      potassium: _enum(NutrientLevel.values, map['potassium']),
      fromLabTest: (map['from_lab'] as int? ?? 0) == 1,
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}
