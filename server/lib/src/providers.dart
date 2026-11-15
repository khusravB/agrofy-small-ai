import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

import 'config.dart';

/// Входящее SMS после проверки подлинности.
class InboundSms {
  final String from;
  final String text;

  /// Идентификатор сообщения у провайдера — для защиты от повторов.
  final String messageId;

  const InboundSms({required this.from, required this.text, required this.messageId});
}

class WebhookRejected implements Exception {
  final int status;
  final String reason;

  const WebhookRejected(this.status, this.reason);

  @override
  String toString() => 'WebhookRejected($status): $reason';
}

/// SMS-провайдер: проверяет и разбирает вебхук, отвечает на него
/// и отправляет отдельные сообщения (для отложенных ответов).
abstract class SmsProvider {
  Future<InboundSms> parse(Request request, String body);

  /// Ответ на вебхук с сообщениями, которые нужно сразу отправить.
  Response respond(List<String> replies);

  Future<void> send(String to, String text);

  /// Сравнение без утечки времени.
  static bool safeEquals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String normalizePhone(String raw) =>
      raw.replaceAll(RegExp(r'[^\d+]'), '');
}

/// Twilio: подпись X-Twilio-Signature — HMAC-SHA1 от адреса вебхука
/// и отсортированных параметров формы, ключ — Auth Token.
class TwilioProvider extends SmsProvider {
  final ServerConfig config;
  final http.Client client;

  TwilioProvider(this.config, {http.Client? client})
      : client = client ?? http.Client();

  static String signature(String authToken, String url, Map<String, String> params) {
    final keys = params.keys.toList()..sort();
    final data = StringBuffer(url);
    for (final key in keys) {
      data
        ..write(key)
        ..write(params[key]);
    }
    final mac = Hmac(sha1, utf8.encode(authToken)).convert(utf8.encode(data.toString()));
    return base64.encode(mac.bytes);
  }

  @override
  Future<InboundSms> parse(Request request, String body) async {
    final params = Uri.splitQueryString(body);
    final url = '${config.publicUrl}${request.requestedUri.path}'
        '${request.requestedUri.hasQuery ? '?${request.requestedUri.query}' : ''}';
    final expected = signature(config.twilioAuthToken!, url, params);
    final given = request.headers['x-twilio-signature'] ?? '';
    if (!SmsProvider.safeEquals(expected, given)) {
      throw const WebhookRejected(403, 'bad signature');
    }

    final from = params['From'];
    final sid = params['MessageSid'] ?? params['SmsSid'];
    if (from == null || sid == null) {
      throw const WebhookRejected(400, 'missing fields');
    }
    return InboundSms(
      from: SmsProvider.normalizePhone(from),
      text: params['Body'] ?? '',
      messageId: 'twilio:$sid',
    );
  }

  static String _xml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  @override
  Response respond(List<String> replies) {
    final messages = replies.map((r) => '<Message>${_xml(r)}</Message>').join();
    return Response.ok(
      '<?xml version="1.0" encoding="UTF-8"?><Response>$messages</Response>',
      headers: {'content-type': 'text/xml; charset=utf-8'},
    );
  }

  @override
  Future<void> send(String to, String text) async {
    final sid = config.twilioAccountSid!;
    final response = await client.post(
      Uri.https('api.twilio.com', '/2010-04-01/Accounts/$sid/Messages.json'),
      headers: {
        'authorization':
            'Basic ${base64.encode(utf8.encode('$sid:${config.twilioAuthToken}'))}',
      },
      body: {'To': to, 'From': config.twilioFrom!, 'Body': text},
    );
    if (response.statusCode >= 300) {
      throw Exception('Twilio: ${response.statusCode}');
    }
  }
}

/// Универсальный шлюз (Android-телефон с SIM-картой, другой провайдер или
/// собственный ретранслятор). JSON {"from","text","id"}; подпись
/// `X-Agrofy-Signature` = hex(HMAC-SHA256(секрет, `timestamp.тело`)),
/// X-Agrofy-Timestamp — секунды Unix, допустимое расхождение 5 минут.
class GenericProvider extends SmsProvider {
  static const Duration maxSkew = Duration(minutes: 5);

  final ServerConfig config;
  final http.Client client;
  final DateTime Function() clock;

  GenericProvider(this.config, {http.Client? client, DateTime Function()? clock})
      : client = client ?? http.Client(),
        clock = clock ?? DateTime.now;

  static String signature(String secret, String timestamp, String body) =>
      Hmac(sha256, utf8.encode(secret))
          .convert(utf8.encode('$timestamp.$body'))
          .toString();

  @override
  Future<InboundSms> parse(Request request, String body) async {
    final timestamp = request.headers['x-agrofy-timestamp'] ?? '';
    final given = request.headers['x-agrofy-signature'] ?? '';
    final seconds = int.tryParse(timestamp);
    if (seconds == null) {
      throw const WebhookRejected(401, 'missing timestamp');
    }
    final sent = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    if (clock().difference(sent).abs() > maxSkew) {
      throw const WebhookRejected(401, 'stale timestamp');
    }
    if (!SmsProvider.safeEquals(signature(config.webhookSecret!, timestamp, body), given)) {
      throw const WebhookRejected(403, 'bad signature');
    }

    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw const WebhookRejected(400, 'bad json');
    }
    if (json is! Map || json['from'] is! String || json['id'] is! String) {
      throw const WebhookRejected(400, 'missing fields');
    }
    return InboundSms(
      from: SmsProvider.normalizePhone(json['from'] as String),
      text: '${json['text'] ?? ''}',
      messageId: 'generic:${json['id']}',
    );
  }

  @override
  Response respond(List<String> replies) => Response.ok(
        jsonEncode({'replies': replies}),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  /// Отправка через шлюз или, если адрес не задан, в локальный файл
  /// outbox.jsonl (режим разработки).
  @override
  Future<void> send(String to, String text) async {
    final body = jsonEncode({'to': to, 'text': text});
    final url = config.outboundUrl;
    if (url == null) {
      await File('${config.dataDir}/outbox.jsonl').writeAsString(
        '${jsonEncode({'at': clock().toIso8601String(), 'to': to, 'text': text})}\n',
        mode: FileMode.append,
      );
      return;
    }
    final timestamp = '${clock().millisecondsSinceEpoch ~/ 1000}';
    final response = await client.post(
      Uri.parse(url),
      headers: {
        'content-type': 'application/json',
        'x-agrofy-timestamp': timestamp,
        'x-agrofy-signature': signature(config.webhookSecret!, timestamp, body),
      },
      body: body,
    );
    if (response.statusCode >= 300) {
      throw Exception('Шлюз: ${response.statusCode}');
    }
  }
}
