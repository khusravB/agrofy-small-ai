import 'dart:convert';

/// Что именно наблюдается на поле.
enum ObservationAttribute {
  leaves('Листья'),
  soil('Почва'),
  weather('Погода'),
  pests('Вредители'),
  growth('Рост'),
  soilMoisture('Влажность почвы');

  final String label;

  const ObservationAttribute(this.label);
}

/// Откуда известно значение.
enum EvidenceSource {
  selectedByUser('выбрано в карточке участка'),
  farmerReport('сообщил фермер'),
  measurement('измерение'),
  eventLog('журнал участка'),
  nasaClimate('климат NASA'),
  ai('предположение модели');

  final String label;

  const EvidenceSource(this.label);
}

/// Насколько значение подтверждено.
enum EvidenceStatus {
  /// Сообщено пользователем или измерено.
  observed('наблюдение'),

  /// Предположение по признакам или от модели — не факт.
  inferred('предположение'),

  /// Данных нет.
  unknown('неизвестно');

  final String label;

  const EvidenceStatus(this.label);
}

/// Допустимые значения признаков — контракт между интерпретатором,
/// валидатором и движком решений.
class ObservationSchema {
  static const Map<ObservationAttribute, Map<String, String>> values = {
    ObservationAttribute.leaves: {
      'yellowing': 'желтеют',
      'wilting': 'вянут',
      'drying': 'сохнут',
      'spots': 'пятна',
      'healthy': 'здоровые',
    },
    ObservationAttribute.soil: {
      'dry': 'сухая',
      'wet': 'переувлажнена',
      'crusted': 'корка',
      'normal': 'в норме',
    },
    ObservationAttribute.weather: {
      'hot': 'жарко',
      'cold': 'холодно',
      'frost': 'заморозок',
      'rain': 'дожди',
      'wind': 'сильный ветер',
    },
    ObservationAttribute.pests: {
      'present': 'есть',
      'absent': 'нет',
    },
    ObservationAttribute.growth: {
      'slow': 'замедлен',
      'lodging': 'полегание',
      'normal': 'в норме',
    },
  };

  static bool isValid(ObservationAttribute attribute, String value) {
    if (attribute == ObservationAttribute.soilMoisture) {
      final number = double.tryParse(value);
      return number != null && number >= 0 && number <= 100;
    }
    return values[attribute]?.containsKey(value) ?? false;
  }

  static String describe(ObservationAttribute attribute, String value) {
    if (attribute == ObservationAttribute.soilMoisture) {
      return '$value%';
    }
    return values[attribute]?[value] ?? value;
  }
}

/// Одно извлечённое значение с источником и статусом.
class ObservedFact {
  final ObservationAttribute attribute;
  final String value;
  final EvidenceSource source;
  final EvidenceStatus status;

  /// Фрагмент исходного текста, из которого взято значение.
  final String? quote;

  /// Фермер выразил неуверенность («кажется», «вроде»).
  final bool hedged;

  const ObservedFact({
    required this.attribute,
    required this.value,
    required this.source,
    required this.status,
    this.quote,
    this.hedged = false,
  });

  String get label =>
      '${attribute.label}: ${ObservationSchema.describe(attribute, value)}';

  Map<String, dynamic> toJson() {
    return {
      'attribute': attribute.name,
      'value': value,
      'source': source.name,
      'status': status.name,
      'quote': quote,
      'hedged': hedged,
    };
  }

  static ObservedFact? fromJson(Map<String, dynamic> json) {
    ObservationAttribute? attribute;
    for (final candidate in ObservationAttribute.values) {
      if (candidate.name == json['attribute']) {
        attribute = candidate;
      }
    }
    final value = json['value'];
    if (attribute == null ||
        value is! String ||
        !ObservationSchema.isValid(attribute, value)) {
      return null;
    }

    return ObservedFact(
      attribute: attribute,
      value: value,
      source: EvidenceSource.values.firstWhere(
        (s) => s.name == json['source'],
        orElse: () => EvidenceSource.farmerReport,
      ),
      status: EvidenceStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => EvidenceStatus.observed,
      ),
      quote: json['quote'] as String?,
      hedged: json['hedged'] as bool? ?? false,
    );
  }
}

/// Наблюдение фермера в структурированном виде.
class FieldObservation {
  final String text;
  final DateTime date;

  /// Культура: из текста или из карточки участка.
  final String? cropId;
  final EvidenceSource cropSource;

  final List<ObservedFact> facts;

  const FieldObservation({
    required this.text,
    required this.date,
    this.cropId,
    this.cropSource = EvidenceSource.selectedByUser,
    this.facts = const [],
  });

  Iterable<ObservedFact> of(ObservationAttribute attribute) =>
      facts.where((fact) => fact.attribute == attribute);

  bool has(ObservationAttribute attribute, String value) =>
      of(attribute).any((fact) => fact.value == value);

  /// Измеренная влажность почвы, %, если она есть.
  double? get soilMoisture {
    for (final fact in of(ObservationAttribute.soilMoisture)) {
      return double.tryParse(fact.value);
    }
    return null;
  }

  String encodeFacts() => jsonEncode(facts.map((f) => f.toJson()).toList());

  static List<ObservedFact> decodeFacts(String payload) {
    try {
      return [
        for (final item in jsonDecode(payload) as List)
          ?ObservedFact.fromJson(item as Map<String, dynamic>),
      ];
    } on Object {
      return const [];
    }
  }
}
