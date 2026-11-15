import '../data/assistant_training.dart';
import '../data/crop_catalog.dart';
import '../models/climate_summary.dart';
import '../models/crop_profile.dart';
import '../models/field.dart';
import '../models/site_conditions.dart';
import '../models/terrain_info.dart';
import '../services/rotation_advisor.dart';
import 'climate_pattern_model.dart';
import 'intent_classifier.dart';
import 'knowledge_retriever.dart';
import 'text_features.dart';

/// Что ассистент знает об участке в момент вопроса.
class AssistantContext {
  final Field? field;
  final AdvisorResult? result;
  final ClimateSummary? climate;
  final ClimatePatterns? patterns;
  final TerrainInfo? terrain;

  const AssistantContext({
    this.field,
    this.result,
    this.climate,
    this.patterns,
    this.terrain,
  });
}

class AssistantAnswer {
  final String text;

  /// На чём основан ответ — показывается под сообщением.
  final String source;

  final String? intent;
  final double confidence;

  const AssistantAnswer({
    required this.text,
    required this.source,
    this.intent,
    this.confidence = 0,
  });
}

/// Офлайн-ассистент фермера.
///
/// Не генерирует текст «из головы»: небольшая модель определяет намерение
/// вопроса, а ответ собирается из расчётов советника, данных NASA по
/// участку и статей базы знаний. Поэтому он не выдумывает факты и всегда
/// называет источник.
class FarmAssistant {
  /// Ниже этой уверенности вопрос передаётся поиску по базе знаний.
  static const double minConfidence = 0.4;

  static const List<String> suggestions = [
    'Что посеять после хлопка?',
    'Сколько воды нужно?',
    'Что если будет засуха?',
    'Когда сеять маш?',
    'Как улучшить почву?',
    'Что такое NDVI?',
  ];

  final IntentClassifier _classifier;
  final KnowledgeRetriever _retriever;
  final RotationAdvisor advisor;

  FarmAssistant({
    IntentClassifier? classifier,
    KnowledgeRetriever? retriever,
    this.advisor = const RotationAdvisor(),
  })  : _classifier =
            classifier ?? IntentClassifier.trained(AssistantTraining.examples),
        _retriever = retriever ?? KnowledgeRetriever();

  IntentPrediction? classify(String question) => _classifier.predict(question);

  /// Находит культуры, упомянутые в вопросе.
  List<CropProfile> mentionedCrops(String question) {
    final tokens = TextFeatures.tokens(question);
    final found = <CropProfile>[];

    AssistantTraining.cropRoots.forEach((cropId, roots) {
      final hit = tokens.any((token) {
        return roots.any((root) {
          if (!token.startsWith(root)) {
            return false;
          }
          // Короткие корни («рис», «лук», «маш») не должны срабатывать
          // на посторонних словах вроде «рисунок» или «машина».
          return root.length > 4 || token.length <= root.length + 2;
        });
      });

      final crop = CropCatalog.byId(cropId);
      if (hit && crop != null) {
        found.add(crop);
      }
    });

    return found;
  }

