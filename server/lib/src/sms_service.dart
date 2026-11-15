import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agrofy_core/ai/farm_assistant.dart';
import 'package:agrofy_core/ai/climate_pattern_model.dart';
import 'package:agrofy_core/data/crop_catalog.dart';
import 'package:agrofy_core/models/climate_history.dart';
import 'package:agrofy_core/decision/decision_engine.dart';
import 'package:agrofy_core/decision/evidence_validator.dart';
import 'package:agrofy_core/decision/observation.dart';
import 'package:agrofy_core/decision/observation_interpreter.dart';
import 'package:agrofy_core/models/climate_summary.dart';
import 'package:agrofy_core/models/field.dart';
import 'package:agrofy_core/remote/package_text.dart';
import 'package:agrofy_core/remote/sms_command.dart';
import 'package:agrofy_core/remote/sms_text.dart';
import 'package:agrofy_core/services/nasa_power_service.dart';
import 'package:agrofy_core/services/rotation_advisor.dart';
import 'package:crypto/crypto.dart';

import 'config.dart';
import 'data_service.dart';
import 'providers.dart';
import 'reports.dart';
import 'store.dart';

/// Результат обработки входящего SMS: что ответить сразу и что доделать
/// в фоне (подготовка пакета данных занимает до минуты).
class SmsOutcome {
  final List<String> replies;
  final Future<void> Function()? background;

  const SmsOutcome(this.replies, [this.background]);

  static const SmsOutcome silent = SmsOutcome([]);
}

/// Command Parser + Conversation Service + AI Orchestrator.
///
/// Вопрос обрабатывают те же модули, что и в приложении: Small AI
/// понимает текст, Evidence Validator и Decision Engine дают проверяемый
/// ответ. Генеративная модель на сервере не используется.
class SmsService {
  static const int maxInboundLength = 480;

  static const String helpText =
      'AGROFY: вопрос — обычным текстом. Поле: REG F1 40.28,69.62 ХЛОПОК. '
      'Всё о поле: INFO F1. Поля: FIELDS. Спутник: FIELD F1 NDVI 90D. '
      'ЕЩЁ — продолжение, NEW — сброс, STOP — отписка.';

  final ServerConfig config;
  final Store store;
  final DataPackageService data;
  final SmsProvider provider;
  final NasaPowerService power;
  final ReportService reports;
  final DateTime Function() clock;

  final FarmAssistant _assistant = FarmAssistant();
  static const _interpreter = ObservationInterpreter();
  static const _validator = EvidenceValidator();
  static const _engine = DecisionEngine();
  static const _advisor = RotationAdvisor();

  SmsService({
    required this.config,
    required this.store,
    required this.data,
    required this.provider,
    NasaPowerService? power,
    ReportService? reports,
    DateTime Function()? clock,
  })  : power = power ?? NasaPowerService(),
        reports = reports ?? ReportService(config, store, clock: clock),
        clock = clock ?? DateTime.now;

  /// Обезличенный номер для журнала.
  String phoneHash(String phone) => sha256
      .convert(utf8.encode('${config.auditSalt}:$phone'))
      .toString()
      .substring(0, 16);

  String _fit(List<String> parts) =>
      SmsText.fit(parts, maxSegments: config.maxReplySegments);

  /// Не помещается ли текст целиком в одно SMS-сообщение (с учётом лимита
  /// сегментов).
  bool _fitsWhole(List<String> parts) =>
      SmsText.segments(parts.join(' ')) <= config.maxReplySegments;

