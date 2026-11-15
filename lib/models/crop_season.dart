/// Этап жизненного цикла культуры на участке.
enum CropStage {
  planning('Планирование'),
  sowing('Посев'),
  germination('Всходы'),
  vegetative('Вегетация'),
  flowering('Цветение'),
  fruiting('Плодоношение'),
  harvest('Уборка'),
  completed('Завершено');

  final String label;

  const CropStage(this.label);

  /// Названия этапов из схемы БД до версии 6.
  static const Map<String, CropStage> _legacy = {
    'planned': planning,
    'sown': sowing,
    'growing': vegetative,
    'harvested': completed,
  };

  static CropStage parse(Object? name) {
    for (final stage in values) {
      if (stage.name == name) {
        return stage;
      }
    }
    return _legacy[name] ?? completed;
  }
}

/// Жизненный цикл культуры на участке в конкретном году: что посеяно,
/// на каком этапе и с каким результатом. Последовательность таких записей —
/// фактический севооборот участка.
class CropSeason {
  final int? id;
  final int fieldId;
  final int year;

  /// Идентификатор культуры из встроенного справочника.
  final String cropId;

  final CropStage stage;
  final DateTime? sownAt;
  final DateTime? harvestedAt;

  /// Урожайность, т/га — основа для будущей калибровки оценок.
  final double? yieldTHa;

  final String? note;

  const CropSeason({
    this.id,
    required this.fieldId,
    required this.year,
    required this.cropId,
    this.stage = CropStage.completed,
    this.sownAt,
    this.harvestedAt,
    this.yieldTHa,
    this.note,
  });

  CropSeason copyWith({
    String? cropId,
    CropStage? stage,
    DateTime? sownAt,
    DateTime? harvestedAt,
    double? yieldTHa,
  }) {
    return CropSeason(
      id: id,
      fieldId: fieldId,
      year: year,
      cropId: cropId ?? this.cropId,
      stage: stage ?? this.stage,
      sownAt: sownAt ?? this.sownAt,
      harvestedAt: harvestedAt ?? this.harvestedAt,
      yieldTHa: yieldTHa ?? this.yieldTHa,
      note: note,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'field_id': fieldId,
      'year': year,
      'crop_id': cropId,
      'stage': stage.name,
      'sown_at': sownAt?.toIso8601String(),
      'harvested_at': harvestedAt?.toIso8601String(),
      'yield_t_ha': yieldTHa,
      'note': note,
    };
  }

  factory CropSeason.fromMap(Map<String, dynamic> map) {
    DateTime? date(String key) {
      final value = map[key] as String?;
      return value == null ? null : DateTime.tryParse(value);
    }

    return CropSeason(
      id: map['id'] as int?,
      fieldId: map['field_id'] as int,
      year: map['year'] as int,
      cropId: map['crop_id'] as String,
      stage: CropStage.parse(map['stage']),
      sownAt: date('sown_at'),
      harvestedAt: date('harvested_at'),
      yieldTHa: (map['yield_t_ha'] as num?)?.toDouble(),
      note: map['note'] as String?,
    );
  }
}