  AssistantAnswer answer(String question, AssistantContext context) {
    final prediction = _classifier.predict(question);
    final crops = mentionedCrops(question);

    if (prediction == null || prediction.confidence < minConfidence) {
      return _fromKnowledge(question, prediction) ?? _fallback(prediction);
    }

    final intent = prediction.intent;

    AssistantAnswer reply(String text, String source) {
      return AssistantAnswer(
        text: text,
        source: source,
        intent: intent,
        confidence: prediction.confidence,
      );
    }

    if (intent == AssistantTraining.help) {
      return reply(
        'Я офлайн-помощник AGROFY. Отвечаю по данным вашего участка и '
        'базе знаний, без интернета. Спросите, например:\n'
        '${suggestions.map((s) => '• $s').join('\n')}',
        'Встроенная справка',
      );
    }

    if (intent == AssistantTraining.term) {
      return _fromKnowledge(question, prediction) ?? _fallback(prediction);
    }

    final result = context.result;
    final field = context.field;

    if (field == null || result == null || result.strategies.isEmpty) {
      return reply(
        result?.blocker ??
            'Сначала добавьте участок на вкладке «Поля» и откройте вкладку '
                '«Советник» — тогда я отвечу по вашим данным.',
        'Нет данных участка',
      );
    }

    final current = result.strategies.first;
    final best = result.best!;
    final source = context.climate == null
        ? 'Расчёт советника по справочнику культур (климат не загружен)'
        : 'Расчёт советника: NASA POWER + справочник культур';

    switch (intent) {
      case AssistantTraining.recommend:
        if (best.isCurrent) {
          return reply(
            'По вашим приоритетам текущий севооборот '
            '(${current.sequenceLabel}) остаётся лучшим: '
            '${current.total.round()} из 100. Альтернативы уступают — '
            'посмотрите их на вкладке «Советник».',
            source,
          );
        }
        return reply(
          'Советую вариант «${best.title}»: ${best.sequenceLabel}. '
          'Оценка ${best.total.round()} из 100 против '
          '${current.total.round()} у текущего севооборота.\n\n'
          '${best.why.take(3).map((w) => '• $w').join('\n')}\n\n'
          'Это вариант для обсуждения с агрономом, а не готовое решение.',
          source,
        );

      case AssistantTraining.water:
        if (crops.isNotEmpty && context.climate != null) {
          final site = SiteConditions.of(field, terrain: context.terrain);
          final lines = crops.map((crop) {
            final fit = advisor.evaluateCrop(
              crop,
              context.climate,
              preferRain: site.rainfed,
              site: site,
            );
            final gross = fit.deficitMm / site.irrigationEfficiency;
            return '• ${crop.name}: потребность ${fit.waterNeedMm.round()} мм '
                'за сезон, осадки покрывают ${fit.effectiveRainMm.round()} мм, '
                'полить нужно около ${gross.round()} мм '
                '(${(gross * 10).round()} м³/га).';
          });
          return reply(
            '${lines.join('\n')}\n\nУчтены потери: ${site.irrigationLabel}.',
            source,
          );
        }
        final sorted = [...result.strategies]
          ..sort((a, b) => a.avgIrrigationMm.compareTo(b.avgIrrigationMm));
        return reply(
          'Сколько воды нужно подать на поле в среднем за год:\n'
          '${sorted.map((s) => '• ${s.title} (${s.sequenceLabel}): около '
              '${s.avgIrrigationMm.round()} мм').join('\n')}\n\n'
          'Меньше всего воды требует «${sorted.first.title}». '
          '100 мм — это 1000 м³ на гектар.',
          source,
        );

      case AssistantTraining.sowing:
        final fits = <CropFit>[];
        if (crops.isNotEmpty) {
          final site = SiteConditions.of(field, terrain: context.terrain);
          for (final crop in crops) {
            fits.add(
              advisor.evaluateCrop(
                crop,
                context.climate,
                preferRain: site.rainfed,
                site: site,
              ),
            );
          }
        } else {
          for (final year in best.years) {
            fits.add(year.main);
            final cover = year.cover;
            if (cover != null) {
              fits.add(cover);
            }
          }
        }

