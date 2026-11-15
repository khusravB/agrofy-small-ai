import '../data/crop_catalog.dart';
import 'evidence_validator.dart';
import 'observation.dart';

/// Технический результат движка решений.
enum DecisionCode {
  askClarification,
  resolveConflict,
  consultAgronomist,
  checkFrostDamage,
  verifySoilMoisture,
  reviewIrrigation,
  checkWaterlogging,
  monitor,
  recordOnly,
}

enum DecisionStatus {
  ready('Можно действовать'),
  needsVerification('Нужна проверка'),
  insufficientEvidence('Недостаточно данных'),
  needsExpert('Нужен агроном');

  final String label;

  const DecisionStatus(this.label);
}

enum ActionPriority {
  high('высокий'),
  medium('средний'),
  low('низкий');

  final String label;

  const ActionPriority(this.label);
}

/// Шаг плана полевых действий.
class ActionStep {
  final String title;

  /// Через сколько дней выполнить (0 — сегодня).
  final int dueInDays;

  final ActionPriority priority;

  /// Что записать по итогам.
  final String result;

  const ActionStep({
    required this.title,
    required this.dueInDays,
    required this.priority,
    required this.result,
  });
}

/// Рекомендация в виде, понятном фермеру.
class Recommendation {
  final DecisionCode code;
  final DecisionStatus status;
  final String action;
  final String reason;
  final List<String> evidence;
  final List<String> missing;

  /// Три варианта: минимальный, сбалансированный, более глубокий.
  final List<String> alternatives;

  final String expectedOutcome;
  final List<ActionStep> plan;

  const Recommendation({
    required this.code,
    required this.status,
    required this.action,
    required this.reason,
    required this.evidence,
    required this.missing,
    required this.alternatives,
    required this.expectedOutcome,
    required this.plan,
  });
}

/// Agricultural Decision Engine.
///
/// Детерминированные правила: одинаковый вход всегда даёт одинаковое
/// решение, и оно не зависит от текста языковой модели. Правила намеренно
/// осторожны — при нехватке данных движок просит измерение, а не выдаёт
/// предписание. Правила составлены разработчиками и требуют проверки
/// агрономом.
class DecisionEngine {
  const DecisionEngine();