  /// Длинный ответ. По умолчанию — страницами: первая уходит сразу,
  /// остальные по команде ЕЩЁ (интернет не нужен). Если включены ссылки —
  /// начало ([shortParts] или [parts]) и ссылка на страницу с полным текстом.
  Future<List<String>> _long(
    InboundSms sms,
    Conversation conversation,
    List<String> parts, {
    required String title,
    List<ReportSection> Function()? sections,
    List<String>? shortParts,
    String? footer,
  }) async {
    conversation.pages.clear();
    if (_fitsWhole(parts)) {
      return [_fit(parts)];
    }
    if (config.reportLinks) {
      final url = await reports.publish(
        ownerHash: phoneHash(sms.from),
        title: title,
        sections: sections?.call() ?? [ReportSection(title, paragraphs: parts)],
        footer: footer,
      );
      return [_withLink(shortParts ?? parts, url)];
    }
    final pages = SmsText.paginate(
      parts,
      maxSegments: config.maxReplySegments,
      maxPages: config.maxPages,
    );
    return _sendNow(conversation, pages);
  }

  /// Сколько частей отправить сразу ([ServerConfig.pagesAtOnce]); остальные
  /// ждут команды ЕЩЁ или ВСЁ, и последняя отправленная часть это говорит.
  List<String> _sendNow(Conversation conversation, List<String> pages, {int? count}) {
    final take = (count ?? config.pagesAtOnce).clamp(1, pages.length);
    final now = pages.take(take).toList();
    final rest = pages.skip(take).toList();
    conversation.pages
      ..clear()
      ..addAll(rest);
    if (rest.isNotEmpty) {
      now[now.length - 1] = '${now.last} ${SmsText.moreHint}';
    }
    return now;
  }

  /// Начало ответа целыми предложениями и ссылка на полный текст.
  String _withLink(List<String> parts, String url) => SmsText.fit(
        parts,
        maxSegments: config.maxReplySegments,
        suffix: ' Полностью: $url',
      );

  Future<void> _audit(String phone, String type, List<String> replies) async {
    final line = jsonEncode({
      'at': clock().toUtc().toIso8601String(),
      'phone': phoneHash(phone),
      'type': type,
      'segments_out': replies.fold<int>(0, (s, r) => s + SmsText.segments(r)),
    });
    await File('${config.dataDir}/audit.jsonl')
        .writeAsString('$line\n', mode: FileMode.append);
  }

  Future<SmsOutcome> handle(InboundSms sms) async {
    final now = clock();
    await store.purge(now, config.contextTtl);

    // Повтор того же сообщения (провайдер прислал вебхук ещё раз).
    if (store.seenMessages.containsKey(sms.messageId)) {
      return SmsOutcome.silent;
    }
    store.seenMessages[sms.messageId] = now;

    final conversation = store.conversation(sms.from, now);
    final command = SmsCommand.parse(sms.text);

    // Отписка соблюдается всегда; после неё отвечаем только на START.
    if (command.type == SmsCommandType.stop) {
      conversation
        ..optedOut = true
        ..facts = null
        ..updatedAt = now;
      await store.save();
      const reply = 'AGROFY: вы отписаны, ответов больше не будет. '
          'START — снова включить.';
      await _audit(sms.from, 'stop', [reply]);
      return const SmsOutcome([reply]);
    }
    if (conversation.optedOut && command.type != SmsCommandType.start) {
      await store.save();
      return SmsOutcome.silent;
    }

    // Лимиты: при превышении отвечаем один раз, дальше молчим.
    final lastHour = conversation.inbound
        .where((d) => now.difference(d) < const Duration(hours: 1))
        .length;
    final lastDay = conversation.inbound.length;
    conversation.inbound.add(now);
    conversation.updatedAt = now;
    if (lastHour >= config.maxPerHour || lastDay >= config.maxPerDay) {
      await store.save();
      final firstOver = lastHour == config.maxPerHour || lastDay == config.maxPerDay;
      if (!firstOver) {
        return SmsOutcome.silent;
      }
      const reply = 'AGROFY: лимит сообщений исчерпан, попробуйте позже.';
      await _audit(sms.from, 'limit', [reply]);
      return const SmsOutcome([reply]);
    }

    if (sms.text.length > maxInboundLength) {
      await store.save();
      const reply = 'AGROFY: сообщение слишком длинное. Опишите вопрос короче.';
      return const SmsOutcome([reply]);
    }

    // Новое сообщение заменяет недочитанный длинный ответ.
    if (command.type != SmsCommandType.more) {
      conversation.pages.clear();
    }
    final outcome = await _dispatch(sms, command, conversation, now);
    await store.save();
    await _audit(sms.from, command.type.name, outcome.replies);
    return outcome;
  }

