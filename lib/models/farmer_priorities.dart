import 'dart:convert';

/// Приоритеты фермера: веса от 0 до 1 для каждой цели.
class FarmerPriorities {
  final double water;
  final double soil;
  final double income;
  final double resilience;

  /// Длина севооборота, лет (3–5).
  final int rotationYears;

  const FarmerPriorities({
    this.water = 0.5,
    this.soil = 0.5,
    this.income = 0.5,
    this.resilience = 0.5,
    this.rotationYears = 3,
  });

  FarmerPriorities copyWith({
    double? water,
    double? soil,
    double? income,
    double? resilience,
    int? rotationYears,
  }) {
    return FarmerPriorities(
      water: water ?? this.water,
      soil: soil ?? this.soil,
      income: income ?? this.income,
      resilience: resilience ?? this.resilience,
      rotationYears: rotationYears ?? this.rotationYears,
    );
  }

  String encode() {
    return jsonEncode({
      'water': water,
      'soil': soil,
      'income': income,
      'resilience': resilience,
      'rotationYears': rotationYears,
    });
  }

  factory FarmerPriorities.decode(String payload) {
    final json = jsonDecode(payload) as Map<String, dynamic>;

    double read(String key) => (json[key] as num?)?.toDouble() ?? 0.5;

    return FarmerPriorities(
      water: read('water'),
      soil: read('soil'),
      income: read('income'),
      resilience: read('resilience'),
      rotationYears:
          ((json['rotationYears'] as num?)?.toInt() ?? 3).clamp(3, 5),
    );
  }
}