  Recommendation decide(EvidenceReport report) {
    final observation = report.observation;
    final moisture = observation.soilMoisture;

    final evidence = [
      for (final fact in observation.facts)
        '${fact.label} — ${fact.source.label}, ${fact.status.label}',
      ...report.context,
    ];

    Recommendation build({
      required DecisionCode code,
      required DecisionStatus status,
      required String action,
      required String reason,
      required List<String> alternatives,
      required String expectedOutcome,
      required List<ActionStep> plan,
    }) {
      return Recommendation(
        code: code,
        status: status,
        action: action,
        reason: reason,
        evidence: evidence,
        missing: report.missing,
        alternatives: alternatives,
        expectedOutcome: expectedOutcome,
        plan: plan,
      );
    }

    // Только то, что сообщил фермер или измерено: предположения модели
    // не запускают правила.
    bool observed(ObservationAttribute attribute, String value) {
      return observation.of(attribute).any((fact) {
        return fact.value == value && fact.status == EvidenceStatus.observed;
      });
    }

    final leafStress = ['yellowing', 'wilting', 'drying']
        .any((value) => observed(ObservationAttribute.leaves, value));
    final soilDry = observed(ObservationAttribute.soil, 'dry');
    final soilWet = observed(ObservationAttribute.soil, 'wet');

    final observedFacts = observation.facts
        .where((fact) => fact.status == EvidenceStatus.observed)
        .toList();

    // 1. Нет ни одного подтверждённого признака.
    if (observedFacts.isEmpty) {
      return build(
        code: DecisionCode.askClarification,
        status: DecisionStatus.insufficientEvidence,
        action: 'Опишите наблюдение подробнее',
        reason: 'Из текста не удалось выделить признаки состояния листьев, '
            'почвы, погоды или вредителей.',
        alternatives: const [
          'Минимально: напишите, что именно вы видите на листьях и почве.',
          'Сбалансированно: добавьте измерение — влажность почвы в процентах.',
          'Подробнее: сделайте запись в журнале участка с датой и количеством.',
        ],
        expectedOutcome: 'Появятся данные, по которым можно предложить '
            'следующий шаг. Текст наблюдения при этом сохраняется.',
        plan: const [
          ActionStep(
            title: 'Уточнить наблюдение',
            dueInDays: 0,
            priority: ActionPriority.medium,
            result: 'Запись с конкретными признаками',
          ),
        ],
      );
    }

    // 2. Источники противоречат друг другу.
    if (report.contradictions.isNotEmpty) {
      return build(
        code: DecisionCode.resolveConflict,
        status: DecisionStatus.needsVerification,
        action: 'Сначала проверьте противоречие в данных',
        reason: report.contradictions.map((c) => c.message).join(' '),
        alternatives: const [
          'Минимально: осмотрите то же место ещё раз и уточните запись.',
          'Сбалансированно: измерьте влажность в 3–5 точках поля на глубине '
              'корней.',
          'Подробнее: проверьте, равномерно ли дошла вода по полю, и '
              'запишите результат по частям участка.',
        ],
        expectedOutcome: 'Станет ясно, какие данные верны. До этого система '
            'не выбирает, какому источнику верить, и не предлагает действий '
            'с культурой.',
        plan: const [
          ActionStep(
            title: 'Повторно осмотреть место наблюдения',
            dueInDays: 0,
            priority: ActionPriority.high,
            result: 'Уточнённое наблюдение',
          ),
          ActionStep(
            title: 'Измерить влажность почвы в нескольких точках',
            dueInDays: 1,
            priority: ActionPriority.high,
            result: 'Влажность в процентах по точкам',
          ),
        ],
      );
    }

    // 3. Вредители или пятна — нужен специалист.
    if (report.needsExpert) {
      return build(
        code: DecisionCode.consultAgronomist,
        status: DecisionStatus.needsExpert,
        action: 'Покажите растения агроному',
        reason: 'Отмечены вредители или пятна на листьях. Определить причину '
            'и подобрать защиту по описанию нельзя — нужен осмотр.',
        alternatives: const [
          'Минимально: сфотографируйте повреждения и отметьте, какая доля '
              'растений затронута.',
          'Сбалансированно: осмотрите поле по диагонали и запишите, где очаги.',
          'Подробнее: передайте образцы и записи агроному или в службу '
              'защиты растений.',
        ],
        expectedOutcome: 'Причина будет установлена специалистом. Приложение '
            'не назначает препараты и дозы.',
        plan: const [
          ActionStep(
            title: 'Зафиксировать повреждения: фото, доля растений, очаги',
            dueInDays: 0,
            priority: ActionPriority.high,
            result: 'Запись в журнале участка',
          ),
          ActionStep(
            title: 'Связаться с агрономом',
            dueInDays: 1,
            priority: ActionPriority.high,
            result: 'Заключение специалиста',
          ),
        ],
      );
    }

    // 4. Заморозок на культуре, которая его не переносит.
    final crop = CropCatalog.byId(observation.cropId);
    if (observed(ObservationAttribute.weather, 'frost') &&
        crop != null &&
        !crop.frostTolerant) {
      return build(
        code: DecisionCode.checkFrostDamage,
        status: DecisionStatus.needsVerification,
        action: 'Оцените повреждение растений после заморозка',
        reason: 'Сообщается о заморозке, а культура «${crop.name}» по '
            'справочнику его не переносит.',
        alternatives: const [
          'Минимально: осмотрите растения через 2–3 дня, когда повреждения '
              'станут видны.',
          'Сбалансированно: подсчитайте долю погибших растений на нескольких '
              'участках поля.',
          'Подробнее: обсудите с агрономом подсев или пересев, если '
              'повреждена большая часть.',
        ],
        expectedOutcome: 'Будет понятна доля повреждённых растений. Решение '
            'о пересеве принимает фермер вместе с агрономом.',
        plan: const [
          ActionStep(
            title: 'Осмотреть растения и подсчитать повреждённые',
            dueInDays: 2,
            priority: ActionPriority.high,
            result: 'Доля повреждённых растений',
          ),
        ],
      );
    }

    // 5. Есть признаки стресса, но влажность не измерена.
    if ((leafStress || soilDry || soilWet) && moisture == null) {
      return build(
        code: DecisionCode.verifySoilMoisture,
        status: DecisionStatus.needsVerification,
        action: soilWet && !soilDry
            ? 'Не добавляйте полив, пока не проверите влажность у корней'
            : 'Проверьте влажность почвы возле корней',
        reason: soilWet && !soilDry
            ? 'При влажной почве так часто проявляется переувлажнение. '
                'Но это предположение: влажность на глубине корней не '
                'измерена, а те же признаки бывают при болезнях и нехватке '
                'питания.'
            : 'Признаки могут говорить о водном стрессе, но это только '
                'предположение: влажность на глубине корней не измерена. Те же '
                'признаки бывают при переувлажнении, болезнях и нехватке питания.',
        alternatives: const [
          'Минимально: возьмите ком почвы с глубины 15–20 см и оцените его '
              'на ощупь.',
          'Сбалансированно: измерьте влажность в 3–5 точках и запишите '
              'проценты в наблюдение.',
          'Подробнее: повторяйте измерение перед каждым поливом, чтобы '
              'сверять график с фактом.',
        ],
        expectedOutcome: 'Появится измерение, по которому можно судить, '
            'нужен ли пересмотр полива. До измерения менять полив не '
            'предлагается.',
        plan: const [
          ActionStep(
            title: 'Измерить влажность почвы на глубине корней',
            dueInDays: 0,
            priority: ActionPriority.high,
            result: 'Влажность в процентах',
          ),
          ActionStep(
            title: 'Записать результат новым наблюдением',
            dueInDays: 0,
            priority: ActionPriority.medium,
            result: 'Наблюдение с измерением',
          ),
        ],
      );
    }

    // 6. Измерение показывает сухую почву при признаках стресса.
    if (moisture != null && moisture < 25 && (leafStress || soilDry)) {
      return build(
        code: DecisionCode.reviewIrrigation,
        status: DecisionStatus.ready,
        action: 'Сверьте график полива с потребностью культуры',
        reason: 'Измеренная влажность ${moisture.round()}% низкая, и есть '
            'признаки стресса растений.',
        alternatives: const [
          'Минимально: проверьте, когда был последний полив и дошла ли вода '
              'до этой части поля.',
          'Сбалансированно: сверьте норму и интервал полива с расчётом '
              'потребности на вкладке «Советник» и ведите замеры влажности.',
          'Подробнее: обсудите с агрономом мульчирование или смену способа '
              'полива, если нехватка воды повторяется.',
        ],
        expectedOutcome: 'После корректировки повторное измерение через '
            '2–3 дня должно показать более высокую влажность. Это не '
            'гарантия: на результат влияют погода и состояние почвы.',
        plan: const [
          ActionStep(
            title: 'Проверить дату и равномерность последнего полива',
            dueInDays: 0,
            priority: ActionPriority.high,
            result: 'Запись о поливе в журнале',
          ),
          ActionStep(
            title: 'Повторно измерить влажность',
            dueInDays: 3,
            priority: ActionPriority.medium,
            result: 'Влажность в процентах',
          ),
        ],
      );
    }

    // 7. Измерение показывает избыток влаги при пожелтении.
    if (moisture != null && moisture > 70 && (leafStress || soilWet)) {
      return build(
        code: DecisionCode.checkWaterlogging,
        status: DecisionStatus.ready,
        action: 'Проверьте, нет ли застоя воды',
        reason: 'Измеренная влажность ${moisture.round()}% высокая. '
            'Пожелтение и увядание бывают и при переувлажнении.',
        alternatives: const [
          'Минимально: осмотрите пониженные места поля на застой воды.',
          'Сбалансированно: сделайте паузу до следующего замера и '
              'проверьте сток воды с участка.',
          'Подробнее: обсудите с агрономом дренаж и режим полива.',
        ],
        expectedOutcome: 'Повторное измерение через 2–3 дня покажет, уходит '
            'ли лишняя влага. Результат зависит от погоды и типа почвы.',
        plan: const [
          ActionStep(
            title: 'Осмотреть поле на застой воды',
            dueInDays: 0,
            priority: ActionPriority.high,
            result: 'Запись о состоянии участка',
          ),
          ActionStep(
            title: 'Повторно измерить влажность',
            dueInDays: 3,
            priority: ActionPriority.medium,
            result: 'Влажность в процентах',
          ),
        ],
      );
    }

    // 8. Есть отклонения, но они не требуют срочных действий.
    final concerns = observed(ObservationAttribute.growth, 'slow') ||
        observed(ObservationAttribute.growth, 'lodging') ||
        observed(ObservationAttribute.soil, 'crusted') ||
        leafStress ||
        observed(ObservationAttribute.weather, 'hot') ||
        observed(ObservationAttribute.weather, 'frost');

    if (concerns) {
      return build(
        code: DecisionCode.monitor,
        status: DecisionStatus.ready,
        action: 'Понаблюдайте и запишите повторный осмотр',
        reason: 'Есть отклонения, но по имеющимся данным они не указывают '
            'на конкретную причину.',
        alternatives: const [
          'Минимально: осмотрите поле ещё раз через 2–3 дня.',
          'Сбалансированно: добавьте замер влажности и отметьте этап '
              'развития культуры.',
          'Подробнее: если признаки усиливаются, покажите растения агроному.',
        ],
        expectedOutcome: 'Повторная запись покажет, усиливаются ли признаки.',
        plan: const [
          ActionStep(
            title: 'Повторный осмотр поля',
            dueInDays: 3,
            priority: ActionPriority.medium,
            result: 'Новое наблюдение',
          ),
        ],
      );
    }

    // 9. Тревожных признаков нет.
    return build(
      code: DecisionCode.recordOnly,
      status: DecisionStatus.ready,
      action: 'Сохраните наблюдение в историю поля',
      reason: 'Тревожных признаков в наблюдении нет.',
      alternatives: const [
        'Минимально: сохраните запись.',
        'Сбалансированно: добавьте замер влажности для истории.',
        'Подробнее: отметьте текущий этап развития культуры.',
      ],
      expectedOutcome: 'Запись пополнит историю поля — с ней будущие '
          'наблюдения можно будет сравнивать.',
      plan: const [
        ActionStep(
          title: 'Сохранить наблюдение',
          dueInDays: 0,
          priority: ActionPriority.low,
          result: 'Запись в истории поля',
        ),
      ],
    );
  }
}
