import 'package:agrofy_small_ai/data/crop_catalog.dart';
import 'package:agrofy_small_ai/decision/crop_lifecycle.dart';
import 'package:agrofy_small_ai/decision/decision_engine.dart';
import 'package:agrofy_small_ai/decision/evidence_validator.dart';
import 'package:agrofy_small_ai/decision/observation.dart';
import 'package:agrofy_small_ai/decision/observation_interpreter.dart';
import 'package:agrofy_small_ai/decision/saved_observation.dart';
import 'package:agrofy_small_ai/models/crop_season.dart';
import 'package:agrofy_small_ai/models/field.dart';
import 'package:agrofy_small_ai/models/field_event.dart';
import 'package:agrofy_small_ai/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sughd_region_test.dart' show khujandClimate;

const field = Field(
  id: 1,
  name: 'Поле',
  location: 'Худжанд',
  area: 2,
  crop: 'Овощи',
  latitude: 40.28,
  longitude: 69.62,
  irrigation: 'Поверхностное',
);

final now = DateTime(2026, 7, 10);

const interpreter = ObservationInterpreter();
const validator = EvidenceValidator();
const engine = DecisionEngine();

FieldObservation read(String text) =>
    interpreter.interpret(text, date: now, fieldCropId: 'vegetables');

Recommendation decide(
  String text, {
  List<FieldEvent> events = const [],
  bool withClimate = false,
}) {
  final report = validator.validate(
    read(text),
    EvidenceContext(
      field: field,
      events: events,
      climate: withClimate ? khujandClimate() : null,
      stageKnown: true,
    ),
  );
  return engine.decide(report);
}

/// Тестовый набор для оценки качества разбора: фраза → ожидаемые признаки.
/// Включает разговорные и неоднозначные формулировки.
const Map<String, Set<String>> evaluationSet = {
  'У томатов листья стали желтеть, почва сухая, последние дни было очень '
      'жарко': {'leaves:yellowing', 'soil:dry', 'weather:hot'},
  'листья вянут, земля пересохла': {'leaves:wilting', 'soil:dry'},
  'на листьях пятна и тля': {'leaves:spots', 'pests:present'},
  'после дождей поле залито, стоят лужи': {'weather:rain', 'soil:wet'},
  'ночью был заморозок': {'weather:frost'},
  'всходы отстают в росте': {'growth:slow'},
  'пшеница полегла после ветра': {'growth:lodging', 'weather:wind'},
  'на почве корка': {'soil:crusted'},
  'вредителей нет, листья здоровые': {'pests:absent', 'leaves:healthy'},
  'влажность почвы 18%, листья желтеют': {
    'soilMoisture:18',
    'leaves:yellowing',
  },
  'почва не сухая': <String>{},
  'кажется, земля суховата': {'soil:dry'},
  'сухие листья, но земля мокрая': {'leaves:drying', 'soil:wet'},
  'листья сохнут по краям': {'leaves:drying'},
  'всё хорошо': <String>{},
  'стоит жара, поливали вчера': {'weather:hot'},
};

Set<String> keys(FieldObservation observation) =>
    observation.facts.map((f) => '${f.attribute.name}:${f.value}').toSet();

