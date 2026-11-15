import '../data/crop_catalog.dart';
import '../models/climate_summary.dart';
import '../models/field.dart';
import '../models/field_event.dart';
import 'observation.dart';

/// Что известно об участке на момент наблюдения.
class EvidenceContext {
  final Field field;

  /// Записи журнала участка.
  final List<FieldEvent> events;

  final ClimateSummary? climate;

  /// Этап культуры в текущем году известен из жизненного цикла.
  final bool stageKnown;

  const EvidenceContext({
    required this.field,
    this.events = const [],
    this.climate,
    this.stageKnown = false,
  });
}

/// Противоречие между источниками. Валидатор не выбирает, кто прав.
class Contradiction {
  final String message;
  final List<EvidenceSource> sources;

  const Contradiction(this.message, this.sources);
}

class EvidenceReport {
  final FieldObservation observation;

  /// Каких данных не хватает для решения.
  final List<String> missing;

  final List<Contradiction> contradictions;

  /// Случай нужно показать агроному.
  final bool needsExpert;

  /// Контекст из журнала и климата — со своим источником.
  final List<String> context;

  const EvidenceReport({
    required this.observation,
    this.missing = const [],
    this.contradictions = const [],
    this.needsExpert = false,
    this.context = const [],
  });

  bool get hasFacts => observation.facts.isNotEmpty;
}

/// Agronomic Evidence Validator: проверяет источники, полноту и
/// противоречия. Неизвестное остаётся неизвестным и не подменяется
/// догадкой.
class EvidenceValidator {
  /// Полив считается недавним в течение стольких дней.
  static const int recentIrrigationDays = 3;

  const EvidenceValidator();

  EvidenceReport validate(FieldObservation observation, EvidenceContext ctx) {
    final missing = <String>[];
    final contradictions = <Contradiction>[];
    final context = <String>[];

    final moisture = observation.soilMoisture;
    final soilDry = observation.has(ObservationAttribute.soil, 'dry');
    final soilWet = observation.has(ObservationAttribute.soil, 'wet');
    final leaves = observation.of(ObservationAttribute.leaves).toList();
    final leafStress = leaves.any((fact) => fact.value != 'healthy');

    // --- Противоречия ---

    FieldEvent? lastIrrigation;
    for (final event in ctx.events) {
      if (event.type != FieldEventType.irrigation ||
          event.date.isAfter(observation.date)) {
        continue;
      }
      if (lastIrrigation == null || event.date.isAfter(lastIrrigation.date)) {
        lastIrrigation = event;
      }
    }

    if (lastIrrigation != null) {
      final days = observation.date.difference(lastIrrigation.date).inDays;
      context.add(
        'Последний полив по журналу: $days дн. назад '
        '(${EvidenceSource.eventLog.label}).',
      );

      if (soilDry && days <= recentIrrigationDays) {
        contradictions.add(
          Contradiction(
            'Вы сообщаете, что почва сухая, но в журнале записан полив '
            '$days дн. назад. Проверьте, где и на какой глубине смотрели '
            'почву и дошла ли вода до этого места.',
            const [EvidenceSource.farmerReport, EvidenceSource.eventLog],
          ),
        );
      }
    }

    if (moisture != null) {
      if (soilDry && moisture >= 60) {
        contradictions.add(
          Contradiction(
            'Почва описана как сухая, но измеренная влажность '
            '${moisture.round()}%. Уточните место и глубину измерения.',
            const [EvidenceSource.farmerReport, EvidenceSource.measurement],
          ),
        );
      }
      if (soilWet && moisture <= 20) {
        contradictions.add(
          Contradiction(
            'Почва описана как переувлажнённая, но измеренная влажность '
            '${moisture.round()}%. Уточните место и глубину измерения.',
            const [EvidenceSource.farmerReport, EvidenceSource.measurement],
          ),
        );
      }
    }

    if (soilDry && soilWet) {
      contradictions.add(
        const Contradiction(
          'Почва описана и как сухая, и как переувлажнённая. Возможно, речь '
          'о разных частях поля — уточните.',
          [EvidenceSource.farmerReport],
        ),
      );
    }

    if (leafStress && leaves.any((fact) => fact.value == 'healthy')) {
      contradictions.add(
        const Contradiction(
          'Листья описаны и как здоровые, и как повреждённые. Уточните, '
          'какая часть растений затронута.',
          [EvidenceSource.farmerReport],
        ),
      );
    }

    final climate = ctx.climate;
    if (climate != null) {
      final month = observation.date.month - 1;
      final normal = climate.tMean[month];
      context.add(
        'Норма месяца: ${normal.round()} °C, '
        '${climate.precipMm[month].round()} мм осадков '
        '(${EvidenceSource.nasaClimate.label}, многолетнее среднее).',
      );

      if (observation.has(ObservationAttribute.weather, 'hot') && normal < 12) {
        contradictions.add(
          Contradiction(
            'Вы сообщаете о жаре, а многолетняя норма этого месяца — '
            '${normal.round()} °C. Данные NASA — это средний климат, а не '
            'погода этих дней; если жара была, она необычна для сезона.',
            const [EvidenceSource.farmerReport, EvidenceSource.nasaClimate],
          ),
        );
      }
      if (observation.has(ObservationAttribute.weather, 'frost') &&
          normal > 18 &&
          climate.frostDays[month] < 0.5) {
        contradictions.add(
          Contradiction(
            'Вы сообщаете о заморозке, а в этом месяце по многолетним '
            'данным их практически не бывает (норма ${normal.round()} °C). '
            'Уточните дату и температуру.',
            const [EvidenceSource.farmerReport, EvidenceSource.nasaClimate],
          ),
        );
      }
    }

    // --- Недостающие данные ---

    if (moisture == null && (soilDry || soilWet || leafStress)) {
      missing.add(
        'Влажность почвы на глубине корней не измерена — есть только '
        'описание на глаз.',
      );
    }
    if (observation.of(ObservationAttribute.weather).isNotEmpty) {
      missing.add(
        'Погода записана со слов, без измерения температуры или осадков.',
      );
    }
    if (!ctx.stageKnown) {
      missing.add('Этап развития культуры в этом году не отмечен.');
    }
    if (lastIrrigation == null &&
        ctx.field.irrigation != 'Без орошения' &&
        (soilDry || leafStress)) {
      missing.add('В журнале нет записей о поливах — дата последнего неизвестна.');
    }
    if (observation.cropId == null ||
        CropCatalog.byId(observation.cropId) == null) {
      missing.add('Культура не определена.');
    }
    if (observation.facts.any((fact) => fact.hedged)) {
      missing.add(
        'Наблюдение записано с оговоркой («кажется», «вроде») — его стоит '
        'перепроверить.',
      );
    }

    final needsExpert =
        observation.has(ObservationAttribute.pests, 'present') ||
            observation.has(ObservationAttribute.leaves, 'spots');

    return EvidenceReport(
      observation: observation,
      missing: missing,
      contradictions: contradictions,
      needsExpert: needsExpert,
      context: context,
    );
  }
}
