import 'dart:convert';

import 'package:agrofy_small_ai/data/crop_catalog.dart';
import 'package:agrofy_small_ai/models/climate_summary.dart';
import 'package:agrofy_small_ai/models/farmer_priorities.dart';
import 'package:agrofy_small_ai/models/field.dart';
import 'package:agrofy_small_ai/services/rotation_advisor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Реальный ответ NASA POWER Climatology API для точки 45° с. ш., 10° в. д.
const powerJson = {
  'properties': {
    'parameter': {
      'PRECTOTCORR': {
        'JAN': 1.42, 'FEB': 2.07, 'MAR': 1.99, 'APR': 2.42, 'MAY': 2.55,
        'JUN': 1.94, 'JUL': 1.5, 'AUG': 1.9, 'SEP': 2.12, 'OCT': 2.72,
        'NOV': 3.73, 'DEC': 1.9, 'ANN': 2.18,
      },
      'T2M': {
        'JAN': 2.87, 'FEB': 4.42, 'MAR': 8.52, 'APR': 12.79, 'MAY': 17.31,
        'JUN': 22.42, 'JUL': 25.46, 'AUG': 25.13, 'SEP': 19.82, 'OCT': 14.31,
        'NOV': 8.43, 'DEC': 3.65, 'ANN': 13.81,
      },
      'T2M_MAX': {
        'JAN': 21.64, 'FEB': 20.03, 'MAR': 25.34, 'APR': 28.14, 'MAY': 32.99,
        'JUN': 39.38, 'JUL': 39.6, 'AUG': 40.62, 'SEP': 34.19, 'OCT': 29.83,
        'NOV': 22.77, 'DEC': 15.89, 'ANN': 40.62,
      },
      'T2M_RANGE': {
        'JAN': 7.38, 'FEB': 8.57, 'MAR': 10.18, 'APR': 10.65, 'MAY': 10.84,
        'JUN': 11.39, 'JUL': 12.47, 'AUG': 12.28, 'SEP': 11.25, 'OCT': 10.0,
        'NOV': 7.98, 'DEC': 7.0, 'ANN': 10.01,
      },
      'FROST_DAYS': {
        'JAN': 16.3, 'FEB': 11.0, 'MAR': 4.3, 'APR': 0.2, 'MAY': 0.0,
        'JUN': 0.0, 'JUL': 0.0, 'AUG': 0.0, 'SEP': 0.0, 'OCT': 0.0,
        'NOV': 3.0, 'DEC': 12.6, 'ANN': 47.5,
      },
      'GWETROOT': {
        'JAN': 0.78, 'FEB': 0.81, 'MAR': 0.81, 'APR': 0.77, 'MAY': 0.72,
        'JUN': 0.64, 'JUL': 0.56, 'AUG': 0.54, 'SEP': 0.55, 'OCT': 0.59,
        'NOV': 0.68, 'DEC': 0.75, 'ANN': 0.68,
      },
    },
  },
  'header': {
    'fill_value': -999.0,
    'range': '25-year Meteorological and Solar Monthly & Annual '
        'Climatologies (January 2001 - December 2025)',
  },
};

ClimateSummary sampleClimate() {
  return ClimateSummary.fromPowerJson(
    powerJson,
    latitude: 45,
    longitude: 10,
    fetchedAt: DateTime(2026, 11, 15),
  );
}

const cottonField = Field(
  id: 1,
  name: 'Тест',
  location: 'Тест',
  area: 5,
  crop: 'Хлопок',
  latitude: 45,
  longitude: 10,
  soilPh: 7.2,
  irrigation: 'Поверхностное',
);