  Future<SmsOutcome> _dispatch(
    InboundSms sms,
    SmsCommand command,
    Conversation conversation,
    DateTime now,
  ) async {
    if (!command.isValid) {
      return SmsOutcome([_fit(['AGROFY: ${command.error}'])]);
    }

    switch (command.type) {
      case SmsCommandType.help:
        return SmsOutcome(await _long(sms, conversation, [helpText], title: 'Команды AGROFY'));

      case SmsCommandType.start:
        conversation.optedOut = false;
        return SmsOutcome([_fit(['AGROFY: ответы снова включены.', helpText])]);

      case SmsCommandType.reset:
        conversation.facts = null;
        return const SmsOutcome(['AGROFY: диалог начат заново.']);

      case SmsCommandType.register:
        final fields = store.fields.putIfAbsent(sms.from, () => {});
        final cropText = command.text;
        final cropKnown = _cropId(cropText) != null;
        final record = FieldRecord(
          fieldId: command.fieldId!,
          latitude: command.point!.latitude,
          longitude: command.point!.longitude,
          crop: command.text,
          registeredAt: now,
        );
        fields[command.fieldId!] = record;
        conversation.activeField = command.fieldId;
        return SmsOutcome(
          [
            _fit([
              'AGROFY: поле ${command.fieldId} сохранено '
                  '(${command.point!.format()}'
                  '${cropText == null ? '' : ', ${cropText.toLowerCase()}'}).',
              if (cropText == null)
                'Культура не указана — советы по севообороту будут недоступны. '
                    'Добавьте её: REG ${command.fieldId} ${command.point!.format()} ХЛОПОК.'
              else if (!cropKnown)
                'Культуры «${cropText.toLowerCase()}» нет в справочнике. '
                    'Примеры: ХЛОПОК, ПШЕНИЦА, МАШ, ЛЮЦЕРНА, ТОМАТ.',
              'Вопросы теперь учитывают климат NASA этого поля.',
            ]),
          ],
          () async {
            await _climateFor(sms.from, record);
            await _historyFor(sms.from, fields[command.fieldId!]!);
          },
        );

      case SmsCommandType.selectField:
        final record = store.fields[sms.from]?[command.fieldId];
        if (record == null) {
          return SmsOutcome([
            _fit([
              'AGROFY: поле ${command.fieldId} не найдено для этого номера.',
              'Зарегистрируйте: REG ${command.fieldId} 40.28,69.62 ХЛОПОК',
            ]),
          ]);
        }
        conversation
          ..activeField = command.fieldId
          ..facts = null;
        return SmsOutcome(['AGROFY: выбрано поле ${command.fieldId}.']);

      case SmsCommandType.dataRequest:
        return _dataRequest(sms, command, conversation, now);

      case SmsCommandType.info:
        return _info(sms, command, conversation, now);

      case SmsCommandType.more:
        if (conversation.pages.isEmpty) {
          return const SmsOutcome(['AGROFY: продолжения нет. Задайте новый вопрос.']);
        }
        return SmsOutcome(_sendNow(
          conversation,
          List.of(conversation.pages),
          count: command.text == 'all' ? conversation.pages.length : null,
        ));

      case SmsCommandType.listFields:
        final mine = store.fields[sms.from] ?? const <String, FieldRecord>{};
        if (mine.isEmpty) {
          return SmsOutcome([
            _fit([
              'AGROFY: у этого номера нет полей.',
              'Добавьте: REG F1 40.28,69.62 ХЛОПОК',
            ]),
          ]);
        }
        final list = [
          for (final r in mine.values)
            '${r.fieldId} (${r.crop?.toLowerCase() ?? 'культура не указана'}, '
                '${r.latitude.toStringAsFixed(2)},${r.longitude.toStringAsFixed(2)})',
        ];
        final active = conversation.activeField;
        final parts = [
          'AGROFY: ваши поля: ${list.join('; ')}.',
          if (active != null) 'Текущее: $active.',
          'Всё о поле: INFO ${active ?? mine.keys.first}.',
        ];
        return SmsOutcome(
          await _long(
            sms,
            conversation,
            parts,
            title: 'Поля AGROFY',
            sections: () => [ReportSection('Ваши поля', items: list)],
            shortParts: ['AGROFY: полей ${mine.length}.', if (active != null) 'Текущее: $active.'],
          ),
        );

      case SmsCommandType.question:
        final replies = await _answer(sms, command.text ?? '', conversation, now);
        final active = conversation.activeField == null
            ? null
            : store.fields[sms.from]?[conversation.activeField];
        // Поле зарегистрировано до появления истории или загрузка не
        // удалась — догружаем в фоне, следующий ответ её учтёт.
        return SmsOutcome(
          replies,
          active != null && active.history == null
              ? () => _historyFor(sms.from, active).then((_) {})
              : null,
        );

      case SmsCommandType.stop:
        return SmsOutcome.silent;
    }
  }

