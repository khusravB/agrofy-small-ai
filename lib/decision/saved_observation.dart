import 'decision_engine.dart';
import 'observation.dart';

/// Наблюдение, сохранённое в памяти поля вместе с решением движка.
class SavedObservation {
  final int? id;
  final int fieldId;
  final DateTime date;
  final String text;
  final String? cropId;
  final List<ObservedFact> facts;
  final DecisionCode code;
  final DecisionStatus status;
  final String action;

  /// Предыдущее наблюдение, после рекомендации которого сделана эта запись.
  final int? followsId;

  const SavedObservation({
    this.id,
    required this.fieldId,
    required this.date,
    required this.text,
    this.cropId,
    required this.facts,
    required this.code,
    required this.status,
    required this.action,
    this.followsId,
  });

  factory SavedObservation.from({
    required int fieldId,
    required FieldObservation observation,
    required Recommendation recommendation,
    int? followsId,
  }) {
    return SavedObservation(
      fieldId: fieldId,
      date: observation.date,
      text: observation.text,
      cropId: observation.cropId,
      facts: observation.facts,
      code: recommendation.code,
      status: recommendation.status,
      action: recommendation.action,
      followsId: followsId,
    );
  }

  /// Рекомендация ждёт проверки: следующая запись будет её результатом.
  bool get awaitsFollowUp =>
      code != DecisionCode.recordOnly && code != DecisionCode.askClarification;

  FieldObservation get observation {
    return FieldObservation(
      text: text,
      date: date,
      cropId: cropId,
      facts: facts,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'field_id': fieldId,
      'date': date.toIso8601String(),
      'text': text,
      'crop_id': cropId,
      'facts': observation.encodeFacts(),
      'decision_code': code.name,
      'decision_status': status.name,
      'action': action,
      'follows_id': followsId,
    };
  }

  factory SavedObservation.fromMap(Map<String, dynamic> map) {
    return SavedObservation(
      id: map['id'] as int?,
      fieldId: map['field_id'] as int,
      date: DateTime.parse(map['date'] as String),
      text: map['text'] as String,
      cropId: map['crop_id'] as String?,
      facts: FieldObservation.decodeFacts(map['facts'] as String),
      code: DecisionCode.values.firstWhere(
        (code) => code.name == map['decision_code'],
        orElse: () => DecisionCode.recordOnly,
      ),
      status: DecisionStatus.values.firstWhere(
        (status) => status.name == map['decision_status'],
        orElse: () => DecisionStatus.ready,
      ),
      action: map['action'] as String,
      followsId: map['follows_id'] as int?,
    );
  }
}

/// Learning from Outcomes: сопоставляет рекомендацию и следующее
/// наблюдение. Это сравнение записей, а не доказательство, что помогло
/// именно действие.
class OutcomeReview {
  static const String caveat =
      'Это сравнение двух записей. Оно не доказывает, что изменение вызвано '
      'именно вашим действием: на результат влияют погода, место и точность '
      'измерения.';

  /// Что изменилось между прошлым наблюдением и новым.
  static List<String> compare(
    SavedObservation previous,
    FieldObservation current,
  ) {
    final changes = <String>[];
    final before = previous.observation;

    final moistureBefore = before.soilMoisture;
    final moistureNow = current.soilMoisture;
    if (moistureNow != null) {
      changes.add(
        moistureBefore == null
            ? 'Влажность почвы теперь измерена: ${moistureNow.round()}% '
                '(раньше измерения не было).'
            : 'Влажность почвы: было ${moistureBefore.round()}%, стало '
                '${moistureNow.round()}%.',
      );
    }

    for (final attribute in const [
      ObservationAttribute.leaves,
      ObservationAttribute.soil,
      ObservationAttribute.pests,
      ObservationAttribute.growth,
    ]) {
      String describe(FieldObservation observation) {
        final values = observation
            .of(attribute)
            .map((f) => ObservationSchema.describe(attribute, f.value))
            .join(', ');
        return values.isEmpty ? 'не отмечено' : values;
      }

      final was = describe(before);
      final now = describe(current);
      if (was != now) {
        changes.add('${attribute.label}: было — $was, стало — $now.');
      }
    }

    if (changes.isEmpty) {
      changes.add('По записанным признакам изменений нет.');
    }
    return changes;
  }
}