void main() {
  const advisor = RotationAdvisor();

  group('ClimateSummary', () {
    test('разбирает ответ NASA POWER и переводит осадки в мм/месяц', () {
      final climate = sampleClimate();

      expect(climate.precipMm[0], closeTo(1.42 * 31, 0.01));
      expect(climate.annualPrecipMm, inInclusiveRange(700, 900));
      expect(climate.annualFrostDays, closeTo(47.4, 0.2));
      expect(climate.rootWetness, isNotNull);
    });

    test('ET0 по Харгривсу правдоподобно для 45° с. ш.', () {
      final climate = sampleClimate();
      final et0 = climate.et0Mm;

      expect(climate.annualEt0Mm, inInclusiveRange(800, 1300));
      expect(et0[6], greaterThan(et0[0] * 4));
    });

    test('значение-заглушка -999 считается отсутствием данных', () {
      final broken = {
        'properties': {
          'parameter': {
            ...(powerJson['properties']! as Map)['parameter'] as Map,
            'T2M': {
              for (final key in const [
                'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', //
                'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
              ])
                key: -999.0,
            },
          },
        },
        'header': powerJson['header'],
      };

      expect(
        () => ClimateSummary.fromPowerJson(
          jsonDecode(jsonEncode(broken)) as Map<String, dynamic>,
          latitude: 45,
          longitude: 10,
          fetchedAt: DateTime(2026),
        ),
        throwsFormatException,
      );
    });

    test('сохраняется и восстанавливается из кэша', () {
      final climate = sampleClimate();
      final restored = ClimateSummary.decode(climate.encode());

      expect(restored.tMean, climate.tMean);
      expect(restored.precipMm, climate.precipMm);
      expect(restored.fetchedAt, climate.fetchedAt);
    });

    test('сценарий меняет осадки и температуру', () {
      final climate = sampleClimate();
      final dry = climate.adjusted(rainFactor: 0.7, tempDelta: 2);

      expect(dry.annualPrecipMm, closeTo(climate.annualPrecipMm * 0.7, 0.01));
      expect(dry.tMean[6], closeTo(climate.tMean[6] + 2, 1e-9));
      expect(dry.annualEt0Mm, greaterThan(climate.annualEt0Mm));
    });
  });

  group('RotationAdvisor.evaluateCrop', () {
    test('теплолюбивая культура сеется после заморозков', () {
      final fit = advisor.evaluateCrop(
        CropCatalog.byId('maize')!,
        sampleClimate(),
      );

      expect(fit.startMonth, inInclusiveRange(4, 5));
      expect(fit.suitability, 1.0);
      expect(fit.frostMonths, 0);
      expect(fit.deficitMm, greaterThan(0));
    });

    test('озимая пшеница проходит зиму в покое', () {
      final fit = advisor.evaluateCrop(
        CropCatalog.byId('wheat')!,
        sampleClimate(),
      );

      expect(fit.suitability, greaterThanOrEqualTo(0.8));
      expect(fit.months, contains(0));
    });

    test('без климата берётся справочная потребность в воде', () {
      final rice = CropCatalog.byId('rice')!;
      final fit = advisor.evaluateCrop(rice, null);

      expect(fit.climateKnown, isFalse);
      expect(fit.waterNeedMm, rice.waterNeedMm);
    });
  });

  group('RotationAdvisor.advise', () {
    test('сравнивает текущий севооборот минимум с двумя альтернативами', () {
      final result = advisor.advise(
        field: cottonField,
        historyCropIds: const [],
        climate: sampleClimate(),
      );

      expect(result.blocker, isNull);
      expect(result.strategies.length, greaterThanOrEqualTo(3));
      expect(result.strategies.first.isCurrent, isTrue);
      expect(result.strategies.first.sequenceLabel, 'Хлопок');
      expect(result.insights, isNotEmpty);

      final labels = result.strategies.map((s) => s.sequenceLabel).toSet();
      expect(labels.length, result.strategies.length);

      for (final strategy in result.strategies) {
        expect(strategy.why, isNotEmpty);
        expect(strategy.evidence, isNotEmpty);
        expect(strategy.benefits, isNotEmpty);
        expect(strategy.gaps, isNotEmpty);
        expect(strategy.risks, isNotEmpty);
        expect(strategy.total, inInclusiveRange(0, 100));
      }
    });

    test('альтернативы сохраняют культуру фермера и разрывают монокультуру',
        () {
      final result = advisor.advise(
        field: cottonField,
        historyCropIds: const [],
        climate: sampleClimate(),
      );
      final current = result.strategies.first;

      for (final strategy in result.strategies.skip(1)) {
        expect(strategy.years.first.main.crop.id, 'cotton');
        expect(
          strategy.scores.pestBreak,
          greaterThan(current.scores.pestBreak),
        );
      }
    });

    test('стратегия экономии воды требует меньше полива, чем текущая', () {
      final result = advisor.advise(
        field: cottonField,
        historyCropIds: const [],
        climate: sampleClimate(),
      );
      final saving = result.strategies.firstWhere(
        (s) => s.kind == StrategyKind.waterSaving,
      );

      expect(
        saving.avgDeficitMm,
        lessThan(result.strategies.first.avgDeficitMm),
      );
    });

    test('стратегия восстановления почвы включает бобовые или покровные', () {
      final result = advisor.advise(
        field: cottonField,
        historyCropIds: const [],
        climate: sampleClimate(),
      );
      final soil = result.strategies.firstWhere(
        (s) => s.kind == StrategyKind.soilBuilding,
      );

      final hasLegume = soil.years.any((y) => y.main.crop.nitrogenFixing);
      final hasCover = soil.years.any((y) => y.cover != null);

      expect(hasLegume || hasCover, isTrue);
      expect(soil.scores.soil, greaterThan(result.strategies.first.scores.soil));
    });

    test('история культур задаёт текущий севооборот', () {
      final result = advisor.advise(
        field: cottonField,
        historyCropIds: const ['cotton', 'wheat', 'cotton'],
        climate: sampleClimate(),
      );

      expect(result.strategies.first.years.length, 3);
      expect(
        result.strategies.first.sequenceLabel,
        'Хлопок → Пшеница озимая → Хлопок',
      );
    });

    test('работает без климатических данных и сообщает о пробеле', () {
      final result = advisor.advise(
        field: cottonField,
        historyCropIds: const [],
      );

      expect(result.strategies.length, greaterThanOrEqualTo(3));
      expect(
        result.strategies.first.gaps.any((g) => g.contains('климатических')),
        isTrue,
      );
    });

    test('приоритеты фермера меняют итоговые оценки', () {
      final water = advisor.advise(
        field: cottonField,
        historyCropIds: const [],
        climate: sampleClimate(),
        priorities: const FarmerPriorities(
          water: 1,
          soil: 0,
          income: 0,
          resilience: 0,
        ),
      );
      final income = advisor.advise(
        field: cottonField,
        historyCropIds: const [],
        climate: sampleClimate(),
        priorities: const FarmerPriorities(
          water: 0,
          soil: 0,
          income: 1,
          resilience: 0,
        ),
      );

      expect(
        water.strategies.first.total,
        isNot(closeTo(income.strategies.first.total, 0.5)),
      );
    });

    test('без орошения влаголюбивые культуры не предлагаются', () {
      const rainfed = Field(
        id: 2,
        name: 'Богара',
        location: 'Тест',
        area: 3,
        crop: 'Пшеница',
        irrigation: 'Без орошения',
      );

      final result = advisor.advise(
        field: rainfed,
        historyCropIds: const [],
        climate: sampleClimate().adjusted(rainFactor: 0.4),
      );

      for (final strategy in result.strategies.skip(1)) {
        final ids = strategy.years.map((y) => y.main.crop.id);
        expect(ids, isNot(contains('rice')));
      }
    });

    test('для многолетних насаждений просит историю культур', () {
      const orchard = Field(
        id: 3,
        name: 'Сад',
        location: 'Тест',
        area: 2,
        crop: 'Фрукты',
      );

      final result = advisor.advise(field: orchard, historyCropIds: const []);

      expect(result.blocker, isNotNull);
      expect(result.strategies, isEmpty);
    });
  });
}
