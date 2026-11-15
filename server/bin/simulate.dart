import 'dart:convert';
import 'dart:io';

import 'package:agrofy_sms_server/agrofy_sms_server.dart';
import 'package:http/http.dart' as http;

/// Имитирует входящее SMS для универсального шлюза — для локальной проверки.
///
///   dart run bin/simulate.dart +992900000001 "REG F1 40.28,69.62 ХЛОПОК"
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('dart run bin/simulate.dart <номер> "<текст SMS>"');
    exitCode = 64;
    return;
  }
  final secret = Platform.environment['AGROFY_WEBHOOK_SECRET'];
  final url = Platform.environment['AGROFY_SIMULATE_URL'] ?? 'http://localhost:8080/sms/inbound';
  if (secret == null) {
    stderr.writeln('Нужен AGROFY_WEBHOOK_SECRET.');
    exitCode = 64;
    return;
  }

  final body = jsonEncode({
    'from': args[0],
    'text': args.sublist(1).join(' '),
    'id': 'sim-${DateTime.now().microsecondsSinceEpoch}',
  });
  final timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
  final response = await http.post(
    Uri.parse(url),
    headers: {
      'content-type': 'application/json',
      'x-agrofy-timestamp': timestamp,
      'x-agrofy-signature': GenericProvider.signature(secret, timestamp, body),
    },
    body: body,
  );
  stdout.writeln('${response.statusCode}');
  final replies = (jsonDecode(response.body) as Map)['replies'] as List? ?? [];
  for (final reply in replies) {
    stdout.writeln('← $reply');
  }
}