void main() {
  group('ObservationInterpreter', () {
    test('пример из архитектурного документа', () {
      final observation = interpreter.interpret(
        'У томатов листья стали желтеть, почва сухая, последние дни было '
        'очень жарко',
        date: now,
        fieldCropId: 'cotton',
      );

      expect(observation.cropId, 'vegetables');
      expect(observation.cropSource, EvidenceSource.farmerReport);
      expect(
        keys(observation),
        {'leaves:yellowing', 'soil:dry', 'weather:hot'},
      );
      for (final fact in observation.facts) {
        expect(fact.source, EvidenceSource.farmerReport);
        expect(fact.status, EvidenceStatus.observed);
        expect(fact.quote, isNotEmpty);
      }
    });

    test('культура берётся из карточки, если не названа в тексте', () {
      final observation = read('листья желтеют');

      expect(observation.cropId, 'vegetables');
      expect(observation.cropSource, EvidenceSource.selectedByUser);
    });

    test('отрицание не превращается в противоположный факт', () {
      final observation = read('почва не сухая');

      expect(observation.of(ObservationAttribute.soil), isEmpty);
    });

    test('оговорка фермера сохраняется', () {
      final observation = read('кажется, земля суховата');

      expect(observation.facts.single.hedged, isTrue);
    });

    test('измерение влажности получает источник «измерение»', () {
      final fact = read('влажность почвы 18%')
          .of(ObservationAttribute.soilMoisture)
          .single;

      expect(fact.value, '18');
      expect(fact.source, EvidenceSource.measurement);
    });

    test('качество на тестовом наборе не ниже 90%', () {
      var correct = 0;
      final errors = <String>[];

      evaluationSet.forEach((text, expected) {
        final actual = keys(read(text));
        if (actual.length == expected.length && actual.containsAll(expected)) {
          correct++;
        } else {
          errors.add('$text → $actual, ожидалось $expected');
        }
      });

      final accuracy = correct / evaluationSet.length;
      expect(accuracy, greaterThanOrEqualTo(0.9), reason: errors.join('\n'));
    });
  });

  group('Контракт языковой модели', () {
    test('корректный JSON принимается', () {
      final parsed = ObservationInterpreter.parseLlmOutput(
        'Ответ: {"leaves": "yellowing", "soil": "dry"}',
      );

      expect(parsed, {
        ObservationAttribute.leaves: 'yellowing',
        ObservationAttribute.soil: 'dry',
      });
    });

    test('значение вне схемы отклоняет весь ответ', () {
      expect(
        ObservationInterpreter.parseLlmOutput('{"leaves": "purple"}'),
        isNull,
      );
      expect(
        ObservationInterpreter.parseLlmOutput('{"disease": "blight"}'),
        isNull,
      );
      expect(ObservationInterpreter.parseLlmOutput('листья желтеют'), isNull);
      expect(ObservationInterpreter.parseLlmOutput('{"leaves": '), isNull);
    });

    test('unknown и null пропускаются и не становятся фактом', () {
      final parsed = ObservationInterpreter.parseLlmOutput(
        '{"leaves": "yellowing", "soil": "unknown", "pests": null}',
      );

      expect(parsed, {ObservationAttribute.leaves: 'yellowing'});
    });

    test('признак от модели — предположение и не спорит с фермером', () {
      final merged = ObservationInterpreter.mergeLlm(
        read('почва сухая, листья скрутились'),
        {
          ObservationAttribute.soil: 'wet',
          ObservationAttribute.leaves: 'wilting',
        },
      );

      expect(merged.of(ObservationAttribute.soil).single.value, 'dry');
      final leaves = merged.of(ObservationAttribute.leaves).single;
      expect(leaves.source, EvidenceSource.ai);
      expect(leaves.status, EvidenceStatus.inferred);
    });

    test('модель не может добавить то, о чём фермер не писал', () {
      final merged = ObservationInterpreter.mergeLlm(
        read('qwerty asdf'),
        {
          ObservationAttribute.leaves: 'yellowing',
          ObservationAttribute.soil: 'crusted',
          ObservationAttribute.pests: 'present',
        },
      );

      expect(merged.facts, isEmpty);
    });

    test('предположение модели не запускает правила', () {
      final merged = ObservationInterpreter.mergeLlm(
        read('листья какие-то странные'),
        {ObservationAttribute.leaves: 'wilting'},
      );
      expect(merged.facts.single.status, EvidenceStatus.inferred);
      final recommendation = engine.decide(
        validator.validate(merged, const EvidenceContext(field: field)),
      );

      expect(recommendation.code, DecisionCode.askClarification);
    });
  });

  group('EvidenceValidator', () {
    test('отмечает, что влажность не измерена, а погода со слов', () {
      final report = validator.validate(
        read('листья желтеют, почва сухая, жарко'),
        const EvidenceContext(field: field, stageKnown: true),
      );

      expect(report.missing.any((m) => m.contains('не измерена')), isTrue);
      expect(report.missing.any((m) => m.contains('со слов')), isTrue);
      expect(report.contradictions, isEmpty);
    });

    test('сухая почва при недавнем поливе — противоречие', () {
      final report = validator.validate(
        read('почва сухая'),
        EvidenceContext(
          field: field,
          stageKnown: true,
          events: [
            FieldEvent(
              fieldId: 1,
              type: FieldEventType.irrigation,
              title: 'Полив',
              description: '',
              date: now.subtract(const Duration(days: 1)),
            ),
          ],
        ),
      );

      expect(report.contradictions.single.sources, [
        EvidenceSource.farmerReport,
        EvidenceSource.eventLog,
      ]);
    });

    test('сухая почва при высокой измеренной влажности — противоречие', () {
      final report = validator.validate(
        read('почва сухая, влажность почвы 75%'),
        const EvidenceContext(field: field, stageKnown: true),
      );

      expect(report.contradictions, isNotEmpty);
    });

    test('заморозок в июле расходится с климатом NASA', () {
      final report = validator.validate(
        read('ночью был заморозок'),
        EvidenceContext(
          field: field,
          stageKnown: true,
          climate: khujandClimate(),
        ),
      );

      expect(
        report.contradictions.single.sources,
        contains(EvidenceSource.nasaClimate),
      );
    });

    test('вредители и пятна требуют агронома', () {
      expect(
        validator
            .validate(
              read('на листьях пятна'),
              const EvidenceContext(field: field),
            )
            .needsExpert,
        isTrue,
      );
    });
  });

  group('DecisionEngine', () {
    test('пример из документа: сначала проверить влажность', () {
      final r = decide('листья желтеют, почва сухая, жарко');

      expect(r.code, DecisionCode.verifySoilMoisture);
      expect(r.status, DecisionStatus.needsVerification);
      expect(r.alternatives.length, 3);
      expect(r.evidence, isNotEmpty);
      expect(r.missing, isNotEmpty);
      expect(r.plan, isNotEmpty);
      expect(r.expectedOutcome, isNotEmpty);
    });

    test('противоречие важнее любых действий с культурой', () {
      final r = decide('почва сухая, влажность почвы 80%');

      expect(r.code, DecisionCode.resolveConflict);
    });

    test('вредители — к агроному, без назначения препаратов', () {
      final r = decide('на листьях тля');

      expect(r.code, DecisionCode.consultAgronomist);
      expect(r.status, DecisionStatus.needsExpert);
    });

    test('низкая измеренная влажность — сверить полив', () {
      final r = decide('листья вянут, влажность почвы 15%');

      expect(r.code, DecisionCode.reviewIrrigation);
      expect(r.status, DecisionStatus.ready);
    });

    test('высокая влажность и пожелтение — проверить застой воды', () {
      final r = decide('листья желтеют, влажность почвы 85%');

      expect(r.code, DecisionCode.checkWaterlogging);
    });

    test('заморозок на теплолюбивой культуре — оценить повреждение', () {
      final r = decide('ночью был заморозок');

      expect(r.code, DecisionCode.checkFrostDamage);
    });

    test('без признаков просит уточнить, а не советует', () {
      final r = decide('всё как обычно');

      expect(r.code, DecisionCode.askClarification);
      expect(r.status, DecisionStatus.insufficientEvidence);
    });

    test('здоровое поле — только сохранить запись', () {
      expect(
        decide('листья здоровые, вредителей нет').code,
        DecisionCode.recordOnly,
      );
    });

    test('решение воспроизводимо', () {
      final a = decide('листья желтеют, почва сухая');
      final b = decide('листья желтеют, почва сухая');

      expect(a.code, b.code);
      expect(a.action, b.action);
      expect(a.evidence, b.evidence);
    });
  });

  group('CropLifecycle', () {
    final season = const CropSeason(
      fieldId: 1,
      year: 2026,
      cropId: 'cotton',
      stage: CropStage.planning,
    );

    test('этапы идут по порядку', () {
      expect(CropLifecycle.allowedNext(CropStage.planning), [CropStage.sowing]);
      expect(CropLifecycle.allowedNext(CropStage.completed), isEmpty);
    });

    test('нельзя перескочить этап или вернуться назад', () {
      expect(
        () => CropLifecycle.advance(season, CropStage.flowering, at: now),
        throwsStateError,
      );
      expect(
        () => CropLifecycle.advance(
          season.copyWith(stage: CropStage.flowering),
          CropStage.sowing,
          at: now,
        ),
        throwsStateError,
      );
    });

    test('посев и уборка фиксируют даты', () {
      final sown = CropLifecycle.advance(season, CropStage.sowing, at: now);

      expect(sown.stage, CropStage.sowing);
      expect(sown.sownAt, now);
    });

    test('люцерну можно убирать сразу после вегетации', () {
      expect(
        CropLifecycle.allowedNext(
          CropStage.vegetative,
          crop: CropCatalog.byId('alfalfa'),
        ),
        [CropStage.flowering, CropStage.harvest],
      );
      expect(
        CropLifecycle.allowedNext(
          CropStage.vegetative,
          crop: CropCatalog.byId('cotton'),
        ),
        [CropStage.flowering],
      );
    });

    test('старые названия этапов из БД читаются', () {
      expect(CropStage.parse('growing'), CropStage.vegetative);
      expect(CropStage.parse('harvested'), CropStage.completed);
      expect(CropStage.parse('flowering'), CropStage.flowering);
    });
  });

  group('Память поля и результаты', () {
    sqfliteFfiInit();

    tearDown(() => DatabaseService.useDatabaseForTesting(null));

    test('наблюдение сохраняется с признаками и решением', () async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: DatabaseService.schemaVersion,
          onCreate: DatabaseService.createSchema,
          singleInstance: false,
        ),
      );
      DatabaseService.useDatabaseForTesting(db);

      final observation = read('листья желтеют, почва сухая');
      final recommendation = engine.decide(
        validator.validate(observation, const EvidenceContext(field: field)),
      );

      final id = await DatabaseService.instance.insertObservation(
        SavedObservation.from(
          fieldId: 1,
          observation: observation,
          recommendation: recommendation,
        ),
      );

      final saved = (await DatabaseService.instance.getObservations(1)).single;
      expect(saved.id, id);
      expect(saved.code, DecisionCode.verifySoilMoisture);
      expect(saved.facts.length, 2);
      expect(saved.facts.first.source, EvidenceSource.farmerReport);
      expect(saved.awaitsFollowUp, isTrue);

      await db.close();
    });

    test('сравнение с прошлым наблюдением не утверждает причинность', () {
      final before = read('листья вянут, почва сухая');
      final previous = SavedObservation.from(
        fieldId: 1,
        observation: before,
        recommendation: engine.decide(
          validator.validate(before, const EvidenceContext(field: field)),
        ),
      );

      final changes = OutcomeReview.compare(
        previous,
        read('влажность почвы 45%, листья здоровые'),
      );

      expect(changes.any((c) => c.contains('45%')), isTrue);
      expect(changes.any((c) => c.contains('Листья')), isTrue);
      expect(OutcomeReview.caveat, contains('не доказывает'));
    });
  });
}
