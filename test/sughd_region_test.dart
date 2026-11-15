import 'dart:io';

import 'package:agrofy_small_ai/data/crop_catalog.dart';
import 'package:agrofy_small_ai/data/region_profile.dart';
import 'package:agrofy_small_ai/models/climate_summary.dart';
import 'package:agrofy_small_ai/models/field.dart';
import 'package:agrofy_small_ai/services/rotation_advisor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Климатология NASA POWER для точки под Худжандом (40.28° с. ш.,
/// 69.62° в. д.), сохранённая приложением в симуляторе.
ClimateSummary khujandClimate() {
  return ClimateSummary.decode(
    File('test/fixtures/khujand_climate.json').readAsStringSync(),
  );
}

const khujandCotton = Field(
  id: 1,
  name: 'Участок №1',
  location: 'Худжанд, Таджикистан',
  area: 2.5,
  crop: 'Хлопок',
  latitude: 40.28,
  longitude: 69.62,
  soilPh: 7.6,
  irrigation: 'Поверхностное',
);

void main() {
  const advisor = RotationAdvisor();

  group('RegionProfile', () {
    test('определяет Согд по координатам', () {
      expect(RegionProfile.detect(khujandCotton), RegionProfile.sughd);
    });

    test('без координат определяет Согд по названию места', () {
      const field = Field(
        name: 'Поле',
        location: 'Истаравшан',
        area: 1,
        crop: 'Пшеница',
      );

      expect(RegionProfile.detect(field), RegionProfile.sughd);
    });

    test('участок вне региона остаётся без региональной настройки', () {
      const field = Field(
        name: 'Поле',
        location: 'Худжанд',
        area: 1,
        crop: 'Пшеница',
        latitude: 45,
        longitude: 10,
      );

      expect(RegionProfile.detect(field), isNull);
    });

    test('все культуры региона есть в справочнике', () {
      for (final id in RegionProfile.sughd.cropIds) {
        expect(CropCatalog.byId(id), isNotNull, reason: id);
      }
    });
  });

  group('Советник для Согда', () {
    test('предлагает только культуры региона', () {
      final result = advisor.advise(
        field: khujandCotton,
        historyCropIds: const [],
        climate: khujandClimate(),
      );

      expect(result.region, RegionProfile.sughd);
      expect(result.strategies.length, greaterThanOrEqualTo(3));

      for (final strategy in result.strategies) {
        for (final year in strategy.years) {
          expect(RegionProfile.sughd.cropIds, contains(year.main.crop.id));
          final extra = year.cover;
          if (extra != null) {
            expect(RegionProfile.sughd.cropIds, contains(extra.crop.id));
          }
        }
        expect(
          strategy.gaps.any((gap) => gap.contains('засоление')),
          isTrue,
        );
      }
    });

    test('хлопок полностью подходит климату Худжанда', () {
      final fit = advisor.evaluateCrop(
        CropCatalog.byId('cotton')!,
        khujandClimate(),
      );

      expect(fit.suitability, 1.0);
      expect(fit.startMonth, inInclusiveRange(3, 4));
    });

    test('после озимой пшеницы возможен повторный посев', () {
      final result = advisor.advise(
        field: khujandCotton,
        historyCropIds: const ['cotton', 'wheat', 'cotton'],
        climate: khujandClimate(),
      );

      final withSecond = result.strategies.where((strategy) {
        return strategy.years.any((year) {
          final extra = year.cover;
          return year.main.crop.id == 'wheat' &&
              extra != null &&
              !extra.crop.isCover;
        });
      });

      for (final strategy in withSecond) {
        expect(strategy.sequenceLabel, contains('повторно'));
        expect(
          strategy.risks.any((risk) => risk.contains('Повторный посев')),
          isTrue,
        );
      }
    });
  });
}