        final dated = fits.where((f) => f.startMonth != null).toList();
        if (dated.isEmpty) {
          return reply(
            'Чтобы назвать сроки, мне нужен климат участка. Загрузите его '
            'на вкладке «Советник» — потребуется интернет один раз.',
            'Нет климатических данных',
          );
        }
        return reply(
          'По многолетнему климату участка:\n'
          '${dated.map((f) => '• ${f.crop.name}: посев — '
              '${ClimateSummary.monthNames[f.startMonth!]}, уборка — '
              '${ClimateSummary.monthNames[f.months.last]}').join('\n')}\n\n'
          'Сроки рассчитаны с точностью до месяца — точную дату уточните '
          'по погоде и у агронома.',
          source,
        );

      case AssistantTraining.climate:
        if (result.insights.isEmpty) {
          return reply(
            'Климат участка ещё не загружен. Откройте вкладку «Советник» и '
            'нажмите «Загрузить данные NASA».',
            'Нет климатических данных',
          );
        }
        final trends = context.patterns?.trends ?? const <ClimateTrend>[];
        return reply(
          [
            ...result.insights.map((i) => '• $i'),
            if (trends.isNotEmpty) '\nТренды за ${context.patterns!.yearCount} лет:',
            ...trends.map((t) => '• ${t.describe()}'),
          ].join('\n'),
          'NASA POWER: климатология и история по годам',
        );

      case AssistantTraining.dryYear:
        final patterns = context.patterns;
        if (patterns == null) {
          return reply(
            'Чтобы оценить засушливые годы, мне нужна история погоды '
            'участка. Загрузите данные NASA на вкладке «Советник».',
            'Нет истории погоды',
          );
        }
        final dry = patterns.dry;
        final lines = <String>[];
        for (final strategy in result.strategies) {
          for (final outcome in strategy.yearOutcomes) {
            if (outcome.type.kind == YearKind.dry) {
              lines.add(
                '• ${strategy.title}: оценка ${outcome.total.round()} из 100, '
                'полив около ${outcome.irrigationMm.round()} мм'
                '${outcome.stressedCrops.isEmpty ? '' : '; страдают: '
                    '${outcome.stressedCrops.join(', ')}'}',
              );
            }
          }
        }
        return reply(
          'Моя модель типов лет изучила ${patterns.yearCount} лет погоды '
          'участка. Засушливых лет ${(dry.share * 100).round()}%, а за '
          'последние 10 лет — ${(dry.recentShare * 100).round()}%.\n\n'
          'Как варианты ведут себя в засушливый год:\n${lines.join('\n')}',
          'Модель типов лет (k-средних) на истории NASA POWER',
        );

      case AssistantTraining.risks:
        return reply(
          'Для варианта «${best.title}» стоит проверить:\n'
          '${best.risks.map((r) => '• $r').join('\n')}\n\n'
          'Чего нет в моих данных:\n'
          '${best.gaps.take(4).map((g) => '• $g').join('\n')}',
          source,
        );

      case AssistantTraining.soil:
        final soil = result.strategies.firstWhere(
          (s) => s.kind == StrategyKind.soilBuilding,
          orElse: () => best,
        );
        return reply(
          'Почву восстанавливают три вещи: бобовые (дают азот), покровные '
          'культуры (закрывают поле и добавляют органику) и чередование '
          'семейств.\n\nДля вашего участка это вариант '
          '«${soil.title}»: ${soil.sequenceLabel}. Оценка почвы '
          '${soil.scores.soil.round()} из 100 против '
          '${current.scores.soil.round()} у текущего севооборота.',
          source,
        );

      case AssistantTraining.compare:
        return reply(
          result.strategies.map((s) {
            return '• ${s.title} — ${s.total.round()} из 100\n'
                '  ${s.sequenceLabel}\n'
                '  полив около ${s.avgIrrigationMm.round()} мм/год, почва '
                '${s.scores.soil.round()}, доход ${s.scores.income.round()}';
          }).join('\n'),
          source,
        );

      case AssistantTraining.cropInfo:
        if (crops.isEmpty) {
          return _fromKnowledge(question, prediction) ??
              reply(
                'Назовите культуру — например: «Подходит ли нут?»',
                'Уточнение',
              );
        }
        final site = SiteConditions.of(field, terrain: context.terrain);
        return reply(
          crops.map((crop) {
            final fit = advisor.evaluateCrop(
              crop,
              context.climate,
              preferRain: site.rainfed,
              site: site,
            );
            final traits = [
              crop.family.label.toLowerCase(),
              if (crop.nitrogenFixing) 'фиксирует азот',
              if (crop.droughtTolerance >= 4) 'засухоустойчива',
              if (crop.rootDepth == 3) 'глубокие корни',
              if (crop.forage) 'кормовая ценность',
            ];
            final climateLine = fit.climateKnown
                ? 'Соответствие климату участка '
                    '${(fit.suitability * 100).round()}%'
                    '${fit.startMonth == null ? '' : ', посев — '
                        '${ClimateSummary.monthNames[fit.startMonth!]}'}'
                    ', полив около '
                    '${(fit.deficitMm / site.irrigationEfficiency).round()} мм.'
                : 'Климат участка не загружен — оценить соответствие не могу.';
            return '${crop.name}: ${traits.join(', ')}. '
                'Цикл около ${crop.cycleMonths} мес. $climateLine';
          }).join('\n\n'),
          source,
        );
    }

    return _fromKnowledge(question, prediction) ?? _fallback(prediction);
  }

  AssistantAnswer? _fromKnowledge(
    String question,
    IntentPrediction? prediction,
  ) {
    final found = _retriever.search(question, limit: 1);
    if (found.isEmpty || found.first.score < 1.5) {
      return null;
    }

    final article = found.first.article;
    return AssistantAnswer(
      text: '${article.title}\n\n${article.body}',
      source: 'База знаний: ${article.category}',
      intent: AssistantTraining.term,
      confidence: prediction?.confidence ?? 0,
    );
  }

  AssistantAnswer _fallback(IntentPrediction? prediction) {
    return AssistantAnswer(
      text: 'Я не уверен, что правильно понял вопрос, и не хочу гадать. '
          'Попробуйте спросить иначе, например:\n'
          '${suggestions.map((s) => '• $s').join('\n')}',
      source: 'Вопрос не распознан',
      intent: prediction?.intent,
      confidence: prediction?.confidence ?? 0,
    );
  }
}
