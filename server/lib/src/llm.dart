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

/// Свободные вопросы фермера по команде /ВОПРОС: своя модель (llama.cpp на
/// сервере AGROFY) или Claude через Messages API (для Dart нет официального
/// SDK, поэтому прямой HTTP-запрос). Номер
/// телефона в запрос не попадает: только вопрос и данные поля.
class LlmService {
  static const String endpoint = 'https://api.anthropic.com/v1/messages';
  static const String apiVersion = '2026-10-21';
  static const String fallbackBeta = 'server-side-fallback-2026-07-01';

  /// Модели с серверным переключением при отказе (fallbacks: "default").
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

  bool get enabled => config.llmProvider == LlmProvider.local ||
      (config.anthropicApiKey != null && config.anthropicApiKey!.isNotEmpty);

  /// Подпись модели в журнале.
  String get modelName =>
      config.llmProvider == LlmProvider.local ? 'local' : config.llmModel;

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
