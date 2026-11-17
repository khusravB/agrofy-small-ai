/// Команды SMS-канала AGROFY. Один и тот же разбор используется сервером
/// (входящие SMS) и приложением (подготовка текста перед отправкой).
library;

import 'field_code.dart';

export 'field_code.dart' show FarmerGoal;

enum SmsCommandType {
  help,
  stop,
  start,
  reset,
  register,
  selectField,
  dataRequest,

  /// Все данные поля одним отчётом: INFO F1 (или INFO — активное поле).
  info,

  /// Список полей этого номера: FIELDS.
  listFields,

  /// Следующая часть длинного ответа: ЕЩЁ (или все сразу: ВСЁ).
  more,

  /// Свободный вопрос к языковой модели: /ВОПРОС текст.
  ask,
  question,
}

/// Тип запроса данных.
enum DataRequestKind {
  /// Индекс вегетации NDVI (MODIS) за период.
  ndvi('NDVI', 90, 366, ['НДВИ']),

  /// Суточная агрометеорология NASA POWER за период.
  climate('CLIMATE', 365, 3 * 366, ['КЛИМАТ', 'ПОГОДА']),

  /// NDVI за несколько лет — сезонная динамика поля.
  history('HISTORY', 3 * 365, 5 * 366, ['ИСТОРИЯ']),

  /// Климатический контекст для планирования посева (не дата посева).
  sowing('SOWING', 365, 366, ['ПОСЕВ', 'СЕВ']),

  /// NDVI и климат вместе.
  data('DATA', 90, 366, ['ДАННЫЕ']);

  final String keyword;
  final int defaultDays;
  final int maxDays;

  /// Русские слова, которые понимаются наравне с [keyword].
  final List<String> aliases;

  const DataRequestKind(this.keyword, this.defaultDays, this.maxDays, this.aliases);

  bool matches(String word) {
    final upper = word.toUpperCase();
    return upper == keyword || aliases.contains(upper);
  }
}

class GeoPoint {
  final double latitude;
  final double longitude;

  const GeoPoint(this.latitude, this.longitude);

  bool get valid =>
      latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180;

  String format() =>
      '${latitude.toStringAsFixed(4)},${longitude.toStringAsFixed(4)}';
}

class SmsCommand {
  final SmsCommandType type;

  /// Идентификатор поля (F102) — для регистрации, выбора и запросов.
  final String? fieldId;

  /// Координаты — для регистрации поля и запросов по точке.
  final GeoPoint? point;

  final DataRequestKind? kind;

  /// Период запроса, дней.
  final int? days;

  /// Культура при регистрации или текст вопроса.
  final String? text;

  /// Цель фермера (INFO … ВОДА).
  final FarmerGoal? goal;

  /// Ошибка разбора: команда распознана, но параметры неверны.
  final String? error;

  const SmsCommand(
    this.type, {
    this.fieldId,
    this.point,
    this.kind,
    this.days,
    this.text,
    this.goal,
    this.error,
  });

  bool get isValid => error == null;

  static final RegExp _fieldId = RegExp(r'^[A-Z][A-Z0-9]{1,9}$');
  static final RegExp _coordinates =
      RegExp(r'^(-?\d{1,2}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)$');
  static final RegExp _period = RegExp(r'^(\d{1,4})([DMYДМГЛ])$');

  static const Map<String, SmsCommandType> _keywords = {
    'HELP': SmsCommandType.help,
    'ПОМОЩЬ': SmsCommandType.help,
    '?': SmsCommandType.help,
    'STOP': SmsCommandType.stop,
    'СТОП': SmsCommandType.stop,
    'START': SmsCommandType.start,
    'СТАРТ': SmsCommandType.start,
    'NEW': SmsCommandType.reset,
    'НОВЫЙ': SmsCommandType.reset,
    'ЕЩЁ': SmsCommandType.more,
    'ЕЩЕ': SmsCommandType.more,
    'MORE': SmsCommandType.more,
    'ДАЛЬШЕ': SmsCommandType.more,
    'ДАЛЕЕ': SmsCommandType.more,
    'FIELDS': SmsCommandType.listFields,
    'ПОЛЯ': SmsCommandType.listFields,
  };

  static const Set<String> _infoWords = {'INFO', 'ИНФО', 'REPORT', 'ОТЧЕТ', 'ОТЧЁТ'};

