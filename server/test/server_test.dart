import 'dart:convert';
import 'dart:io';

import 'package:agrofy_core/models/climate_history.dart';
import 'package:agrofy_core/models/climate_summary.dart';
import 'package:crypto/crypto.dart';
import 'package:agrofy_core/remote/data_package.dart';
import 'package:agrofy_core/remote/sms_command.dart';
import 'package:agrofy_core/remote/sms_text.dart';
import 'package:agrofy_core/services/modis_service.dart';
import 'package:agrofy_core/services/nasa_power_service.dart';
import 'package:agrofy_sms_server/agrofy_sms_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

const secret = 'test-secret-0123456789';

/// Реальная климатология NASA POWER для Худжанда из фикстур приложения.
ClimateSummary khujand() => ClimateSummary.decode(
      File('../test/fixtures/khujand_climate.json').readAsStringSync(),
    );

class FakeModis extends ModisService {
  final List<NdviObservation> points;
  FakeModis(this.points);

  @override
  Future<List<NdviObservation>> fetchNdvi({
    required double latitude,
    required double longitude,
    required DateTime start,
    required DateTime end,
  }) async =>
      points.where((p) => !p.date.isBefore(start) && !p.date.isAfter(end)).toList();
}

class FakePower extends NasaPowerService {
  int climatologyCalls = 0;

  @override
  Future<ClimateSummary> fetchClimatology({
    required double latitude,
    required double longitude,
  }) async {
    climatologyCalls++;
    return khujand();
  }

  int historyCalls = 0;

  @override
  Future<ClimateHistory> fetchHistory({
    required double latitude,
    required double longitude,
  }) async {
    historyCalls++;
    return ClimateHistory.fromPowerJson(
      jsonDecode(File('../test/fixtures/khujand_history_power.json').readAsStringSync())
          as Map<String, dynamic>,
      latitude: latitude,
      longitude: longitude,
      fetchedAt: DateTime(2026, 11, 15),
    );
  }

  @override
  Future<Map<String, Map<DateTime, double>>> fetchDailySeries({
    required double latitude,
    required double longitude,
    required DateTime start,
    required DateTime end,
    List<String> parameters = const ['T2M', 'T2M_MIN', 'PRECTOTCORR'],
  }) async {
    final days = <DateTime>[
      for (var d = start; d.isBefore(end.subtract(const Duration(days: 2))); d = d.add(const Duration(days: 1)))
        d,
    ];
    return {
      'T2M': {for (final d in days) d: 20.0},
      'T2M_MIN': {for (final d in days) d: 12.0},
      'PRECTOTCORR': {for (final d in days) d: 0.4},
    };
  }
}

const vonageSecret = 'vonage-signature-secret-0123456789';

String sha256Hex(String body) => sha256.convert(utf8.encode(body)).toString();

class Harness {
  final Directory dir;
  final DateTime now;
  final SmsServerApp app;
  final Store store;
  final FakePower power;

  /// Запросы к API провайдера (Vonage).
  final List<http.Request> apiCalls;

  Harness._(this.dir, this.now, this.app, this.store, this.power, this.apiCalls);

  static Future<Harness> create({
    List<NdviObservation>? ndvi,
    int maxPerHour = 20,
    ProviderKind provider = ProviderKind.generic,
    bool reportLinks = false,
    int pagesAtOnce = 8,
  }) async {
    final dir = await Directory.systemTemp.createTemp('agrofy_sms');
    final now = DateTime(2026, 11, 15, 12);
    final config = ServerConfig(
      dataDir: dir.path,
      publicUrl: 'https://sms.agrofy.test',
      provider: provider,
      webhookSecret: secret,
      twilioAccountSid: 'AC123',
      twilioAuthToken: 'twilio-token',
      twilioFrom: '+15550001111',
      vonageApiKey: 'vkey',
      vonageApiSecret: 'vsecret',
      vonageSignatureSecret: vonageSecret,
      vonageFrom: '15550002222',
      maxPerHour: maxPerHour,
      reportLinks: reportLinks,
      pagesAtOnce: pagesAtOnce,
    );
    final store = await Store.open(dir.path);
    final power = FakePower();
    DateTime clock() => now;
    final apiCalls = <http.Request>[];
    final client = MockClient((request) async {
      apiCalls.add(request);
      return http.Response('{"message_uuid":"out"}', 202);
    });
    final SmsProvider smsProvider = switch (provider) {
      ProviderKind.twilio => TwilioProvider(config),
      ProviderKind.vonage => VonageProvider(config, client: client, clock: clock),
      ProviderKind.generic => GenericProvider(config, clock: clock),
    };
    final app = SmsServerApp(
      config: config,
      store: store,
      provider: smsProvider,
      clock: clock,
      service: SmsService(
        config: config,
        store: store,
        provider: smsProvider,
        power: power,
        clock: clock,
        data: DataPackageService(
          config,
          store,
          modis: FakeModis(ndvi ??
              [
                NdviObservation(date: DateTime.utc(2026, 9, 14), ndvi: 0.18, reliability: 'good'),
                NdviObservation(date: DateTime.utc(2026, 9, 30), ndvi: 0.21, reliability: 'good'),
                NdviObservation(date: DateTime.utc(2026, 10, 16), ndvi: 0.13, reliability: 'cloudy'),
              ]),
          power: power,
          clock: clock,
        ),
      ),
    );
    return Harness._(dir, now, app, store, power, apiCalls);
  }

