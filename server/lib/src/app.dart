import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'config.dart';
import 'providers.dart';
import 'sms_service.dart';
import 'store.dart';

/// SMS Webhook API и выдача пакетов по защищённой ссылке.
class SmsServerApp {
  static const int maxBodyBytes = 16 * 1024;

  final ServerConfig config;
  final Store store;
  final SmsProvider provider;
  final SmsService service;
  final DateTime Function() clock;

  /// Фоновые задачи — чтобы тесты могли дождаться их.
  final List<Future<void>> pending = [];

  SmsServerApp({
    required this.config,
    required this.store,
    required this.provider,
    required this.service,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  Handler get handler {
    final router = Router()
      ..get('/health', (Request _) => Response.ok('ok'))
      ..post(provider.inboundPath, _inbound)
      // Статусы доставки (Vonage Status URL): принимаем без обработки, чтобы
      // провайдер не повторял их.
      ..post('${provider.inboundPath}/status', (Request _) => Response(204))
      ..get('/p/<token>', _download);

    return const Pipeline().addMiddleware(_errors).addHandler(router.call);
  }

  Middleware get _errors => (inner) => (request) async {
        try {
          return await inner(request);
        } on WebhookRejected catch (e) {
          stderr.writeln('Отклонён вебхук: ${e.reason}');
          return Response(e.status, body: e.reason);
        } on Object catch (e, stack) {
          stderr.writeln('Ошибка: $e\n$stack');
          return Response.internalServerError(body: 'error');
        }
      };

  Future<Response> _inbound(Request request) async {
    final length = request.contentLength;
    if (length != null && length > maxBodyBytes) {
      return Response(413, body: 'too large');
    }
    final body = await request.readAsString();
    if (body.length > maxBodyBytes) {
      return Response(413, body: 'too large');
    }

    final sms = await provider.parse(request, body);
    final outcome = await service.handle(sms);

    final background = outcome.background;
    if (background != null) {
      _track(background());
    }

    if (provider.repliesInWebhook) {
      return provider.respond(outcome.replies);
    }
    // Провайдер ждёт быстрый 200; ответы — отдельными запросами, по порядку.
    if (outcome.replies.isNotEmpty) {
      _track(() async {
        for (final reply in outcome.replies) {
          await provider.send(sms.from, reply);
        }
      }());
    }
    return provider.respond(const []);
  }

  void _track(Future<void> work) {
    final task = work.catchError((Object e) {
      stderr.writeln('Фоновая задача не выполнена: $e');
    });
    pending.add(task);
    unawaited(task.whenComplete(() => pending.remove(task)));
  }

  Future<Response> _download(Request request, String token) async {
    final record = store.packages[token];
    if (record == null || clock().isAfter(record.expiresAt)) {
      return Response.notFound('Ссылка недействительна или срок её действия истёк.');
    }
    final file = File('${store.packagesDir.path}/$token.json');
    if (!await file.exists()) {
      return Response.notFound('Файл удалён.');
    }
    return Response.ok(
      file.openRead(),
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'content-length': '${record.bytes}',
        'content-disposition':
            'attachment; filename="agrofy-${record.requestId}.json"',
        'cache-control': 'no-store',
        'x-agrofy-expires': record.expiresAt.toIso8601String(),
      },
    );
  }
}
