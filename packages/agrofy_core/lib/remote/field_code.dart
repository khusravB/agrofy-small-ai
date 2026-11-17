import 'package:crypto/crypto.dart';
import 'dart:convert';

import '../models/climate_summary.dart';
import '../models/farmer_priorities.dart';

/// Цель фермера в SMS: ВОДА, ПОЧВА, ДОХОД, УСТОЙЧИВОСТЬ.
enum FarmerGoal {
  water('w', 'экономия воды'),
  soil('s', 'восстановление почвы'),
  income('i', 'доход'),
  resilience('r', 'устойчивость к погоде');

  final String code;
  final String label;

  const FarmerGoal(this.code, this.label);

  static const Map<String, FarmerGoal> _words = {
    'ВОДА': water, 'ВОДУ': water, 'ВОДЫ': water, 'ПОЛИВ': water, 'WATER': water,
    'ЭКОНОМИЯ': water,
    'ПОЧВА': soil, 'ПОЧВУ': soil, 'ПОЧВЫ': soil, 'SOIL': soil,
    'ДОХОД': income, 'ПРИБЫЛЬ': income, 'ДЕНЬГИ': income, 'INCOME': income,
    'УСТОЙЧИВОСТЬ': resilience, 'ЗАСУХА': resilience, 'РИСК': resilience,
    'RESILIENCE': resilience,
  };

  static FarmerGoal? fromWord(String word) => _words[word.toUpperCase()];

  static FarmerGoal? fromCode(String code) {
    for (final goal in values) {
      if (goal.code == code) {
        return goal;
      }
    }
    return null;
  }

  /// Приоритеты советника: выбранная цель главная, остальные учитываются.
  FarmerPriorities priorities({int rotationYears = 3}) => FarmerPriorities(
        water: this == water ? 1.0 : 0.3,
        soil: this == soil ? 1.0 : 0.3,
        income: this == income ? 1.0 : 0.3,
        resilience: this == resilience ? 1.0 : 0.3,
        rotationYears: rotationYears,
      );
}

/// Данные поля, переданные по SMS кодом из латиницы и цифр, — чтобы
/// приложение работало без интернета: климат NASA POWER по месяцам, цель
/// и рекомендованный севооборот. Контрольная сумма ловит опечатки и
/// обрезанные сообщения.
///
/// `AGF1;F1;40.2800;69.6200;cotton;w;512;1991-2020;tMean;tRange;tMax;осадки;заморозки;влажность;cotton>chickpea>wheat;3a9f1c`
class FieldCode {
  static const String prefix = 'AGF1';

  final String fieldId;
  final double latitude;
  final double longitude;
  final String? cropId;
  final FarmerGoal? goal;
  final ClimateSummary climate;
  final List<String> rotation;

  const FieldCode({
    required this.fieldId,
    required this.latitude,
    required this.longitude,
    required this.climate,
    this.cropId,
    this.goal,
    this.rotation = const [],
  });

  static String _n(double v, int digits) {
    final text = v.toStringAsFixed(digits);
    // «-0.0» и лишние нули не нужны: код должен быть коротким.
    final trimmed = digits == 0 ? text : text.replaceFirst(RegExp(r'\.?0+$'), '');
    return trimmed == '-0' ? '0' : trimmed;
  }

  static String _list(List<double> values, int digits) =>
      values.map((v) => _n(v, digits)).join(',');

  /// Из описания периода NASA POWER оставляем только годы: «2001-2025».
  static String _years(String period) {
    final years = RegExp(r'(19|20)\d\d').allMatches(period).map((m) => m.group(0)!).toList();
    if (years.isEmpty) {
      return '';
    }
    return years.length == 1 ? years.first : '${years.first}-${years.last}';
  }

  static String _checksum(String body) =>
      sha256.convert(utf8.encode(body)).toString().substring(0, 6);

  String encode() {
    final c = climate;
    final body = [
      prefix,
      fieldId,
      latitude.toStringAsFixed(4),
      longitude.toStringAsFixed(4),
      cropId ?? '',
      goal?.code ?? '',
      c.gridElevation == null ? '' : c.gridElevation!.round().toString(),
      _years(c.period),
      _list(c.tMean, 1),
      _list(c.tRange, 1),
      _list(c.tMaxExtreme, 1),
      _list(c.precipMm, 0),
      _list(c.frostDays, 0),
      c.rootWetness == null ? '' : _list([for (final w in c.rootWetness!) w * 100], 0),
      rotation.join('>'),
    ].join(';');
    return '$body;${_checksum(body)}';
  }

  /// Находит и разбирает код в любом тексте (например, в скопированном
  /// SMS). Бросает [FormatException] с понятной причиной.
  static FieldCode find(String text, {DateTime? receivedAt}) {
    final match = RegExp('$prefix;[^\\s]+').firstMatch(text);
    if (match == null) {
      throw const FormatException('В тексте нет кода AGROFY (он начинается с AGF1;).');
    }
    final raw = match.group(0)!;
    final cut = raw.lastIndexOf(';');
    final body = raw.substring(0, cut);
    if (raw.substring(cut + 1) != _checksum(body)) {
      throw const FormatException(
        'Код повреждён или скопирован не полностью — скопируйте последнее SMS целиком.',
      );
    }
    final f = body.split(';');
    if (f.length != 15) {
      throw const FormatException('Неизвестный формат кода.');
    }

    List<double> list(String s, {int expected = 12, double scale = 1}) {
      final values = [for (final v in s.split(',')) double.parse(v) * scale];
      if (values.length != expected) {
        throw const FormatException('В коде не хватает месяцев.');
      }
      return values;
    }

    final latitude = double.parse(f[2]);
    final longitude = double.parse(f[3]);
    return FieldCode(
      fieldId: f[1],
      latitude: latitude,
      longitude: longitude,
      cropId: f[4].isEmpty ? null : f[4],
      goal: FarmerGoal.fromCode(f[5]),
      rotation: f[14].isEmpty ? const [] : f[14].split('>'),
      climate: ClimateSummary(
        latitude: latitude,
        longitude: longitude,
        gridElevation: f[6].isEmpty ? null : double.parse(f[6]),
        period: f[7],
        tMean: list(f[8]),
        tRange: list(f[9]),
        tMaxExtreme: list(f[10]),
        precipMm: list(f[11]),
        frostDays: list(f[12]),
        rootWetness: f[13].isEmpty ? null : list(f[13], scale: 0.01),
        fetchedAt: receivedAt ?? DateTime.now(),
      ),
    );
  }
}
