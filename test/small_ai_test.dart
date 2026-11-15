import 'dart:convert';
import 'dart:io';

import 'package:agrofy_core/ai/climate_pattern_model.dart';
import 'package:agrofy_core/ai/farm_assistant.dart';
import 'package:agrofy_core/ai/intent_classifier.dart';
import 'package:agrofy_core/ai/knowledge_retriever.dart';
import 'package:agrofy_core/data/assistant_training.dart';
import 'package:agrofy_core/models/climate_history.dart';
import 'package:agrofy_core/models/field.dart';
import 'package:agrofy_core/models/terrain_info.dart';
import 'package:agrofy_core/services/rotation_advisor.dart';
import 'package:agrofy_core/services/terrain_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sughd_region_test.dart' show khujandClimate, khujandCotton;

/// Реальный ответ NASA POWER Monthly API для точки под Худжандом, 1991–2025.
ClimateHistory khujandHistory() {
  return ClimateHistory.fromPowerJson(
    jsonDecode(
      File('test/fixtures/khujand_history_power.json').readAsStringSync(),
    ) as Map<String, dynamic>,
    latitude: 40.28,
    longitude: 69.62,
    fetchedAt: DateTime(2026, 11, 15),
  );
}

void main() {
  group('ClimateHistory', () {
    test('разбирает помесячную историю NASA POWER по годам', () {
      final history = khujandHistory();

      expect(history.firstYear, 1991);
      expect(history.lastYear, 2025);
      expect(history.years.length, 35);
      expect(history.years.first.tMean.length, 12);
    });

    test('сохраняется и восстанавливается из кэша', () {
      final history = khujandHistory();
      final restored = ClimateHistory.decode(history.encode());

      expect(restored.years.length, history.years.length);
      expect(restored.years.last.precipMm, history.years.last.precipMm);
    });
  });

  group('ClimatePatternModel', () {
    const model = ClimatePatternModel();

    test('делит годы на три непустых типа, от сухого к влажному', () {
      final patterns = model.train(khujandHistory());

      expect(patterns.yearTypes.map((t) => t.kind), YearKind.values);
      expect(
        patterns.yearTypes.map((t) => t.years.length).reduce((a, b) => a + b),
        35,
      );
      for (final type in patterns.yearTypes) {
        expect(type.years, isNotEmpty);
      }

      final shares = patterns.yearTypes.map((t) => t.share);
      expect(shares.reduce((a, b) => a + b), closeTo(1, 1e-9));

      final dry = patterns.yearTypes.first.climate;
      final wet = patterns.yearTypes.last.climate;
      expect(dry.annualPrecipMm, lessThan(wet.annualPrecipMm));
    });

    test('обучение воспроизводимо', () {
      final a = model.train(khujandHistory());
      final b = model.train(khujandHistory());

      expect(a.dry.years, b.dry.years);
    });

    test('находит тренд в линейно растущем ряду и не находит в шуме', () {
      final xs = List.generate(30, (i) => i.toDouble());
      final rising = List.generate(30, (i) => 10 + 0.05 * i);
      final flat = List.generate(30, (i) => i.isEven ? 1.0 : -1.0);

      expect(
        ClimatePatternModel.theilSenSlope(xs, rising),
        closeTo(0.05, 1e-9),
      );
      expect(ClimatePatternModel.mannKendallZ(rising), greaterThan(1.96));
      expect(ClimatePatternModel.mannKendallZ(flat).abs(), lessThan(1.96));
    });
  });

  group('Советник с типами лет, рельефом и поливом', () {
    const advisor = RotationAdvisor();
    final patterns = const ClimatePatternModel().train(khujandHistory());

    test('каждая стратегия проверена на трёх типах лет', () {
      final result = advisor.advise(
        field: khujandCotton,
        historyCropIds: const [],
        climate: khujandClimate(),
        patterns: patterns,
      );

      for (final strategy in result.strategies) {
        expect(strategy.yearOutcomes.length, 3);
        final dry = strategy.yearOutcomes.first;
        final wet = strategy.yearOutcomes.last;
        expect(dry.irrigationMm, greaterThanOrEqualTo(wet.irrigationMm));
      }
      expect(
        result.insights.any((i) => i.contains('Модель типов лет')),
        isTrue,
      );
    });

    test('капельный полив требует меньше воды, чем по бороздам', () {
      Field withIrrigation(String kind) {
        return Field(
          id: 1,
          name: 'Поле',
          location: 'Худжанд',
          area: 1,
          crop: 'Хлопок',
          latitude: 40.28,
          longitude: 69.62,
          irrigation: kind,
        );
      }

      double irrigation(String kind) {
        return advisor
            .advise(
              field: withIrrigation(kind),
              historyCropIds: const [],
              climate: khujandClimate(),
            )
            .strategies
            .first
            .avgIrrigationMm;
      }

      expect(irrigation('Капельное'), lessThan(irrigation('Поверхностное')));
    });

    test('на склоне голое поле снижает оценку почвы и даёт риск', () {
      final flat = advisor.advise(
        field: khujandCotton,
        historyCropIds: const [],
        climate: khujandClimate(),
        terrain: TerrainInfo(
          elevation: 340,
          slopePercent: 0.5,
          fetchedAt: DateTime(2026),
        ),
      );
      final steep = advisor.advise(
        field: khujandCotton,
        historyCropIds: const [],
        climate: khujandClimate(),
        terrain: TerrainInfo(
          elevation: 900,
          slopePercent: 9,
          fetchedAt: DateTime(2026),
        ),
      );

      expect(
        steep.strategies.first.scores.soil,
        lessThan(flat.strategies.first.scores.soil),
      );
      expect(
        steep.strategies.first.risks.any((r) => r.contains('смыва')),
        isTrue,
      );
    });

    test('уклон считается по высотам SRTM', () {
      final terrain = TerrainService.parse(
        {
          'results': [
            {'elevation': 500.0},
            {'elevation': 509.0},
            {'elevation': 491.0},
            {'elevation': 500.0},
            {'elevation': 500.0},
          ],
        },
        fetchedAt: DateTime(2026),
      );

      // Перепад 18 м на 180 м — уклон 10%.
      expect(terrain.slopePercent, closeTo(10, 1e-9));
      expect(terrain.elevation, 500);
    });
  });

  group('IntentClassifier', () {
    final classifier = IntentClassifier.trained(AssistantTraining.examples);

    test('распознаёт вопросы, которых не было в обучении', () {
      const cases = {
        'что бы мне посеять после пшеницы': AssistantTraining.recommend,
        'сколько нужно воды на полив поля': AssistantTraining.water,
        'в каком месяце лучше сеять нут': AssistantTraining.sowing,
        'а если случится сильная засуха': AssistantTraining.dryYear,
        'как мне улучшить плодородие земли': AssistantTraining.soil,
        'что такое индекс ndvi': AssistantTraining.term,
        'какие есть риски': AssistantTraining.risks,
      };

      cases.forEach((question, intent) {
        expect(classifier.predict(question)?.intent, intent, reason: question);
      });
    });

    test('устойчив к опечаткам', () {
      expect(
        classifier.predict('скока воды нужна для полева')?.intent,
        AssistantTraining.water,
      );
    });

    test('на бессмысленный ввод не отвечает', () {
      expect(classifier.predict('qwerty 12345'), isNull);
    });
  });

  group('KnowledgeRetriever', () {
    test('находит статью по вопросу', () {
      final retriever = KnowledgeRetriever();

      expect(
        retriever.search('что такое эвапотранспирация').first.article.id,
        'et0',
      );
      expect(
        retriever.search('зачем сеять бобовые азот').first.article.id,
        'legumes',
      );
    });
  });

  group('FarmAssistant', () {
    final assistant = FarmAssistant();
    final patterns = const ClimatePatternModel().train(khujandHistory());
    final climate = khujandClimate();
    final result = const RotationAdvisor().advise(
      field: khujandCotton,
      historyCropIds: const [],
      climate: climate,
      patterns: patterns,
    );
    final context = AssistantContext(
      field: khujandCotton,
      result: result,
      climate: climate,
      patterns: patterns,
    );

    test('советует лучший севооборот по расчёту советника', () {
      final answer = assistant.answer('Что посеять после хлопка?', context);

      expect(answer.intent, AssistantTraining.recommend);
      expect(answer.text, contains(result.best!.sequenceLabel));
      expect(answer.source, contains('NASA POWER'));
    });

    test('называет срок посева упомянутой культуры', () {
      final answer = assistant.answer('Когда сеять маш?', context);

      expect(answer.text, contains('Маш'));
      expect(answer.text, contains('посев'));
    });

    test('отвечает про засушливые годы по модели типов лет', () {
      final answer = assistant.answer('Что если будет засуха?', context);

      expect(answer.text, contains('Засушливых лет'));
      expect(answer.source, contains('Модель типов лет'));
    });

    test('объясняет термин из базы знаний', () {
      final answer = assistant.answer('Что такое NDVI?', context);

      expect(answer.text, contains('вегетацион'));
      expect(answer.source, contains('База знаний'));
    });

    test('не путает короткие названия культур с другими словами', () {
      expect(assistant.mentionedCrops('нарисуй рисунок машины'), isEmpty);
      expect(
        assistant.mentionedCrops('сколько воды для риса и маша').map((c) => c.id),
        containsAll(['rice', 'mung']),
      );
    });

    test('без участка просит добавить его, а не выдумывает', () {
      final answer = assistant.answer(
        'Что посеять?',
        const AssistantContext(),
      );

      expect(answer.text, contains('добавьте участок'));
    });

    test('честно признаёт непонятый вопрос', () {
      final answer = assistant.answer('zzz qqq', context);

      expect(answer.source, 'Вопрос не распознан');
    });
  });
}
