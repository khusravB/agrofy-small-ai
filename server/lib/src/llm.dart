import 'dart:convert';

import 'package:http/http.dart' as http;

import 'config.dart';

/// Ответ языковой модели или причина, по которой его нет.
class LlmAnswer {
  final String? text;

  /// refusal, error, disabled — для ответа фермеру и журнала.
  final String? problem;
  final int inputTokens;
  final int outputTokens;

  const LlmAnswer.ok(this.text, {this.inputTokens = 0, this.outputTokens = 0})
      : problem = null;

  const LlmAnswer.failed(this.problem)
      : text = null,
        inputTokens = 0,
        outputTokens = 0;

  bool get ok => text != null;
}

/// Свободные вопросы фермера по команде /ВОПРОС: Gemini 3.1 Flash-Lite через
/// Interactions API (по умолчанию), GPT-5.6 Luna через OpenAI Responses API, Claude через Messages API или своя модель
/// (llama.cpp на сервере AGROFY). Claude — через Messages API (для Dart нет официального
/// SDK, поэтому прямой HTTP-запрос). Номер
/// телефона в запрос не попадает: только вопрос и данные поля.
class LlmService {
  static const String endpoint = 'https://api.anthropic.com/v1/messages';
  static const String apiVersion = '2026-10-21';
  static const String fallbackBeta = 'server-side-fallback-2026-07-01';

  /// Модели с серверным переключением при отказе (fallbacks: "default").
  /// У Claude Haiku 5.5 (модель по умолчанию) его нет: отказ приходит как
  /// stop_reason "refusal" и фермер получает короткий ответ.
  static const Set<String> fallbackModels = {
    'claude-opus-5-5',
    'claude-opus-5',
    'claude-sonnet-5-5',
    'claude-fable-5-2',
    'claude-fable-5-1',
  };

  bool get _fallbacks => fallbackModels.contains(config.llmModel);

  /// Длина ответа для SMS: до ~4 SMS кириллицей.
  static const int maxAnswerChars = 700;

  static const String systemPrompt = '''
Ты — агрономический помощник сервиса AGROFY для фермеров Согдийской области Таджикистана. Тебе пишут по SMS, часто без интернета.

Отвечай на языке вопроса (русский или таджикский), простыми словами, обычным текстом без markdown, списков со звёздочками и эмодзи. Не длиннее $maxAnswerChars символов: сначала прямой ответ, потом одна-две причины или шага.

Опирайся на данные поля из сообщения (климат NASA POWER, рекомендация советника). Не выдумывай цифры, которых там нет; если данных не хватает — так и скажи и предложи, что измерить или у кого уточнить.

Ты не ставишь диагнозы и не назначаешь препараты и дозы: при болезнях, вредителях и химической защите советуй показать растения агроному или в службу защиты растений. Решение всегда за фермером.''';

  final ServerConfig config;
  final http.Client client;

  LlmService(this.config, {http.Client? client}) : client = client ?? http.Client();

  static bool _has(String? key) => key != null && key.isNotEmpty;

  bool get enabled => switch (config.llmProvider) {
        LlmProvider.local => true,
        LlmProvider.gemini => _has(config.geminiApiKey),
        LlmProvider.openai => _has(config.openaiApiKey),
        LlmProvider.anthropic => _has(config.anthropicApiKey),
      };

  /// Подпись модели в журнале.
  String get modelName => switch (config.llmProvider) {
        LlmProvider.local => 'local',
        LlmProvider.gemini => config.geminiModel,
        LlmProvider.openai => config.openaiModel,
        LlmProvider.anthropic => config.llmModel,
      };

  static const String geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/interactions';

  /// Схема ответа Interactions API по ревизии мая 2026 года.
  static const String geminiRevision = '2026-05-20';

  /// Gemini Interactions API. store: false — запрос не сохраняется для
  /// последующего чтения. max_output_tokens включает размышления модели.
  Map<String, dynamic> geminiBody(String question, String context) => {
        'model': config.geminiModel,
        'system_instruction': systemPrompt,
        'input': '$context\n\nВопрос фермера: $question',
        'generation_config': {
          'max_output_tokens': 4000,
          'thinking_level': config.geminiThinking,
        },
        'store': false,
      };