  int _id = 0;

  Future<Response> raw(String body, {String? signature, int? timestamp}) async {
    final ts = '${timestamp ?? now.millisecondsSinceEpoch ~/ 1000}';
    return await app.handler(Request(
      'POST',
      Uri.parse('https://sms.agrofy.test/sms/inbound'),
      body: body,
      headers: {
        'content-type': 'application/json',
        'x-agrofy-timestamp': ts,
        'x-agrofy-signature': signature ?? GenericProvider.signature(secret, ts, body),
      },
    ));
  }

  Future<List<String>> sms(String text, {String from = '+992900000001', String? id}) async {
    final response = await raw(jsonEncode({'from': from, 'text': text, 'id': id ?? 'm${_id++}'}));
    expect(response.statusCode, 200);
    final json = jsonDecode(await response.readAsString()) as Map;
    return [for (final r in json['replies'] as List) '$r'];
  }

  Future<Response> vonage(
    String text, {
    String id = 'uuid-1',
    String? jwtSecret,
    int? iatOffsetSeconds,
    String? payloadHash,
    String apiKey = 'vkey',
  }) async {
    final body = jsonEncode({
      'channel': 'sms',
      'message_uuid': id,
      'to': '15550002222',
      'from': '992900000001',
      'text': text,
      'timestamp': '2026-11-15T12:00:00Z',
    });
    final jwt = VonageProvider.sign(jwtSecret ?? vonageSecret, {
      'iat': now.millisecondsSinceEpoch ~/ 1000 + (iatOffsetSeconds ?? 0),
      'jti': 'j-$id',
      'iss': 'Vonage',
      'api_key': apiKey,
      'payload_hash': payloadHash ?? sha256Hex(body),
    });
    return await app.handler(Request(
      'POST',
      Uri.parse('https://sms.agrofy.test/sms/vonage'),
      body: body,
      headers: {'content-type': 'application/json', 'authorization': 'Bearer $jwt'},
    ));
  }

  Future<void> settle() async {
    while (app.pending.isNotEmpty) {
      await Future.wait(List.of(app.pending));
    }
  }

