import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agrofy_core/remote/data_package.dart';
import 'package:agrofy_core/remote/sms_command.dart';
import 'package:agrofy_core/services/modis_service.dart';
import 'package:agrofy_core/services/nasa_power_service.dart';

import 'config.dart';
import 'store.dart';

class BuiltPackage {
  final DataPackage package;
  final PackageRecord? record;

  const BuiltPackage(this.package, this.record);

  String? url(String publicUrl) =>
      record == null ? null : '$publicUrl/p/${record!.token}';
}

/// Earth Observation Connector + Processing & Packaging: собирает реальные
/// наблюдения из NASA (MODIS NDVI через ORNL DAAC, NASA POWER) в пакет
/// с метаданными и отчётом о качестве. Пакет без данных не сохраняется.
class DataPackageService {
  final ServerConfig config;
  final Store store;
  final ModisService modis;
  final NasaPowerService power;
  final DateTime Function() clock;
  final Random _random;

  DataPackageService(
    this.config,
    this.store, {
    ModisService? modis,
    NasaPowerService? power,
    DateTime Function()? clock,
    Random? random,
  })  : modis = modis ?? ModisService(),
        power = power ?? NasaPowerService(),
        clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  /// Случайный токен ссылки: 24 байта, не содержит координат и номера.
  String _token() => base64Url
      .encode(List<int>.generate(24, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  Future<BuiltPackage> build({
    required String ownerHash,
    required DataRequestKind kind,
    required int days,
    required double latitude,
    required double longitude,
    String? fieldId,
  }) async {
    final now = clock().toUtc();
    final end = DateTime.utc(now.year, now.month, now.day);
    final start = end.subtract(Duration(days: days));

    final wantNdvi = kind == DataRequestKind.ndvi ||
        kind == DataRequestKind.history ||
        kind == DataRequestKind.data;
    final wantClimate = kind == DataRequestKind.climate ||
        kind == DataRequestKind.sowing ||
        kind == DataRequestKind.data;

    final datasets = <PackageDataset>[];
    final missing = <String>[];
    final warnings = <String>[];

    if (wantNdvi) {
      try {
        final points = await modis.fetchNdvi(
          latitude: latitude,
          longitude: longitude,
          start: start,
          end: end,
        );
        if (points.isEmpty) {
          missing.add('NDVI MODIS: за период нет наблюдений.');
        } else {
          final unusable = points.where((p) => !p.usable).length;
          if (unusable > 0) {
            warnings.add(
              'NDVI MODIS: $unusable из ${points.length} наблюдений с облаками, '
              'снегом или низкой надёжностью — они помечены в поле quality.',
            );
          }
          datasets.add(
            PackageDataset(
              source: 'NASA_MODIS_MOD13Q1',
              product: ModisService.ndviBand,
              provider: 'NASA ORNL DAAC MODIS/VIIRS Land Product Subsets',
              resolution: '250 m, 16-day composite',
              units: const {'ndvi': '1'},
              observations: [
                for (final p in points)
                  PackageObservation(
                    date: p.date,
                    variable: 'ndvi',
                    value: double.parse(p.ndvi.toStringAsFixed(4)),
                    quality: p.reliability,
                  ),
              ],
              notes: const [
                'NDVI — косвенный показатель зелени, не диагноз растений, '
                    'не азот, не pH и не влажность почвы.',
                'Точка = один пиксель MODIS около 250 × 250 м; маленькое поле '
                    'может смешиваться с соседними участками.',
              ],
            ),
          );
        }
      } on Object catch (error) {
        missing.add('NDVI MODIS недоступен: $error');
      }
    }

    if (wantClimate) {
      try {
        final series = await power.fetchDailySeries(
          latitude: latitude,
          longitude: longitude,
          start: start,
          end: end,
        );
        const variables = {
          'T2M': ('t2m', '°C'),
          'T2M_MIN': ('t2m_min', '°C'),
          'PRECTOTCORR': ('precipitation', 'mm/day'),
        };
        final observations = <PackageObservation>[
          for (final entry in variables.entries)
            for (final day in (series[entry.key] ?? const <DateTime, double>{}).entries)
              PackageObservation(
                date: day.key,
                variable: entry.value.$1,
                value: day.value,
              ),
        ]..sort((a, b) => a.date.compareTo(b.date));

        if (observations.isEmpty) {
          missing.add('NASA POWER: за период нет данных.');
        } else {
          final last = observations.map((o) => o.date).reduce((a, b) => a.isAfter(b) ? a : b);
          final lag = end.difference(last).inDays;
          if (lag > 0) {
            missing.add('NASA POWER: последние $lag дн. ещё не обработаны.');
          }
          datasets.add(
            PackageDataset(
              source: 'NASA_POWER',
              product: 'daily_agrometeorology',
              provider: 'NASA POWER (MERRA-2, ~50 km)',
              resolution: '0.5° × 0.625°, daily',
              units: {for (final v in variables.values) v.$1: v.$2},
              observations: observations,
              notes: [
                if (kind == DataRequestKind.sowing)
                  'Климатический контекст для планирования посева; дату посева '
                      'приложение не назначает автоматически.',
                'Модельные данные по ячейке около 50 км, не метеостанция поля.',
              ],
            ),
          );
        }
      } on Object catch (error) {
        missing.add('NASA POWER недоступен: $error');
      }
    }

    final status = datasets.isEmpty
        ? PackageStatus.unavailable
        : missing.isEmpty && warnings.isEmpty
            ? PackageStatus.ready
            : PackageStatus.partial;

    final package = DataPackage(
      requestId: store.nextRequestId(now),
      createdAt: now,
      field: PackageField(
        fieldId: fieldId,
        latitude: latitude,
        longitude: longitude,
        geometryNote: 'point; MODIS pixel ~250 m; NASA POWER cell ~50 km',
      ),
      periodStart: start,
      periodEnd: end,
      datasets: datasets,
      quality: PackageQuality(status: status, missingData: missing, warnings: warnings),
    );

    if (status == PackageStatus.unavailable) {
      await store.save();
      return BuiltPackage(package, null);
    }

    final token = _token();
    final payload = package.encode();
    await File('${store.packagesDir.path}/$token.json').writeAsString(payload);
    final record = PackageRecord(
      token: token,
      requestId: package.requestId,
      ownerHash: ownerHash,
      createdAt: now,
      expiresAt: now.add(config.packageTtl),
      bytes: utf8.encode(payload).length,
    );
    store.packages[token] = record;
    await store.save();
    return BuiltPackage(package, record);
  }
}