  static SmsCommand parse(String raw) {
    final text = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    final words = text.split(' ');
    // «/INFO» — как в мессенджерах: косая черта перед командой допустима.
    final head = words.first
        .toUpperCase()
        .replaceFirst(RegExp(r'^/'), '')
        .replaceAll(RegExp(r'[.!?,]+$'), '');

    if (words.length == 1 && _keywords.containsKey(head)) {
      return SmsCommand(_keywords[head]!);
    }

    // ВСЁ — все оставшиеся части длинного ответа сразу.
    if (words.length == 1 && const {'ВСЁ', 'ВСЕ', 'ALL'}.contains(head)) {
      return const SmsCommand(SmsCommandType.more, text: 'all');
    }

    if (head == 'REG' || head == 'РЕГ') {
      return _parseRegister(words.skip(1).toList());
    }

    // К языковой модели — только явной командой: «/ВОПРОС …» (с косой
    // чертой) или QUESTION; обычный текст «Вопрос про полив» остаётся
    // встроенному советнику.
    final slash = words.first.startsWith('/');
    if ((slash && const {'ВОПРОС', 'QUESTION', 'Q', 'ASK', 'СПРОСИТЬ'}.contains(head)) ||
        head == 'QUESTION') {
      final question = words.skip(1).join(' ').trim();
      return SmsCommand(
        SmsCommandType.ask,
        text: question.isEmpty ? null : question,
        error: question.isEmpty ? 'Напишите вопрос после команды: /ВОПРОС чем подкормить хлопок?' : null,
      );
    }

    if (_infoWords.contains(head)) {
      return _parseInfo(words.skip(1).toList());
    }

    if (head == 'FIELD' || head == 'ПОЛЕ') {
      return _parseField(words.skip(1).toList());
    }

    return SmsCommand(SmsCommandType.question, text: text);
  }

  /// INFO [F1 | широта,долгота] [КУЛЬТУРА] [ЦЕЛЬ]:
  /// `/INFO 40.28,69.62 ХЛОПОК ВОДА`, `INFO F1 ДОХОД`, `INFO`.
  static SmsCommand _parseInfo(List<String> args) {
    const format = 'Формат: INFO 40.28,69.62 ХЛОПОК ВОДА '
        '(цель: ВОДА, ПОЧВА, ДОХОД или УСТОЙЧИВОСТЬ) или INFO F1.';
    String? fieldId;
    GeoPoint? point;
    var rest = args;
    if (rest.isNotEmpty) {
      final first = rest.first;
      final upper = first.toUpperCase();
      if (_fieldId.hasMatch(upper) && FarmerGoal.fromWord(upper) == null) {
        fieldId = upper;
        rest = rest.skip(1).toList();
        // INFO F5 40.28,69.62 … — поле с номером из приложения.
        if (rest.isNotEmpty && RegExp(r'^-?\d').hasMatch(rest.first)) {
          point = _point(rest.first);
          if (point == null) {
            return const SmsCommand(SmsCommandType.info, error: format);
          }
          rest = rest.skip(1).toList();
        }
      } else if (RegExp(r'^-?\d').hasMatch(first)) {
        point = _point(first);
        if (point == null) {
          return const SmsCommand(SmsCommandType.info, error: format);
        }
        rest = rest.skip(1).toList();
      }
    }
    FarmerGoal? goal;
    if (rest.isNotEmpty) {
      goal = FarmerGoal.fromWord(rest.last);
      if (goal != null) {
        rest = rest.sublist(0, rest.length - 1);
      }
    }
    // «ЭКОНОМИЯ ВОДЫ» — две слова одной цели.
    if (goal == FarmerGoal.water && rest.isNotEmpty && FarmerGoal.fromWord(rest.last) == FarmerGoal.water) {
      rest = rest.sublist(0, rest.length - 1);
    }
    final crop = rest.join(' ').trim();
    return SmsCommand(
      SmsCommandType.info,
      fieldId: fieldId,
      point: point,
      text: crop.isEmpty ? null : crop,
      goal: goal,
    );
  }

  static GeoPoint? _point(String word) {
    final match = _coordinates.firstMatch(word);
    if (match == null) {
      return null;
    }
    final point = GeoPoint(
      double.parse(match.group(1)!),
      double.parse(match.group(2)!),
    );
    return point.valid ? point : null;
  }