  Future<LlmAnswer> _askGemini(String question, String context) async {
    http.Response response;
    try {
      response = await client
          .post(
            Uri.parse(geminiEndpoint),
            headers: {
              'content-type': 'application/json',
              'x-goog-api-key': config.geminiApiKey!,
              'api-revision': geminiRevision,
            },
            body: jsonEncode(geminiBody(question, context)),
          )
          .timeout(const Duration(seconds: 120));
    } on Object catch (e) {
      return LlmAnswer.failed('gemini network: $e');
    }
    if (response.statusCode != 200) {
      return LlmAnswer.failed('gemini http ${response.statusCode}');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final texts = <String>[
      for (final step in json['steps'] as List? ?? const [])
        if (step is Map && step['type'] == 'model_output')
          for (final part in step['content'] as List? ?? const [])
            if (part is Map && part['type'] == 'text') '${part['text']}',
    ];
    final text = texts.join('\n').trim();
    if (text.isEmpty) {
      // Без текста: блокировка фильтром безопасности или сбой.
      return LlmAnswer.failed(json['status'] == 'failed' ? 'refusal' : 'empty (${json['status']})');
    }
    final usage = json['usage'] as Map<String, dynamic>? ?? const {};
    int count(String key) => (usage[key] as num?)?.toInt() ?? 0;
    return LlmAnswer.ok(
      text,
      inputTokens: count('total_input_tokens'),
      // Размышления оплачиваются как выходные токены.
      outputTokens: count('total_output_tokens') + count('total_thought_tokens'),
    );
  }

  static const String openaiEndpoint = 'https://api.openai.com/v1/responses';

  /// OpenAI Responses API. store: false — вопросы фермеров не хранятся у
  /// OpenAI. max_output_tokens включает токены рассуждения, поэтому с запасом.
  Map<String, dynamic> openaiBody(String question, String context) => {
        'model': config.openaiModel,
        'instructions': systemPrompt,
        'input': '$context\n\nВопрос фермера: $question',
        'reasoning': {'effort': config.openaiEffort},
        'max_output_tokens': 4000,
        'store': false,
      };

  Future<LlmAnswer> _askOpenAi(String question, String context) async {
    http.Response response;
    try {
      response = await client
          .post(
            Uri.parse(openaiEndpoint),
            headers: {
              'content-type': 'application/json',
              'authorization': 'Bearer ${config.openaiApiKey}',
            },
            body: jsonEncode(openaiBody(question, context)),
          )
          .timeout(const Duration(seconds: 120));
    } on Object catch (e) {
      return LlmAnswer.failed('openai network: $e');
    }
    if (response.statusCode != 200) {
      return LlmAnswer.failed('openai http ${response.statusCode}');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final texts = <String>[];
    var refused = false;
    for (final item in json['output'] as List? ?? const []) {
      if (item is! Map || item['type'] != 'message') {
        continue;
      }
      for (final part in item['content'] as List? ?? const []) {
        if (part is Map && part['type'] == 'output_text') {
          texts.add('${part['text']}');
        } else if (part is Map && part['type'] == 'refusal') {
          refused = true;
        }
      }
    }
    final text = texts.join('\n').trim();
    if (text.isEmpty) {
      return LlmAnswer.failed(refused ? 'refusal' : 'empty (${json['status']})');
    }
    final usage = json['usage'] as Map<String, dynamic>? ?? const {};
    return LlmAnswer.ok(
      text,
      inputTokens: (usage['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (usage['output_tokens'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> requestBody(String question, String context) => {
        'model': config.llmModel,
        'max_tokens': 16000,
        'output_config': {'effort': config.llmEffort},
        // При отказе классификатора безопасности запрос повторяется на
        // подходящей модели автоматически.
        if (_fallbacks) 'fallbacks': 'default',
        'system': systemPrompt,
        'messages': [
          {
            'role': 'user',
            'content': '$context\n\nВопрос фермера: $question',
          },
        ],
      };

  /// Запрос к своей модели: llama-server, OpenAI-совместимый
  /// /v1/chat/completions. Маленькой модели — короче инструкция и ответ.
  Map<String, dynamic> localBody(String question, String context) => {
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': '$context\n\nВопрос фермера: $question'},
        ],
        'max_tokens': 300,
        'temperature': 0.3,
        // Маленькие модели склонны повторяться.
        'repeat_penalty': 1.15,
        'stream': false,
      };

  Future<LlmAnswer> _askLocal(String question, String context) async {
    http.Response response;
    try {
      response = await client
          .post(
            Uri.parse('${config.llmUrl}/v1/chat/completions'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(localBody(question, context)),
          )
          // На 2 vCPU модель 1.5B отвечает до минуты.
          .timeout(const Duration(seconds: 180));
    } on Object catch (e) {
      return LlmAnswer.failed('local network: $e');
    }
    if (response.statusCode != 200) {
      return LlmAnswer.failed('local http ${response.statusCode}');
    }
    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final choices = json['choices'] as List? ?? const [];
    final text = choices.isEmpty
        ? ''
        : '${(choices.first as Map)['message']?['content'] ?? ''}'.trim();
    if (text.isEmpty) {
      return const LlmAnswer.failed('empty');
    }
    final usage = json['usage'] as Map<String, dynamic>? ?? const {};
    return LlmAnswer.ok(
      text,
      inputTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
    );
  }

  Future<LlmAnswer> ask(String question, String context) async {
    if (!enabled) {
      return const LlmAnswer.failed('disabled');
    }
    if (config.llmProvider == LlmProvider.local) {
      return _askLocal(question, context);
    }
    if (config.llmProvider == LlmProvider.openai) {
      return _askOpenAi(question, context);
    }
    if (config.llmProvider == LlmProvider.gemini) {
      return _askGemini(question, context);
    }
    http.Response response;
    try {
      response = await client
          .post(
            Uri.parse(endpoint),
            headers: {
              'content-type': 'application/json',
              'x-api-key': config.anthropicApiKey!,
              'anthropic-version': apiVersion,
              if (_fallbacks) 'anthropic-beta': fallbackBeta,
            },
            body: jsonEncode(requestBody(question, context)),
          )
          .timeout(const Duration(seconds: 120));
    } on Object catch (e) {
      return LlmAnswer.failed('network: $e');
    }
    if (response.statusCode != 200) {
      return LlmAnswer.failed('http ${response.statusCode}');
    }

    final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (json['stop_reason'] == 'refusal') {
      return const LlmAnswer.failed('refusal');
    }
    final text = [
      for (final block in json['content'] as List? ?? const [])
        if (block is Map && block['type'] == 'text') '${block['text']}',
    ].join('\n').trim();
    if (text.isEmpty) {
      return const LlmAnswer.failed('empty');
    }
    final usage = json['usage'] as Map<String, dynamic>? ?? const {};
    return LlmAnswer.ok(
      text,
      inputTokens: (usage['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (usage['output_tokens'] as num?)?.toInt() ?? 0,
    );
  }
}
