
enum FieldEventType {
  planting,
  irrigation,
  fertilization,
  observation,
  pestOrDisease,
}

class FieldEvent {
  final int? id;
  final int fieldId;
  final FieldEventType type;
  final String title;
  final String description;
  final DateTime date;

  // Optional structured values
  final double? quantity;
  final String? unit;

  const FieldEvent({
    this.id,
    required this.fieldId,
    required this.type,
    required this.title,
    required this.description,
    required this.date,
    this.quantity,
    this.unit,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'field_id': fieldId,
      'type': type.name,
      'title': title,
      'description': description,
      'date': date.toIso8601String(),
      'quantity': quantity,
      'unit': unit,
    };
  }

  factory FieldEvent.fromMap(Map<String, dynamic> map) {
    return FieldEvent(
      id: map['id'] as int?,
      fieldId: map['field_id'] as int,
      type: FieldEventType.values.firstWhere(
        (type) => type.name == map['type'],
        orElse: () => FieldEventType.observation,
      ),
      title: map['title'] as String,
      description: map['description'] as String,
      date: DateTime.parse(map['date'] as String),
      quantity: (map['quantity'] as num?)?.toDouble(),
      unit: map['unit'] as String?,
    );
  }
}
