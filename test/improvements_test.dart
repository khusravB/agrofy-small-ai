import 'dart:convert';
import 'dart:io';

import 'package:agrofy_small_ai/ai/climate_pattern_model.dart';
import 'package:agrofy_small_ai/ai/model_file_check.dart';
import 'package:agrofy_small_ai/data/crop_catalog.dart';
import 'package:agrofy_small_ai/decision/observation_interpreter.dart';
import 'package:agrofy_small_ai/models/climate_summary.dart';
import 'package:agrofy_small_ai/models/crop_economics.dart';
import 'package:agrofy_small_ai/models/crop_season.dart';
import 'package:agrofy_small_ai/models/daily_climate.dart';
import 'package:agrofy_small_ai/models/elevation_correction.dart';
import 'package:agrofy_small_ai/models/farmer_priorities.dart';
import 'package:agrofy_small_ai/models/field.dart';
import 'package:agrofy_small_ai/models/site_conditions.dart';
import 'package:agrofy_small_ai/models/soil_profile.dart';
import 'package:agrofy_small_ai/models/terrain_info.dart';
import 'package:agrofy_small_ai/services/database_service.dart';
import 'package:agrofy_small_ai/services/rotation_advisor.dart';
import 'package:agrofy_small_ai/services/yield_calibration.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'small_ai_test.dart' show khujandHistory;
import 'sughd_region_test.dart' show khujandClimate, khujandCotton;

/// Суточные температуры NASA POWER под Худжандом, 1991–2025.
DailyClimate khujandDaily() => DailyClimate.decode(
      File('test/fixtures/khujand_daily.json').readAsStringSync(),
    );

/// Климатология Худжанда с высотой ячейки NASA из реального ответа API.
ClimateSummary khujandClimateWithGrid() {
  final base = khujandClimate();
  return ClimateSummary.fromJson({...base.toJson(), 'gridElevation': 570.89});
}

const advisor = RotationAdvisor();