  static SmsCommand _parseRegister(List<String> args) {
    if (args.length < 2) {
      return const SmsCommand(
        SmsCommandType.register,
        error: 'Формат: REG F102 40.28,69.62 ХЛОПОК',
      );
    }
    final id = args[0].toUpperCase();
    final point = _point(args[1]);
    if (!_fieldId.hasMatch(id)) {
      return const SmsCommand(
        SmsCommandType.register,
        error: 'ID поля: латинская буква и до 9 букв или цифр, например F102.',
      );
    }
    if (point == null) {
      return const SmsCommand(
        SmsCommandType.register,
        error: 'Координаты: широта,долгота, например 40.28,69.62.',
      );
    }
    return SmsCommand(
      SmsCommandType.register,
      fieldId: id,
      point: point,
      text: args.length > 2 ? args.skip(2).join(' ') : null,
    );
  }

  static SmsCommand _parseField(List<String> args) {
    if (args.isEmpty) {
      return const SmsCommand(
        SmsCommandType.selectField,
        error: 'Укажите поле: FIELD F102 или FIELD F102 NDVI 90D.',
      );
    }

    final target = args[0];
    final point = _point(target);
    final id = point == null ? target.toUpperCase() : null;
    if (point == null && !_fieldId.hasMatch(id!)) {
      return const SmsCommand(
        SmsCommandType.selectField,
        error: 'Поле: ID вида F102 или координаты 40.28,69.62.',
      );
    }

    if (args.length == 1) {
      if (point != null) {
        return const SmsCommand(
          SmsCommandType.dataRequest,
          error: 'Для точки укажите тип данных: FIELD 40.28,69.62 NDVI 90D.',
        );
      }
      return SmsCommand(SmsCommandType.selectField, fieldId: id);
    }

    DataRequestKind? kind;
    for (final candidate in DataRequestKind.values) {
      if (candidate.matches(args[1])) {
        kind = candidate;
      }
    }
    if (kind == null) {
      return SmsCommand(
        SmsCommandType.dataRequest,
        fieldId: id,
        point: point,
        error: 'Тип данных: '
            '${DataRequestKind.values.map((k) => k.keyword).join(', ')}.',
      );
    }

    var days = kind.defaultDays;
    if (args.length > 2) {
      final match = _period.firstMatch(args[2].toUpperCase());
      if (match == null) {
        return SmsCommand(
          SmsCommandType.dataRequest,
          fieldId: id,
          point: point,
          kind: kind,
          error: 'Период: число и D, M или Y, например 90D или 1Y.',
        );
      }
      final value = int.parse(match.group(1)!);
      days = switch (match.group(2)) {
        'D' || 'Д' => value,
        'M' || 'М' => value * 30,
        _ => value * 365,
      };
    }
    if (days < 1 || days > kind.maxDays) {
      return SmsCommand(
        SmsCommandType.dataRequest,
        fieldId: id,
        point: point,
        kind: kind,
        error: '${kind.keyword}: период от 1 дня до '
            '${(kind.maxDays / 365).floor()} лет.',
      );
    }

    return SmsCommand(
      SmsCommandType.dataRequest,
      fieldId: id,
      point: point,
      kind: kind,
      days: days,
    );
  }

  // ----------------------------------------
  // Подготовка текста в приложении
  // ----------------------------------------

  static String formatRegister(String fieldId, GeoPoint point, {String? crop}) =>
      'REG $fieldId ${point.format()}${crop == null ? '' : ' $crop'}';

  /// Текст SMS «отчёт и совет по полю»: с координатами и культурой поле
  /// само регистрируется на сервере; цель фермер дописывает сам
  /// (ВОДА, ПОЧВА, ДОХОД, УСТОЙЧИВОСТЬ).
  static String formatInfo(String fieldId, {GeoPoint? point, String? crop, FarmerGoal? goal}) {
    if (point == null) {
      return 'INFO $fieldId';
    }
    return [
      'INFO',
      fieldId,
      '${point.latitude.toStringAsFixed(4)},${point.longitude.toStringAsFixed(4)}',
      if (crop != null && crop.trim().isNotEmpty) crop.trim().toUpperCase(),
      if (goal != null) goal.name == 'water' ? 'ВОДА' : goal.name == 'soil' ? 'ПОЧВА' : goal.name == 'income' ? 'ДОХОД' : 'УСТОЙЧИВОСТЬ',
    ].join(' ');
  }

  static String formatRequest({
    String? fieldId,
    GeoPoint? point,
    required DataRequestKind kind,
    int? days,
  }) {
    final target = fieldId ?? point!.format();
    final period = days ?? kind.defaultDays;
    final label = period % 365 == 0
        ? '${period ~/ 365}Y'
        : period % 30 == 0 && period >= 60
            ? '${period ~/ 30}M'
            : '${period}D';
    return 'FIELD $target ${kind.keyword} $label';
  }

  static String fieldIdForLocal(int localId) => 'F$localId';
}