  Future<SmsOutcome> _dataRequest(
    InboundSms sms,
    SmsCommand command,
    Conversation conversation,
    DateTime now,
  ) async {
    double latitude;
    double longitude;
    final fieldId = command.fieldId;

    if (fieldId != null) {
      final record = store.fields[sms.from]?[fieldId];
      if (record == null) {
        return SmsOutcome([
          _fit([
            'AGROFY: нет доступа к полю $fieldId с этого номера.',
            'Зарегистрируйте его: REG $fieldId широта,долгота',
          ]),
        ]);
      }
      latitude = record.latitude;
      longitude = record.longitude;
    } else {
      latitude = command.point!.latitude;
      longitude = command.point!.longitude;
    }

    if (conversation.dataRequests.length >= config.maxDataRequestsPerDay) {
      return const SmsOutcome(['AGROFY: лимит запросов данных на сегодня исчерпан.']);
    }
    conversation.dataRequests.add(now);

    final target = fieldId ?? command.point!.format();
    final kind = command.kind!;
    final days = command.days!;
    final owner = phoneHash(sms.from);

    Future<void> work() async {
      List<String> replies;
      try {
        final built = await data.build(
          ownerHash: owner,
          kind: kind,
          days: days,
          latitude: latitude,
          longitude: longitude,
          fieldId: fieldId,
        );
        final pages = _packagePages(built, target, kind);
        replies = _sendNow(store.conversation(sms.from, clock()), pages);
        await store.save();
      } on Object {
        replies = [
          'AGROFY: не удалось подготовить данные для $target. Повторите позже.',
        ];
      }
      // По порядку: следующая часть уходит после предыдущей.
      for (final reply in replies) {
        await provider.send(sms.from, reply);
      }
      await _audit(sms.from, 'data_ready', replies);
    }

    return SmsOutcome(
      [
        _fit([
          'AGROFY: запрос ${kind.keyword} для $target принят.',
          'Данные пришлём SMS через 1–2 минуты.',
        ]),
      ],
      work,
    );
  }