void main() {
  group('Поправка на высоту', () {
    test('поле ниже ячейки NASA теплее', () {
      final correction = ElevationCorrection.of(
        fieldElevation: 337,
        gridElevation: 570.89,
      )!;

      expect(correction.deltaT, closeTo(1.52, 0.01));
      expect(correction.significant, isTrue);
    });

    test('высота ячейки читается из ответа NASA POWER', () {
      expect(
        ClimateSummary.gridElevationOf({
          'geometry': {
            'coordinates': [69.62, 40.28, 570.89],
          },
        }),
        570.89,
      );
    });

    test('советник применяет поправку и объясняет её', () {
      final result = advisor.advise(
        field: khujandCotton,
        historyCropIds: const [],
        climate: khujandClimateWithGrid(),
        terrain: TerrainInfo(
          elevation: 337,
          slopePercent: 1,
          fetchedAt: DateTime(2026),
        ),
      );

      expect(result.elevation!.deltaT, closeTo(1.52, 0.01));
      expect(
        result.insights.any((i) => i.contains('поправлена на высоту')),
        isTrue,
      );
      expect(
        result.strategies.first.evidence.any((e) => e.contains('6,5 °C/км')),
        isTrue,
      );
    });

    test('заморозки не превышают число дней в месяце', () {
      final cold = khujandClimate().adjusted(tempDelta: -8);

      for (var m = 0; m < 12; m++) {
        expect(cold.frostDays[m], lessThanOrEqualTo(31));
      }
    });
  });

  group('Суточный климат', () {
    final daily = khujandDaily();

    test('35 лет данных, высота ячейки сохранена', () {
      expect(daily.years.length, 35);
      expect(daily.gridElevation, closeTo(570.89, 0.01));
    });

    test('даты заморозков правдоподобны для Худжанда', () {
      final typical = daily.typicalLastSpringFrost();
      final safe = daily.springFrostSafeDay();
      final autumn = daily.typicalFirstAutumnFrost();

      // Последний весенний заморозок — март–апрель.
      expect(typical, inInclusiveRange(59, 119));
      expect(safe, greaterThanOrEqualTo(typical));
      // Первый осенний — октябрь–ноябрь.
      expect(autumn, inInclusiveRange(273, 334));
      expect(daily.frostFreeDays(), inInclusiveRange(170, 260));
    });

    test('теплее — заморозки раньше заканчиваются', () {
      final warmer = daily.withTempDelta(1.5);

      expect(
        warmer.springFrostSafeDay(),
        lessThanOrEqualTo(daily.springFrostSafeDay()),
      );
      expect(warmer.frostFreeDays(), greaterThan(daily.frostFreeDays()));
    });

    test('хлопок сеют весной после заморозков, с точностью до декады', () {
      final cotton = CropCatalog.byId('cotton')!;
      final window = daily.sowingWindow(cotton, 3)!;

      expect(window.day, greaterThan(daily.springFrostSafeDay()));
      expect(DailyClimate.dateOf(window.day).month, inInclusiveRange(4, 5));
      expect(window.decade, matches(RegExp(r'^[123]-я декада (апреля|мая)$')));
    });

    test('озимую пшеницу сеют осенью', () {
      final wheat = CropCatalog.byId('wheat')!;
      final window = daily.sowingWindow(wheat, 8)!;

      expect(DailyClimate.dateOf(window.day).month, inInclusiveRange(9, 11));
    });

    test('сохраняется и восстанавливается', () {
      final restored = DailyClimate.decode(daily.encode());

      expect(restored.years, daily.years);
      expect(restored.frostFreeDays(), daily.frostFreeDays());
    });

    test('разбирает суточный ответ NASA POWER и пропускает 29 февраля', () {
      final minimum = <String, double>{};
      final mean = <String, double>{};
      for (var year = 2000; year < 2012; year++) {
        var date = DateTime(year);
        while (date.year == year) {
          final key = '$year${date.month.toString().padLeft(2, '0')}'
              '${date.day.toString().padLeft(2, '0')}';
          minimum[key] = date.month < 4 ? -2 : 10;
          mean[key] = 15;
          date = date.add(const Duration(days: 1));
        }
      }

      final parsed = DailyClimate.fromPowerJson(
        {
          'geometry': {
            'coordinates': [1, 2, 300],
          },
          'properties': {
            'parameter': {'T2M_MIN': minimum, 'T2M': mean},
          },
          'header': {'fill_value': -999.0},
        },
        latitude: 2,
        longitude: 1,
        fetchedAt: DateTime(2026),
      );

      expect(parsed.years.length, 12);
      expect(parsed.tMin[2000]!.length, 365);
      // Последний заморозок — 31 марта (день 89).
      expect(parsed.typicalLastSpringFrost(), 89);
      expect(parsed.gridElevation, 300);
    });

    test('советник уточняет сроки посева до декады', () {
      final result = advisor.advise(
        field: khujandCotton,
        historyCropIds: const [],
        climate: khujandClimate(),
        daily: daily,
      );

      expect(
        result.strategies.first.evidence.any((e) => e.contains('декада')),
        isTrue,
      );
      expect(
        result.insights.any((i) => i.contains('весенний заморозок')),
        isTrue,
      );
    });
  });

  group('Почва: засоление, грунтовые воды, питание', () {
    SoilProfile soil({
      Salinity? salinity,
      double? groundwater,
      NutrientLevel? nitrogen,
    }) {
      return SoilProfile(
        salinity: salinity,
        groundwaterM: groundwater,
        nitrogen: nitrogen,
        updatedAt: DateTime(2026),
      );
    }

    test('солеустойчивость: ячмень терпит, фасоль нет', () {
      final site = SiteConditions(soil: soil(salinity: Salinity.moderate));

      expect(site.salinityFit(CropCatalog.byId('barley')!), 1.0);
      expect(site.salinityFit(CropCatalog.byId('beans')!), closeTo(0.5, 1e-9));
    });

    test('при сильном засолении чувствительные культуры не предлагаются', () {
      final result = advisor.advise(
        field: khujandCotton,
        historyCropIds: const [],
        climate: khujandClimate(),
        soil: soil(salinity: Salinity.strong),
      );

      for (final strategy in result.strategies.skip(1)) {
        for (final year in strategy.years) {
          expect(
            ['beans', 'carrot', 'onion', 'potato', 'maize'],
            isNot(contains(year.main.crop.id)),
          );
        }
      }
      expect(
        result.strategies.first.risks.any((r) => r.contains('засоление')),
        isTrue,
      );
    });

    test('близкие грунтовые воды: риск для люцерны и подъёма солей', () {
      final site = SiteConditions(
        soil: soil(groundwater: 0.8),
        irrigationLabel: 'полив по бороздам',
      );

      expect(site.waterloggingFit(CropCatalog.byId('alfalfa')!), 0.6);
      expect(site.waterloggingFit(CropCatalog.byId('rice')!), 1.0);
      expect(site.secondarySalinizationRisk, isTrue);
    });

    test('мало азота — почвенная оценка бобовых растёт сильнее', () {
      Map<String, double> soilScores(SoilProfile? profile) {
        final result = advisor.advise(
          field: khujandCotton,
          historyCropIds: const ['cotton', 'chickpea', 'wheat'],
          climate: khujandClimate(),
          soil: profile,
        );
        return {'current': result.strategies.first.scores.soil};
      }

      final normal = soilScores(null)['current']!;
      final poor = soilScores(soil(nitrogen: NutrientLevel.low))['current']!;
      expect(poor, isNot(closeTo(normal, 0.01)));
    });

    test('неизвестная почва отмечена в пробелах, а не считается нормой', () {
      final gaps = advisor
          .advise(
            field: khujandCotton,
            historyCropIds: const [],
            climate: khujandClimate(),
          )
          .strategies
          .first
          .gaps;

      expect(gaps.any((g) => g.contains('Засоление не указано')), isTrue);
      expect(gaps.any((g) => g.contains('грунтовых вод')), isTrue);
    });
  });

  group('Доход в деньгах', () {
    const economics = {
      'cotton': CropEconomics(
        cropId: 'cotton',
        pricePerT: 6000,
        yieldTHa: 3,
        costPerHa: 9000,
      ),
      'wheat': CropEconomics(
        cropId: 'wheat',
        pricePerT: 3000,
        yieldTHa: 4,
        costPerHa: 5000,
      ),
    };

    test('маржа = цена × урожай − затраты', () {
      expect(economics['cotton']!.margin(), 9000);
      expect(economics['wheat']!.margin(yieldShare: 0.5), 1000);
    });

    test('текущий хлопок получает доход в деньгах', () {
      final result = advisor.advise(
        field: khujandCotton,
        historyCropIds: const ['cotton', 'wheat', 'cotton'],
        climate: khujandClimate(),
        economics: economics,
      );
      final current = result.strategies.first;

      expect(current.marginPerHa, isNotNull);
      expect(current.missingEconomics, isEmpty);
      expect(result.currency, 'сомони');
    });

    test('культуры без данных перечислены, доход для них — индекс', () {
      final result = advisor.advise(
        field: khujandCotton,
        historyCropIds: const [],
        climate: khujandClimate(),
        economics: economics,
      );

      final withGaps =
          result.strategies.where((s) => s.missingEconomics.isNotEmpty);
      for (final strategy in withGaps) {
        expect(strategy.marginPerHa, isNull);
        expect(
          strategy.gaps.any((g) => g.contains('условным индексом')),
          isTrue,
        );
      }
    });

    test('урожай из записей фермера заменяет введённый', () {
      final effective = CropEconomics.withRecordedYields(economics, const [
        CropSeason(fieldId: 1, year: 2024, cropId: 'cotton', yieldTHa: 2.5),
        CropSeason(fieldId: 1, year: 2025, cropId: 'cotton', yieldTHa: 3.5),
      ]);

      expect(effective['cotton']!.yieldTHa, 3.0);
      expect(effective['cotton']!.yieldFromRecords, isTrue);
      expect(effective['cotton']!.recordYears, 2);
      expect(effective['wheat']!.yieldFromRecords, isFalse);
    });
  });

  group('Длина севооборота и многолетние культуры', () {
    test('люцерна блоком на 2 года в текущем севообороте', () {
      final result = advisor.advise(
        field: khujandCotton,
        historyCropIds: const ['cotton', 'alfalfa', 'alfalfa'],
        climate: khujandClimate(),
      );
      final current = result.strategies.first;

      expect(current.sequenceLabel, 'Хлопок → Люцерна (2 года)');
      expect(current.years[1].continues, isTrue);
      expect(current.years[2].established, isTrue);
      expect(current.years[1].bareMonths, current.years[1].main.startMonth);
      expect(
        current.risks.any((r) => r.contains('несколько лет подряд')),
        isTrue,
      );
    });

    test('годы одной посадки люцерны не считаются повтором семейства', () {
      final result = advisor.advise(
        field: khujandCotton,
        historyCropIds: const ['cotton', 'alfalfa', 'alfalfa'],
        climate: khujandClimate(),
      );

      expect(result.strategies.first.scores.pestBreak, greaterThan(60));
    });

    for (final length in [4, 5]) {
      test('севооборот на $length лет', () {
        final watch = Stopwatch()..start();
        final result = advisor.advise(
          field: khujandCotton,
          historyCropIds: const [],
          climate: khujandClimate(),
          priorities: FarmerPriorities(rotationYears: length),
        );
        watch.stop();

        expect(result.strategies.length, greaterThanOrEqualTo(3));
        for (final strategy in result.strategies.skip(1)) {
          expect(strategy.years.length, length);
          expect(strategy.years.first.main.crop.id, 'cotton');
        }
        expect(watch.elapsedMilliseconds, lessThan(5000));
      });
    }

    for (final length in [3, 4, 5]) {
      test('в предложениях на $length лет культура не возвращается '
          'раньше чем через 3 года', () {
        final result = advisor.advise(
          field: khujandCotton,
          historyCropIds: const [],
          climate: khujandClimate(),
          priorities: FarmerPriorities(rotationYears: length),
        );

        for (final strategy in result.strategies.skip(1)) {
          final n = strategy.years.length;
          final occurrences = <(int, String)>[
            for (var i = 0; i < n; i++) ...[
              (i, strategy.years[i].main.crop.id),
              if (strategy.years[i].cover != null &&
                  !strategy.years[i].cover!.crop.isCover)
                (i, strategy.years[i].cover!.crop.id),
            ],
          ];
          for (var a = 0; a < occurrences.length; a++) {
            for (var b = a + 1; b < occurrences.length; b++) {
              if (occurrences[a].$2 != occurrences[b].$2) {
                continue;
              }
              final gap = occurrences[b].$1 - occurrences[a].$1;
              final distance = gap < n - gap ? gap : n - gap;
              expect(
                distance,
                greaterThanOrEqualTo(RotationAdvisor.minReturnYears),
                reason: strategy.sequenceLabel,
              );
            }
          }
        }
      });
    }

    test('ранний возврат культуры в текущем севообороте — риск', () {
      final current = advisor
          .advise(
            field: khujandCotton,
            historyCropIds: const ['cotton', 'wheat', 'cotton'],
            climate: khujandClimate(),
          )
          .strategies
          .first;

      expect(current.risks.any((r) => r.contains('возвращается')), isTrue);
    });

    test('длина севооборота сохраняется в приоритетах', () {
      final restored = FarmerPriorities.decode(
        const FarmerPriorities(rotationYears: 5).encode(),
      );

      expect(restored.rotationYears, 5);
      expect(FarmerPriorities.decode('{"water":0.5}').rotationYears, 3);
    });
  });

  group('Засушливый год по водному балансу', () {
    final patterns = const ClimatePatternModel().train(khujandHistory());

    test('агрономический критерий рядом с кластерами', () {
      expect(patterns.waterBalanceDryYears, isNotEmpty);
      expect(patterns.medianSeasonDeficitMm, greaterThan(500));
      expect(
        patterns.yearTypes.first.seasonAridity,
        lessThan(patterns.yearTypes.last.seasonAridity),
      );
      expect(patterns.dryAgreement, lessThanOrEqualTo(patterns.dry.years.length));
    });

    test('классы сухости UNEP', () {
      expect(ClimatePatterns.aridityClassOf(0.03), 'гипераридный');
      expect(ClimatePatterns.aridityClassOf(0.1), 'аридный');
      expect(ClimatePatterns.aridityClassOf(0.3), 'полуаридный');
      expect(ClimatePatterns.aridityClassOf(0.8), 'гумидный');
    });

    test('поправка температуры сохраняет типы лет', () {
      final warmer = patterns.withTempDelta(1.5);

      expect(warmer.yearTypes.length, 3);
      expect(
        warmer.yearTypes.first.climate.tMean[6],
        closeTo(patterns.yearTypes.first.climate.tMean[6] + 1.5, 1e-9),
      );
    });
  });

  group('Нечёткий разбор и таджикские слова', () {
    test('одна опечатка в длинном корне допускается', () {
      expect(ObservationInterpreter.matches('вредетели', 'вредител'), isTrue);
      expect(ObservationInterpreter.matches('насикомые', 'насеком'), isTrue);
    });

    test('короткие корни без нечёткости — нет ложных совпадений', () {
      expect(ObservationInterpreter.matches('полей', 'полег'), isFalse);
      expect(ObservationInterpreter.matches('зардолу', '=зард'), isFalse);
      expect(ObservationInterpreter.matches('зард', '=зард'), isTrue);
    });
  });

  group('Сверка с урожаями', () {
    test('коэффициент Пирсона', () {
      expect(
        YieldCalibration.pearson([1, 2, 3], [2, 4, 6]),
        closeTo(1, 1e-9),
      );
      expect(YieldCalibration.pearson([1, 1, 1], [1, 2, 3]), isNull);
    });

    test('урожаи сравниваются с погодой тех же лет', () {
      final calibration = YieldCalibration.compute(
        seasons: const [
          CropSeason(fieldId: 1, year: 2021, cropId: 'cotton', yieldTHa: 2.6),
          CropSeason(fieldId: 1, year: 2022, cropId: 'cotton', yieldTHa: 3.1),
          CropSeason(fieldId: 1, year: 2023, cropId: 'wheat', yieldTHa: 4.0),
          CropSeason(fieldId: 1, year: 2024, cropId: 'wheat', yieldTHa: 3.6),
          CropSeason(fieldId: 1, year: 2025, cropId: 'cotton'),
        ],
        history: khujandHistory(),
        site: SiteConditions.of(khujandCotton),
      );

      expect(calibration.checks.length, 4);
      expect(calibration.pairs, 4);
      expect(calibration.checks.first.climateFit, isNotNull);
      expect(calibration.verdict, contains('по 4 годам'));
    });

    test('мало лет — честно говорит, что сравнивать рано', () {
      final calibration = YieldCalibration.compute(
        seasons: const [
          CropSeason(fieldId: 1, year: 2024, cropId: 'cotton', yieldTHa: 3),
        ],
        history: khujandHistory(),
        site: SiteConditions.of(khujandCotton),
      );

      expect(calibration.correlation, isNull);
      expect(calibration.verdict, contains('минимум 3 года'));
    });
  });

  group('Проверка файла модели', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('agrofy_model'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('правильный файл проходит проверку', () async {
      final bytes = utf8.encode('GGUF-test-model-content');
      final file = File('${dir.path}/model.gguf')..writeAsBytesSync(bytes);

      expect(
        await ModelFileCheck.verify(
          file,
          expectedBytes: bytes.length,
          expectedSha256: sha256.convert(bytes).toString(),
        ),
        isNull,
      );
    });

    test('другой размер, не GGUF или чужая сумма — отказ', () async {
      final bytes = utf8.encode('GGUF-test-model-content');
      final file = File('${dir.path}/model.gguf')..writeAsBytesSync(bytes);
      final notGguf = File('${dir.path}/other.bin')
        ..writeAsBytesSync(utf8.encode('XXXX-test-model-content'));

      expect(
        await ModelFileCheck.verify(
          file,
          expectedBytes: 10,
          expectedSha256: 'x',
        ),
        contains('Размер'),
      );
      expect(
        await ModelFileCheck.verify(
          notGguf,
          expectedBytes: bytes.length,
          expectedSha256: 'x',
        ),
        contains('GGUF'),
      );
      expect(
        await ModelFileCheck.verify(
          file,
          expectedBytes: bytes.length,
          expectedSha256: 'deadbeef',
        ),
        contains('Контрольная сумма'),
      );
    });
  });

  group('Хранение новых данных', () {
    sqfliteFfiInit();

    tearDown(() => DatabaseService.useDatabaseForTesting(null));

    test('почва, экономика, суточный климат и урожай сохраняются', () async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: DatabaseService.schemaVersion,
          onCreate: DatabaseService.createSchema,
          singleInstance: false,
        ),
      );
      DatabaseService.useDatabaseForTesting(db);
      final service = DatabaseService.instance;

      final fieldId = await service.insertField(
        const Field(name: 'Поле', location: 'Тест', area: 1, crop: 'Хлопок'),
      );

      await service.saveSoilProfile(
        fieldId,
        SoilProfile(
          salinity: Salinity.slight,
          groundwaterM: 1.4,
          nitrogen: NutrientLevel.low,
          fromLabTest: true,
          updatedAt: DateTime(2026, 11, 15),
        ),
      );
      final soil = (await service.getSoilProfile(fieldId))!;
      expect(soil.salinity, Salinity.slight);
      expect(soil.groundwaterM, 1.4);
      expect(soil.nitrogen, NutrientLevel.low);
      expect(soil.phosphorus, isNull);
      expect(soil.fromLabTest, isTrue);

      await service.saveCropEconomics(
        const CropEconomics(cropId: 'cotton', pricePerT: 6000),
      );
      expect((await service.getCropEconomics())['cotton']!.pricePerT, 6000);
      await service.deleteCropEconomics('cotton');
      expect(await service.getCropEconomics(), isEmpty);

      await service.saveDailyClimate(fieldId, khujandDaily());
      expect((await service.getDailyClimate(fieldId))!.years.length, 35);

      await service.saveCropSeason(
        CropSeason(fieldId: fieldId, year: 2025, cropId: 'cotton'),
      );
      await service.setSeasonYield(fieldId, 2025, 3.2);
      expect(
        (await service.getCropSeasons(fieldId)).single.yieldTHa,
        3.2,
      );

      await service.deleteField(fieldId);
      expect(await service.getSoilProfile(fieldId), isNull);
      expect(await service.getDailyClimate(fieldId), isNull);

      await db.close();
    });
  });
}