  List<Map<String, dynamic>> outbox() {
    final file = File('${dir.path}/outbox.jsonl');
    if (!file.existsSync()) {
      return [];
    }
    return [
      for (final line in file.readAsLinesSync())
        if (line.isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
    ];
  }
}

void main() {
  group('Отчёты и команды INFO, FIELDS', () {
    test('страницы: целые предложения, подпись, лимит страниц', () {
      final parts = [for (var i = 1; i <= 30; i++) 'Предложение номер $i про поле и воду.'];
      final pages = SmsText.paginate(parts, maxSegments: 2, maxPages: 4);
      expect(pages, hasLength(4));
      expect(pages.first, endsWith(' (1/4)'));
      expect(pages.last, endsWith('… (4/4)'));
      for (final page in pages) {
        // С подсказкой «Дальше: ЕЩЁ» часть тоже помещается.
        expect(SmsText.segments('$page ${SmsText.moreHint}'), lessThanOrEqualTo(2));
      }
      expect(SmsText.paginate(['Коротко.']), ['Коротко.']);
    });

    test('без интернета: INFO приходит всеми частями сразу', () async {
      final h = await Harness.create();
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.settle();
      final parts = await h.sms('INFO F1');
      expect(parts.length, greaterThan(1));
      expect(parts.first, startsWith('AGROFY: поле F1 (хлопок)'));
      expect(parts.first, endsWith('(1/${parts.length})'));
      expect(parts.last, endsWith('(${parts.length}/${parts.length})'));
      final all = parts.join(' ');
      expect(all, isNot(contains('http')));
      expect(all, isNot(contains('ЕЩЁ')));
      expect(all, contains('Варианты:'));
      expect(all, contains('посев'));
      for (final part in parts) {
        expect(SmsText.segments(part), lessThanOrEqualTo(3));
      }
      expect((await h.sms('ЕЩЁ')).single, contains('продолжения нет'));
    });

    test('лимит частей за раз: остальные по ЕЩЁ, все сразу по ВСЁ', () async {
      final h = await Harness.create(pagesAtOnce: 2);
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.settle();
      final first = await h.sms('INFO F1');
      expect(first, hasLength(2));
      expect(first.last, endsWith('Дальше: ЕЩЁ'));
      final total = int.parse(RegExp(r'\(1/(\d+)\)$').firstMatch(first.first)!.group(1)!);
      expect(total, greaterThan(4));
      final next = await h.sms('еще');
      expect(next, hasLength(2));
      expect(next.first, endsWith('(3/$total)'));
      final rest = await h.sms('ВСЁ');
      expect(rest, hasLength(total - 4));
      expect(rest.last, endsWith('($total/$total)'));
      expect(rest.last, isNot(contains('ЕЩЁ')));
      expect((await h.sms('ЕЩЁ')).single, contains('продолжения нет'));
    });

    test('новый вопрос сбрасывает недочитанные части', () async {
      final h = await Harness.create(pagesAtOnce: 1);
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.settle();
      await h.sms('INFO F1');
      await h.sms('Когда сеять хлопок?');
      expect((await h.sms('ЕЩЁ')).single, contains('продолжения нет'));
    });

    test('без интернета: наблюдение — действие первым, разбор следом', () async {
      final h = await Harness.create();
      final parts = await h.sms('листья желтеют, почва сухая');
      expect(parts.length, greaterThan(1));
      expect(parts.first, contains('не диагноз'));
      expect(parts.join(' '), contains('План:'));
      expect(parts.join(' '), contains('Варианты:'));
    });

    test('ссылка всегда в конце и помещается в лимит', () {
      const suffix = ' Полностью: https://sms.agrofy.test/r/AAAAAAAAAAAAAAAA';
      final text = SmsText.fit(['Первое предложение. ' * 20], maxSegments: 3, suffix: suffix);
      expect(text, endsWith(suffix));
      expect(SmsText.segments(text), lessThanOrEqualTo(3));
      expect(text, startsWith('Первое предложение.'));
    });

    Future<String> page(Harness h, String reply) async {
      final url = RegExp(r'https://sms\.agrofy\.test(/r/[A-Za-z0-9_-]+)').firstMatch(reply)!;
      final response = await h.app.handler(Request('GET', Uri.parse('https://sms.agrofy.test${url.group(1)}')));
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], startsWith('text/html'));
      return response.readAsString();
    }

    test('INFO F1 со ссылками: сводка в SMS и полный отчёт по ссылке', () async {
      final h = await Harness.create(reportLinks: true);
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.settle();
      final reply = (await h.sms('INFO F1')).single;
      expect(reply, startsWith('AGROFY: поле F1 (хлопок).'));
      expect(reply, contains('Полностью: https://sms.agrofy.test/r/'));
      expect(SmsText.segments(reply), lessThanOrEqualTo(3));
      final html = await page(h, reply);
      for (final heading in ['Поле F1', 'Климат участка', 'Рекомендация', 'Все варианты', 'Засушливый год']) {
        expect(html, contains(heading));
      }
      expect(html, isNot(contains('вкладк')));
    });

    test('INFO чужого поля и без истории', () async {
      final h = await Harness.create();
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      final early = (await h.sms('INFO')).single;
      expect(early, contains('загружаются'));
      await h.settle();
      final other = (await h.sms('INFO F1', from: '+992900000002')).single;
      expect(other, contains('не найдено'));
    });

    test('отчёт экранирует текст из SMS', () async {
      final h = await Harness.create(reportLinks: true);
      await h.sms('REG F1 40.28,69.62 <script>x</script>');
      await h.settle();
      final html = await page(h, (await h.sms('INFO F1')).single);
      expect(html, isNot(contains('<script>')));
      expect(html, contains('&lt;script&gt;'));
    });

    test('со ссылками: длинный ответ — начало и ссылка; ссылка истекает', () async {
      final h = await Harness.create(reportLinks: true);
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.settle();
      final reply = (await h.sms('Как меняется климат?')).single;
      expect(reply, contains('Полностью: '));
      final html = await page(h, reply);
      expect(html, contains('Как меняется климат?'));

      final record = h.store.reports.values.last;
      h.store.reports[record.token] = ReportRecord(
        token: record.token,
        ownerHash: record.ownerHash,
        title: record.title,
        createdAt: record.createdAt,
        expiresAt: h.now.subtract(const Duration(seconds: 1)),
      );
      final expired = await h.app.handler(
        Request('GET', Uri.parse('https://sms.agrofy.test/r/${record.token}')),
      );
      expect(expired.statusCode, 404);
    });

    test('со ссылками: наблюдение — короткий ответ и полный разбор по ссылке', () async {
      final h = await Harness.create(reportLinks: true);
      final reply = (await h.sms('листья желтеют, почва сухая')).single;
      expect(reply, contains('не диагноз'));
      final html = await page(h, reply);
      expect(html, contains('Варианты'));
      expect(html, contains('План'));
    });

    test('FIELDS перечисляет поля номера', () async {
      final h = await Harness.create();
      expect((await h.sms('FIELDS')).single, contains('нет полей'));
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.sms('REG F2 40.10,69.30 МАШ');
      final reply = (await h.sms('ПОЛЯ')).single;
      expect(reply, contains('F1 (хлопок'));
      expect(reply, contains('F2 (маш'));
      expect(reply, contains('Текущее: F2'));
    });
  });

  group('Vonage', () {
    test('подписанный вебхук: 204, ответ уходит через Messages API', () async {
      final h = await Harness.create(provider: ProviderKind.vonage);
      final response = await h.vonage('NEW');
      expect(response.statusCode, 204);
      await h.settle();
      expect(h.apiCalls, hasLength(1));
      final call = h.apiCalls.single;
      expect(call.url.toString(), 'https://api.nexmo.com/v1/messages');
      expect(call.headers['authorization'], 'Basic ${base64.encode(utf8.encode('vkey:vsecret'))}');
      final sent = jsonDecode(call.body) as Map;
      expect(sent['to'], '992900000001');
      expect(sent['from'], '15550002222');
      expect(sent['channel'], 'sms');
      expect(sent['text'], startsWith('AGROFY'));
    });

    test('повтор того же message_uuid не обрабатывается дважды', () async {
      final h = await Harness.create(provider: ProviderKind.vonage);
      await h.vonage('NEW', id: 'same');
      await h.vonage('NEW', id: 'same');
      await h.settle();
      expect(h.apiCalls, hasLength(1));
    });

    test('чужой ключ, подмена тела, старый токен и другой api_key отклоняются', () async {
      final h = await Harness.create(provider: ProviderKind.vonage);
      expect((await h.vonage('NEW', jwtSecret: 'wrong-secret-wrong-secret')).statusCode, 403);
      expect((await h.vonage('NEW', id: 'b', payloadHash: sha256Hex('other'))).statusCode, 403);
      expect((await h.vonage('NEW', id: 'c', iatOffsetSeconds: -7200)).statusCode, 401);
      expect((await h.vonage('NEW', id: 'd', apiKey: 'other')).statusCode, 403);
      await h.settle();
      expect(h.apiCalls, isEmpty);
    });

    test('статусы доставки принимаются', () async {
      final h = await Harness.create(provider: ProviderKind.vonage);
      final response = await h.app.handler(Request(
        'POST',
        Uri.parse('https://sms.agrofy.test/sms/vonage/status'),
        body: '{"status":"delivered"}',
      ));
      expect(response.statusCode, 204);
    });

    test('без заголовка Authorization — 401', () async {
      final h = await Harness.create(provider: ProviderKind.vonage);
      final response = await h.app.handler(Request(
        'POST',
        Uri.parse('https://sms.agrofy.test/sms/vonage'),
        body: '{"from":"992900000001","message_uuid":"x","text":"HELP"}',
      ));
      expect(response.statusCode, 401);
    });

    test('конфигурация Vonage требует все ключи', () {
      final config = ServerConfig.fromEnvironment({
        'AGROFY_SMS_PROVIDER': 'vonage',
        'VONAGE_API_KEY': 'k',
        'AGROFY_PUBLIC_URL': 'https://x.sslip.io',
        'AGROFY_AUDIT_SALT': '0123456789abcdef0123',
      });
      expect(config.provider, ProviderKind.vonage);
      expect(config.problems().single, contains('VONAGE_API_SECRET'));
    });
  });

  group('Конфигурация', () {
    test('Twilio в продакшене: нужны https и своя соль', () {
      final base = {
        'AGROFY_SMS_PROVIDER': 'twilio',
        'TWILIO_ACCOUNT_SID': 'AC1',
        'TWILIO_AUTH_TOKEN': 'token',
        'TWILIO_FROM': '+15550000000',
      };
      expect(ServerConfig.fromEnvironment(base).problems(), hasLength(2));
      final ok = ServerConfig.fromEnvironment({
        ...base,
        'AGROFY_PUBLIC_URL': 'https://203.0.113.10.sslip.io/',
        'AGROFY_AUDIT_SALT': '0123456789abcdef0123',
      });
      expect(ok.problems(), isEmpty);
      expect(ok.publicUrl, 'https://203.0.113.10.sslip.io');
    });
  });

  group('Длина SMS', () {
    test('ответ собирается целыми предложениями, без обрыва', () {
      final long = 'Первое предложение про сроки сева хлопка в Согде. '
          'Второе предложение про климат участка и заморозки весной. '
          'Третье предложение про воду и полив в засушливые годы. '
          'Четвёртое предложение, которое уже не поместится в два сегмента.';
      final text = SmsText.fit([long], maxSegments: 2);
      expect(SmsText.segments(text), lessThanOrEqualTo(2));
      expect(text, endsWith('.'));
      expect(text, isNot(contains('…')));
      expect(text, startsWith('Первое'));
    });

    test('висящий заголовок списка отбрасывается', () {
      final text = SmsText.fit(['Засушливых лет 29%.', 'Тренды за 35 лет:', 'x' * 400]);
      expect(text, 'Засушливых лет 29%.');
    });

    test('точка в числе не делит предложение', () {
      expect(SmsText.sentences('NDVI 0.13 на 16.10.2026. Поле F1 40.28,69.62 сохранено.'),
          ['NDVI 0.13 на 16.10.2026.', 'Поле F1 40.28,69.62 сохранено.']);
    });

    test('кириллица — 70 знаков в одном SMS, 67 в части', () {
      expect(SmsText.segments('а' * 70), 1);
      expect(SmsText.segments('а' * 71), 2);
      expect(SmsText.segments('а' * 134), 2);
      expect(SmsText.segments('a' * 160), 1);
      expect(SmsText.segments('a' * 161), 2);
    });

    test('ответ подгоняется под 3 части', () {
      final text = SmsText.fit([
        'Проверьте влажность почвы возле корней.',
        'Признаки могут говорить о водном стрессе, но влажность не измерена.' * 3,
        'Это подсказка, а не диагноз.',
      ]);
      expect(SmsText.segments(text), lessThanOrEqualTo(3));
      expect(text, startsWith('Проверьте влажность'));
      expect(text, endsWith('Это подсказка, а не диагноз.'));
    });

    test('слишком длинная первая часть обрезается по слову', () {
      final text = SmsText.truncate('слово ' * 80, 2);
      expect(SmsText.segments(text), lessThanOrEqualTo(2));
      expect(text, endsWith('…'));
    });
  });

  group('Команды SMS', () {
    test('регистрация, выбор поля и запросы данных', () {
      final reg = SmsCommand.parse('REG F102 40.28,69.62 ХЛОПОК');
      expect(reg.type, SmsCommandType.register);
      expect(reg.fieldId, 'F102');
      expect(reg.point!.latitude, 40.28);
      expect(reg.text, 'ХЛОПОК');

      expect(SmsCommand.parse('field f102').type, SmsCommandType.selectField);

      final ndvi = SmsCommand.parse('FIELD F102 NDVI 90D');
      expect(ndvi.kind, DataRequestKind.ndvi);
      expect(ndvi.days, 90);
      expect(SmsCommand.parse('FIELD F102 CLIMATE 1Y').days, 365);
      expect(SmsCommand.parse('FIELD F102 SOWING').days, 365);
      final ru = SmsCommand.parse('ПОЛЕ F102 НДВИ 3М');
      expect(ru.kind, DataRequestKind.ndvi);
      expect(ru.days, 90);
      expect(SmsCommand.parse('поле F102 климат 2г').days, 730);
      expect(SmsCommand.parse('ПОЛЕ F102 ПОСЕВ').kind, DataRequestKind.sowing);

      final point = SmsCommand.parse('FIELD 48.8566,2.3522 DATA 90D');
      expect(point.point!.longitude, 2.3522);
      expect(point.fieldId, isNull);
    });

    test('ошибки параметров объясняются', () {
      expect(SmsCommand.parse('FIELD F102 RAIN 90D').error, contains('NDVI'));
      expect(SmsCommand.parse('FIELD F102 NDVI 9Y').error, contains('период'));
      expect(SmsCommand.parse('REG F1 200,400').error, contains('Координаты'));
      expect(SmsCommand.parse('FIELD 40.28,69.62').error, contains('тип данных'));
    });

    test('обычный текст — вопрос; служебные слова распознаются', () {
      expect(SmsCommand.parse('Почему желтеют листья?').type, SmsCommandType.question);
      expect(SmsCommand.parse('stop').type, SmsCommandType.stop);
      expect(SmsCommand.parse('ПОМОЩЬ').type, SmsCommandType.help);
      expect(SmsCommand.parse('NEW').type, SmsCommandType.reset);
    });

    test('текст из приложения разбирается сервером так же', () {
      final text = SmsCommand.formatRequest(
        fieldId: 'F7',
        kind: DataRequestKind.climate,
        days: 365,
      );
      expect(text, 'FIELD F7 CLIMATE 1Y');
      final parsed = SmsCommand.parse(text);
      expect(parsed.kind, DataRequestKind.climate);
      expect(parsed.days, 365);

      final reg = SmsCommand.formatRegister('F7', const GeoPoint(40.28, 69.62), crop: 'Хлопок');
      expect(SmsCommand.parse(reg).fieldId, 'F7');
      expect(SmsCommand.formatRequest(fieldId: 'F7', kind: DataRequestKind.ndvi), 'FIELD F7 NDVI 3M');
      expect(SmsCommand.parse('FIELD F7 NDVI 3M').days, 90);
    });
  });

  group('Защита вебхука', () {
    test('неверная подпись — 403, устаревшее время — 401', () async {
      final h = await Harness.create();
      final body = jsonEncode({'from': '+1', 'text': 'HELP', 'id': 'x'});

      expect((await h.raw(body, signature: 'deadbeef')).statusCode, 403);
      final old = h.now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch ~/ 1000;
      expect((await h.raw(body, timestamp: old)).statusCode, 401);
    });

    test('повтор того же сообщения не обрабатывается дважды', () async {
      final h = await Harness.create();
      expect(await h.sms('HELP', id: 'same'), isNotEmpty);
      expect(await h.sms('HELP', id: 'same'), isEmpty);
    });

    test('подпись Twilio проверяется по адресу и параметрам', () async {
      final h = await Harness.create(provider: ProviderKind.twilio);
      final params = {
        'From': '+992900000001',
        'Body': 'HELP',
        'MessageSid': 'SM1',
      };
      final signature = TwilioProvider.signature(
        'twilio-token',
        'https://sms.agrofy.test/sms/twilio',
        params,
      );

      Future<Response> post(String sig) async => await h.app.handler(Request(
            'POST',
            Uri.parse('https://sms.agrofy.test/sms/twilio'),
            body: Uri(queryParameters: params).query,
            headers: {
              'content-type': 'application/x-www-form-urlencoded',
              'x-twilio-signature': sig,
            },
          ));

      final ok = await post(signature);
      expect(ok.statusCode, 200);
      final xml = await ok.readAsString();
      expect(xml, contains('<Response><Message>AGROFY'));
      expect((await post('wrong')).statusCode, 403);
    });
  });

  group('Диалог', () {
    test('HELP, регистрация поля и вопрос о наблюдении', () async {
      final h = await Harness.create();

      expect((await h.sms('HELP')).join(' '), contains('REG F1'));

      final reg = await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      expect(reg.single, contains('поле F1 сохранено'));
      await h.settle();
      expect(h.store.fields['+992900000001']!['F1']!.climate, isNotNull);

      final parts = await h.sms('Листья желтеют, почва сухая');
      final answer = parts.join(' ');
      expect(answer, contains('влажность'));
      expect(parts.first, contains('не диагноз'));
      expect(answer, startsWith('Проверьте влажность почвы'));
      for (final part in parts) {
        expect(SmsText.segments(part), lessThanOrEqualTo(3));
      }

      // Уточнение учитывает прошлое сообщение: теперь есть замер.
      final follow = (await h.sms('влажность почвы 15%')).join(' ');
      expect(follow, contains('полив'));
    });

    test('«что если будет засуха» — сценарий, а не наблюдение', () async {
      final h = await Harness.create();
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.settle();
      final reply = (await h.sms('Что если будет засуха?')).join(' ');
      expect(reply, isNot(contains('не диагноз')));
      expect(reply, isNot(contains('вкладк')));
      expect(reply, isNot(contains('загружаются')));
      expect(h.power.historyCalls, 1);
      final observed = (await h.sms('Почва сухая, листья вянут')).join(' ');
      expect(observed, contains('не диагноз'));
    });

    test('история догружается для поля, зарегистрированного без неё', () async {
      final h = await Harness.create();
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.settle();
      h.store.fields['+992900000001']!['F1'] = FieldRecord(
        fieldId: 'F1',
        latitude: 40.28,
        longitude: 69.62,
        crop: 'ХЛОПОК',
        registeredAt: h.now,
        climate: h.store.fields['+992900000001']!['F1']!.climate,
      );
      final first = (await h.sms('Что если будет засуха?')).join(' ');
      expect(first, contains('загружаются'));
      await h.settle();
      final second = (await h.sms('А если засуха?')).join(' ');
      expect(second, isNot(contains('загружаются')));
    });

    test('культура томат и маш распознаются, советник работает', () async {
      final h = await Harness.create();
      await h.sms('REG F1 40.28,69.62 ТОМАТ');
      await h.settle();
      final reply = (await h.sms('Что посадить после томатов?')).join(' ');
      expect(reply, isNot(contains('не указана')));
      final reg = (await h.sms('REG F2 40.28,69.62 маш')).join(' ');
      expect(reg, isNot(contains('нет в справочнике')));
    });

    test('неизвестная или пропущенная культура — подсказка сразу', () async {
      final h = await Harness.create();
      final unknown = (await h.sms('REG F1 40.28,69.62 БАНАН')).join(' ');
      expect(unknown, contains('нет в справочнике'));
      final none = (await h.sms('REG F2 40.28,69.62')).join(' ');
      expect(none, contains('Культура не указана'));
      await h.settle();
      final reply = (await h.sms('Какой севооборот лучше?')).join(' ');
      expect(reply, contains('не указана культура'));
      expect(reply, contains('REG F2'));
    });

    test('уточнение из спецификации: нижние листья, почва влажная', () async {
      final h = await Harness.create();
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.sms('Почему у моих томатов желтеют листья?');
      final reply = (await h.sms('В основном нижние листья, почва влажная')).join(' ');
      expect(reply, startsWith('Не добавляйте полив'));
      expect(reply, contains('переувлажнение'));
      expect(reply, contains('не диагноз'));
      expect(reply, isNot(contains('восстанавливают')));
    });

    test('противоречие в диалоге: сухая почва и высокий замер', () async {
      final h = await Harness.create();
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.sms('почва сухая');
      final reply = (await h.sms('влажность почвы 80%')).join(' ');
      expect(reply, contains('противоречие'));
    });

    test('NEW сбрасывает признаки прошлых сообщений', () async {
      final h = await Harness.create();
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.sms('почва сухая');
      await h.sms('NEW');
      final reply = (await h.sms('влажность почвы 80%')).join(' ');
      expect(reply, isNot(contains('противоречие')));
    });

    test('вопрос о севообороте использует климат зарегистрированного поля', () async {
      final h = await Harness.create();
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      final parts = await h.sms('Что посеять после хлопка?');
      expect(parts.join(' '), contains('Советую'));
      for (final part in parts) {
        expect(SmsText.segments(part), lessThanOrEqualTo(3));
      }
    });

    test('без поля просит зарегистрировать его, термины объясняет', () async {
      final h = await Harness.create();
      expect((await h.sms('Что посеять?')).join(' '), contains('REG F1'));
      expect((await h.sms('Что такое NDVI?')).join(' '), contains('NDVI'));
    });

    test('чужое поле недоступно', () async {
      final h = await Harness.create();
      await h.sms('REG F1 40.28,69.62', from: '+992900000001');
      expect((await h.sms('FIELD F1', from: '+992900000002')).join(' '), contains('не найдено'));
      expect(
        (await h.sms('FIELD F1 NDVI 90D', from: '+992900000002')).join(' '),
        contains('нет доступа'),
      );
    });

    test('STOP: после отписки ответов нет, START включает', () async {
      final h = await Harness.create();
      expect((await h.sms('STOP')).join(' '), contains('отписаны'));
      expect(await h.sms('HELP'), isEmpty);
      expect((await h.sms('START')).join(' '), contains('снова включены'));
    });

    test('лимит: одно предупреждение, дальше тишина', () async {
      final h = await Harness.create(maxPerHour: 2);
      expect(await h.sms('HELP'), isNotEmpty);
      expect(await h.sms('HELP'), isNotEmpty);
      expect((await h.sms('HELP')).join(' '), contains('лимит'));
      expect(await h.sms('HELP'), isEmpty);
    });

    test('слишком длинное сообщение', () async {
      final h = await Harness.create();
      expect((await h.sms('а' * 500)).join(' '), contains('слишком длинное'));
    });
  });

  group('Спутниковые данные по SMS', () {
    test('NDVI со ссылками: подтверждение, затем SMS со ссылкой на проверяемый пакет', () async {
      final h = await Harness.create(reportLinks: true);
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.settle();

      final ack = (await h.sms('FIELD F1 NDVI 90D')).single;
      expect(ack, contains('принят'));
      await h.settle();

      final sent = h.outbox();
      expect(sent.first['to'], '+992900000001');
      final text = sent.map((m) => m['text']).join(' ');
      expect(text, contains('PARTIAL')); // одно наблюдение облачное
      final url = RegExp(r'https://sms\.agrofy\.test/p/[A-Za-z0-9_-]+').firstMatch(text)!.group(0)!;
      expect(url, isNot(contains('40.28')));
      for (final m in sent) {
        expect(SmsText.segments(m['text'] as String), lessThanOrEqualTo(3));
      }

      final download = await h.app.handler(Request('GET', Uri.parse(url)));
      expect(download.statusCode, 200);
      expect(download.headers['content-disposition'], contains('agrofy-REQ-2026-'));

      final check = DataPackageReader.read(await download.readAsString());
      expect(check.ok, isTrue, reason: check.errors.join('; '));
      final package = check.package!;
      expect(package.field.fieldId, 'F1');
      expect(package.datasets.single.source, 'NASA_MODIS_MOD13Q1');
      expect(package.datasets.single.observations.length, 3);
      expect(package.quality.status, PackageStatus.partial);
    });

    test('DATA по координатам: NDVI и климат NASA POWER', () async {
      final h = await Harness.create(reportLinks: true);
      await h.sms('FIELD 40.28,69.62 DATA 90D');
      await h.settle();

      final url = RegExp(r'https://\S+/p/[A-Za-z0-9_-]+')
          .firstMatch(h.outbox().map((m) => m['text']).join(' '))!
          .group(0)!;
      final package = DataPackageReader.read(
        await (await h.app.handler(Request('GET', Uri.parse(url)))).readAsString(),
      ).package!;
      expect(package.datasets.map((d) => d.source), ['NASA_MODIS_MOD13Q1', 'NASA_POWER']);
      expect(package.quality.missingData.single, contains('ещё не обработаны'));
    });

    test('без интернета: значения NDVI приходят прямо в SMS', () async {
      final h = await Harness.create();
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.settle();
      await h.sms('FIELD F1 NDVI 90D');
      await h.settle();
      final text = h.outbox().map((m) => m['text']).join(' ');
      expect(text, isNot(contains('http')));
      expect(text, contains('14.09 0.18'));
      expect(text, contains('16.10 0.13 обл.'));
      expect(text, contains('максимум 0.21'));
    });

    test('без интернета: климат за год — помесячно, страницами', () async {
      final h = await Harness.create();
      await h.sms('REG F1 40.28,69.62 ХЛОПОК');
      await h.settle();
      await h.sms('FIELD F1 CLIMATE 1Y');
      await h.settle();
      final pages = [for (final m in h.outbox()) m['text'] as String];
      expect(pages.length, greaterThan(1));
      expect(pages.last, endsWith('(${pages.length}/${pages.length})'));
      final all = pages.join(' ');
      expect(all, contains('Климат NASA POWER по месяцам'));
      expect(all, contains('20°'));
      for (final page in pages) {
        expect(SmsText.segments(page), lessThanOrEqualTo(3));
      }
    });

    test('нет наблюдений — UNAVAILABLE без ссылки', () async {
      final h = await Harness.create(ndvi: const []);
      await h.sms('FIELD 40.28,69.62 NDVI 90D');
      await h.settle();

      final text = h.outbox().single['text'] as String;
      expect(text, contains('UNAVAILABLE'));
      expect(text, isNot(contains('/p/')));
      expect(h.store.packages, isEmpty);
    });

    test('ссылка перестаёт работать после срока и для чужого токена', () async {
      final h = await Harness.create();
      await h.sms('FIELD 40.28,69.62 NDVI 90D');
      await h.settle();
      final token = h.store.packages.keys.single;

      expect(
        (await h.app.handler(Request('GET', Uri.parse('https://sms.agrofy.test/p/unknown')))).statusCode,
        404,
      );

      await h.store.purge(h.now.add(const Duration(days: 8)), const Duration(hours: 24));
      expect(
        (await h.app.handler(Request('GET', Uri.parse('https://sms.agrofy.test/p/$token')))).statusCode,
        404,
      );
    });
  });

  group('Проверка пакета при импорте', () {
    DataPackage sample() => DataPackage(
          requestId: 'REQ-1',
          createdAt: DateTime.utc(2026, 11, 15),
          field: const PackageField(fieldId: 'F1', latitude: 40.28, longitude: 69.62),
          periodStart: DateTime.utc(2026, 8, 1),
          periodEnd: DateTime.utc(2026, 11, 1),
          datasets: [
            PackageDataset(
              source: 'NASA_MODIS_MOD13Q1',
              product: 'ndvi',
              provider: 'ORNL',
              resolution: '250 m',
              units: const {'ndvi': '1'},
              observations: [
                PackageObservation(date: DateTime.utc(2026, 9, 14), variable: 'ndvi', value: 0.2),
              ],
            ),
          ],
          quality: const PackageQuality(status: PackageStatus.ready),
        );

    test('корректный пакет принимается', () {
      final check = DataPackageReader.read(sample().encode());
      expect(check.ok, isTrue);
      expect(check.warnings, isEmpty);
    });

    test('изменённые данные не проходят по контрольной сумме', () {
      final tampered = sample().encode().replaceFirst('"value": 0.2', '"value": 0.9');
      expect(tampered, isNot(sample().encode()));
      expect(DataPackageReader.read(tampered).errors.single, contains('Контрольная сумма'));
    });

    test('неизвестная версия схемы и чужой файл отклоняются', () {
      final json = jsonDecode(sample().encode()) as Map<String, dynamic>;
      expect(
        DataPackageReader.read(jsonEncode({...json, 'schema_version': '2.0'})).errors.single,
        contains('не поддерживается'),
      );
      expect(DataPackageReader.read('{"a":1}').errors.single, contains('не поддерживается'));
      expect(DataPackageReader.read('не json').errors.single, contains('JSON'));
    });

    test('набор с неизвестными единицами пропускается с предупреждением', () {
      final json = jsonDecode(sample().encode()) as Map<String, dynamic>;
      (json['datasets'] as List).first['units'] = {'ndvi': 'percent'};
      final check = DataPackageReader.read(jsonEncode(json));
      expect(check.ok, isTrue);
      expect(check.package!.datasets, isEmpty);
      expect(check.warnings.single, contains('неизвестные единицы'));
    });
  });
}