  /// Данные пакета текстом (интернет не нужен); ссылка на файл для
  /// импорта — только если ссылки включены.
  List<String> _packagePages(BuiltPackage built, String target, DataRequestKind kind) {
    final package = built.package;
    final url = built.url(config.publicUrl);
    if (url == null) {
      return [_packageMessage(built, target, kind)];
    }
    String day(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';
    final parts = [
      'AGROFY ${package.requestId}: ${kind.keyword} $target '
          '${day(package.periodStart)}–${day(package.periodEnd)}.${package.periodEnd.year}, '
          '${package.quality.statusLabel}.',
      if (config.reportLinks)
        'Файл для импорта (до ${day(built.record!.expiresAt)}): $url',
      ...PackageText.describe(package),
    ];
    if (_fitsWhole(parts)) {
      return [_fit(parts)];
    }
    return SmsText.paginate(
      parts,
      maxSegments: config.maxReplySegments,
      maxPages: config.maxPages,
    );
  }

  String _packageMessage(BuiltPackage built, String target, DataRequestKind kind) {
    final package = built.package;
    String day(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

    final url = built.url(config.publicUrl);
    if (url == null) {
      final reason = package.quality.missingData.isEmpty
          ? ''
          : ' ${package.quality.missingData.first}';
      return SmsText.truncate(
        'AGROFY: данных ${kind.keyword} для $target за период нет (UNAVAILABLE).$reason',
        config.maxReplySegments,
      );
    }

    // Ссылка не обрезается: она идёт отдельной обязательной частью.
    final expires = built.record!.expiresAt;
    final head = 'AGROFY: данные ${kind.keyword} $target '
        '${day(package.periodStart)}–${day(package.periodEnd)}.${package.periodEnd.year}, '
        '${package.quality.statusLabel}. До ${day(expires)}: $url';
    return _fit([head, 'Импорт: AGROFY → AI → Данные.']);
  }

  Future<ClimateSummary?> _climateFor(String phone, FieldRecord record) async {
    final cached = record.climate;
    if (cached != null) {
      try {
        return ClimateSummary.decode(cached);
      } on Object {
        // повреждённый кэш — загрузим заново
      }
    }
    try {
      final climate = await power
          .fetchClimatology(latitude: record.latitude, longitude: record.longitude)
          .timeout(const Duration(seconds: 10));
      store.fields[phone]?[record.fieldId] = record.withClimate(climate.encode());
      await store.save();
      return climate;
    } on Object {
      return null;
    }
  }

  /// История по годам: из кэша или из NASA POWER (только в фоне — запрос
  /// долгий, вебхук ждать не может).
  Future<ClimateHistory?> _historyFor(String phone, FieldRecord record) async {
    final cached = _cachedHistory(record);
    if (cached != null) {
      return cached;
    }
    try {
      final history = await power
          .fetchHistory(latitude: record.latitude, longitude: record.longitude)
          .timeout(const Duration(seconds: 60));
      final current = store.fields[phone]?[record.fieldId] ?? record;
      store.fields[phone]?[record.fieldId] = current.copyWith(history: history.encode());
      await store.save();
      return history;
    } on Object {
      return null;
    }
  }

  static ClimateHistory? _cachedHistory(FieldRecord? record) {
    final cached = record?.history;
    if (cached == null) {
      return null;
    }
    try {
      return ClimateHistory.decode(cached);
    } on Object {
      return null;
    }
  }

  Future<List<String>> _answer(
    InboundSms sms,
    String text,
    Conversation conversation,
    DateTime now,
  ) async {
    final record = conversation.activeField == null
        ? null
        : store.fields[sms.from]?[conversation.activeField];
    final climate = record == null ? null : await _climateFor(sms.from, record);
    final history = _cachedHistory(record);
    final patterns = history == null || history.years.length < 6
        ? null
        : const ClimatePatternModel().train(history);

    final field = _fieldOf(record);
    final fieldCrop = _cropId(record?.crop);

    // 1. Наблюдение («листья желтеют, почва сухая») — через проверку данных
    //    и движок решений, с учётом фактов из прошлых сообщений диалога.
    final observation = _interpreter.interpret(text, date: now, fieldCropId: fieldCrop);
    if (observation.facts.isNotEmpty && !_hypothetical.hasMatch(text.toLowerCase())) {
      final previous = conversation.facts == null
          ? const <ObservedFact>[]
          : FieldObservation.decodeFacts(conversation.facts!);
      final merged = FieldObservation(
        text: text,
        date: now,
        cropId: observation.cropId,
        cropSource: observation.cropSource,
        facts: [
          for (final fact in previous)
            if (observation.of(fact.attribute).isEmpty) fact,
          ...observation.facts,
        ],
      );
      conversation.facts = merged.encodeFacts();

      final report = _validator.validate(
        merged,
        EvidenceContext(field: field, climate: climate),
      );
      final recommendation = _engine.decide(report);
      final next = recommendation.plan.isEmpty
          ? null
          : recommendation.plan.first.title;
      // Пометка «не диагноз» обязательна, поэтому идёт сразу за действием.
      final shortParts = [
        '${recommendation.action} (подсказка, не диагноз).',
        _firstSentence(recommendation.reason),
        if (next != null && next.toLowerCase() != recommendation.action.toLowerCase())
          'Шаг: ${_lowerFirst(next)}.',
      ];
      // Полный разбор — причины, варианты, план — следующими страницами.
      final plan = [
        for (final step in recommendation.plan)
          '${step.title}${step.dueInDays == 0 ? ' — сегодня' : ' — в течение ${step.dueInDays} дн.'}: ${_lowerFirst(step.result)}.',
      ];
      return _long(
        sms,
        conversation,
        [
          '${recommendation.action} (подсказка, не диагноз).',
          recommendation.reason,
          if (plan.isNotEmpty) 'План: ${plan.join(' ')}',
          if (recommendation.alternatives.isNotEmpty) 'Варианты: ${recommendation.alternatives.join(' ')}',
          recommendation.expectedOutcome,
        ],
        title: recommendation.action,
        shortParts: shortParts,
        sections: () => [
          ReportSection('Ваше сообщение', paragraphs: [text]),
          ReportSection('Почему', paragraphs: [recommendation.reason]),
          ReportSection('Варианты', items: recommendation.alternatives),
          ReportSection('Чего ожидать', paragraphs: [recommendation.expectedOutcome]),
          ReportSection('План', items: plan),
        ],
      );
    }

    // 2. Вопрос — классификатор намерений и расчёты советника.
    final result = record == null
        ? null
        : _advisor.advise(
            field: field,
            historyCropIds: fieldCrop == null ? const [] : [fieldCrop],
            climate: climate,
            patterns: patterns,
          );
    final answer = _assistant.answer(
      text,
      AssistantContext(
        field: record == null ? null : field,
        result: result,
        climate: climate,
        patterns: patterns,
      ),
    );

    if (record != null &&
        (answer.source == 'Нет истории погоды' || answer.source == 'Нет климатических данных')) {
      return [
        _fit([
        'AGROFY: данные NASA для поля ${record.fieldId} ещё загружаются.',
        'Повторите вопрос через 1–2 минуты.',
        ]),
      ];
    }

    if (record == null && answer.source == 'Нет данных участка') {
      return [
        _fit([
        'AGROFY: для ответа нужно поле.',
        'Отправьте: REG F1 широта,долгота КУЛЬТУРА, например REG F1 40.28,69.62 ХЛОПОК',
        ]),
      ];
    }

    if (record != null && result?.blocker != null && answer.text.contains(result!.blocker!)) {
      return [
        _fit([
        'AGROFY: у поля ${record.fieldId} не указана культура из справочника.',
        'Отправьте: REG ${record.fieldId} '
            '${record.latitude.toStringAsFixed(2)},${record.longitude.toStringAsFixed(2)} '
            'ХЛОПОК (или ПШЕНИЦА, МАШ, ЛЮЦЕРНА…).',
        ]),
      ];
    }

    final lines = _smsLines(answer.text);
    return _long(
      sms,
      conversation,
      lines,
      title: 'Ответ AGROFY',
      sections: () => [
        ReportSection('Вопрос', paragraphs: [text]),
        ReportSection('Ответ', paragraphs: lines),
      ],
      footer: 'Источник: ${answer.source}. Подсказка, не диагноз — '
          'решение принимает фермер вместе с агрономом.',
    );
  }

  /// Ответ ассистента в виде строк для SMS: без маркеров списка, с точкой
  /// в конце и без отсылок к экранам приложения.
  static List<String> _smsLines(String text) => text
      .split('\n')
      .map((l) => l.replaceFirst(RegExp(r'^[•\-\s]+'), '').trim())
      .where((l) => l.isNotEmpty)
      .map((l) => RegExp(r'[.!?:;…]$').hasMatch(l) ? l : '$l.')
      .map((l) => SmsText.sentences(l).where((s) => !s.contains('вкладк')).join(' '))
      .where((l) => l.isNotEmpty)
      .toList();

  /// INFO F1: все данные поля одним отчётом по ссылке и короткая сводка.
  Future<SmsOutcome> _info(
    InboundSms sms,
    SmsCommand command,
    Conversation conversation,
    DateTime now,
  ) async {
    final id = command.fieldId ?? conversation.activeField;
    if (id == null) {
      return SmsOutcome([
        _fit(['AGROFY: укажите поле: INFO F1.', 'Список полей: FIELDS.']),
      ]);
    }
    final record = store.fields[sms.from]?[id];
    if (record == null) {
      return SmsOutcome([
        _fit([
          'AGROFY: поле $id не найдено для этого номера.',
          'Зарегистрируйте: REG $id 40.28,69.62 ХЛОПОК',
        ]),
      ]);
    }
    conversation.activeField = id;

    final climate = await _climateFor(sms.from, record);
    final history = _cachedHistory(store.fields[sms.from]?[id]);
    if (climate == null || history == null) {
      return SmsOutcome(
        [
          _fit([
            'AGROFY: данные NASA для поля $id ещё загружаются.',
            'Повторите INFO $id через 1–2 минуты.',
          ]),
        ],
        () => _historyFor(sms.from, store.fields[sms.from]?[id] ?? record).then((_) {}),
      );
    }

    final patterns = history.years.length < 6 ? null : const ClimatePatternModel().train(history);
    final field = _fieldOf(record);
    final cropId = _cropId(record.crop);
    final result = _advisor.advise(
      field: field,
      historyCropIds: cropId == null ? const [] : [cropId],
      climate: climate,
      patterns: patterns,
    );
    final context = AssistantContext(
      field: field,
      result: result,
      climate: climate,
      patterns: patterns,
    );
    List<String> ask(String question) => _smsLines(_assistant.answer(question, context).text);

    final cropName = record.crop?.toLowerCase();
    final best = result.best;
    final sections = [
      ReportSection('Поле', items: [
        'ID: ${record.fieldId}',
        'Координаты: ${record.latitude.toStringAsFixed(4)}, ${record.longitude.toStringAsFixed(4)}',
        'Культура: ${cropName ?? 'не указана'}',
      ]),
      ReportSection('Климат участка (NASA POWER)', paragraphs: ask('Как меняется климат?')),
      if (result.blocker != null)
        ReportSection('Севооборот', paragraphs: [
          result.blocker!,
          'Укажите культуру: REG ${record.fieldId} '
              '${record.latitude.toStringAsFixed(2)},${record.longitude.toStringAsFixed(2)} ХЛОПОК',
        ])
      else ...[
        ReportSection('Рекомендация', paragraphs: ask('Какой севооборот лучше?')),
        ReportSection('Все варианты', items: [
          for (final s in result.strategies)
            '${s.title}: ${s.sequenceLabel} — ${s.total.round()} из 100, '
                'полив около ${s.avgIrrigationMm.round()} мм в год',
        ]),
        ReportSection('Сроки посева', paragraphs: ask('Когда сеять ${cropName ?? ''}?')),
        ReportSection('Засушливый год', paragraphs: ask('Что если будет засуха?')),
      ],
      ReportSection('Откуда данные', items: [
        'NASA POWER: климатология и помесячная история '
            '${history.years.first.year}–${history.years.last.year}, ячейка около 50 км',
        'Справочник культур AGROFY (общие значения, без проверки агрономом)',
        'Спутниковые данные поля: FIELD ${record.fieldId} NDVI 90D',
      ]),
    ];
    final summary = <String>[
      'AGROFY: поле ${record.fieldId}${cropName == null ? '' : ' ($cropName)'}.',
      if (best != null && !best.isCurrent)
        'Советую «${best.title}»: ${best.total.round()} из 100.'
      else if (best != null)
        'Текущий севооборот лучший: ${best.total.round()} из 100.'
      else
        'Культура не указана — севооборот не рассчитан.',
    ];

    // Текстом, по страницам: сначала главное.
    final parts = <String>[
      'AGROFY: поле ${record.fieldId}${cropName == null ? '' : ' ($cropName)'}, '
          '${record.latitude.toStringAsFixed(2)},${record.longitude.toStringAsFixed(2)}.',
      if (result.blocker != null)
        'Культура не указана — севооборот не рассчитан. Отправьте: REG ${record.fieldId} '
            '${record.latitude.toStringAsFixed(2)},${record.longitude.toStringAsFixed(2)} ХЛОПОК.'
      else ...[
        if (best != null && !best.isCurrent)
          'Совет: «${best.title}» — ${best.sequenceLabel}, ${best.total.round()} из 100.'
        else if (best != null)
          'Текущий севооборот лучший: ${best.total.round()} из 100.',
        'Варианты: ${result.strategies.map((s) => '${s.title} ${s.total.round()} (полив ${s.avgIrrigationMm.round()} мм)').join('; ')}.',
        ...ask('Когда сеять ${cropName ?? ''}?'),
        ...ask('Что если будет засуха?').skip(1),
      ],
      ...ask('Как меняется климат?'),
    ];

    return SmsOutcome(
      await _long(
        sms,
        conversation,
        parts,
        title: 'Поле ${record.fieldId}${cropName == null ? '' : ' · $cropName'}',
        sections: () => sections,
        shortParts: summary,
      ),
    );
  }

  static Field _fieldOf(FieldRecord? record) => Field(
        id: 1,
        name: record?.fieldId ?? 'SMS',
        location: '',
        area: 1,
        crop: _cropName(record?.crop),
        latitude: record?.latitude,
        longitude: record?.longitude,
      );

  /// «Что если будет засуха?» — сценарий, а не наблюдение с поля.
  static final RegExp _hypothetical = RegExp(
    r'(^|[^а-яё])(что|а)\s+если([^а-яё]|$)|если\s+(будет|случится|придёт|ударит)|в\s+случае',
  );

  /// Культура из справочника по названию: «хлопок», «Хлопчатник»,
  /// «томаты», «маш», таджикские названия.
  static String? _cropId(String? text) {
    if (text == null || text.trim().isEmpty) {
      return null;
    }
    return CropCatalog.fromFieldCrop(text)?.id ??
        ObservationInterpreter.mentionedCropIds(text).firstOrNull;
  }

  static String _cropName(String? text) {
    if (text == null || text.isEmpty) {
      return 'Другое';
    }
    final lower = text.toLowerCase();
    return '${lower[0].toUpperCase()}${lower.substring(1)}';
  }

  static String _firstSentence(String text) {
    final end = text.indexOf(RegExp(r'[.!?](\s|$)'));
    return end < 0 ? text : text.substring(0, end + 1);
  }

  static String _lowerFirst(String text) =>
      text.isEmpty ? text : '${text[0].toLowerCase()}${text.substring(1)}';
}
