import 'dart:io';

import 'package:agrofy_sms_server/agrofy_sms_server.dart';
import 'package:shelf/shelf_io.dart' as io;

Future<void> main() async {
  final config = ServerConfig.fromEnvironment();
  final problems = config.problems();
  if (problems.isNotEmpty) {
    stderr.writeln('Сервер не запущен:\n${problems.join('\n')}');
    exitCode = 64;
    return;
  }

  final store = await Store.open(config.dataDir);
  final SmsProvider provider = switch (config.provider) {
    ProviderKind.twilio => TwilioProvider(config),
    ProviderKind.vonage => VonageProvider(config),
    ProviderKind.generic => GenericProvider(config),
  };
  final app = SmsServerApp(
    config: config,
    store: store,
    provider: provider,
    service: SmsService(
      config: config,
      store: store,
      data: DataPackageService(config, store),
      provider: provider,
    ),
  );

  final server = await io.serve(app.handler, InternetAddress.anyIPv4, config.port);
  stdout.writeln(
    'AGROFY SMS сервер: порт ${server.port}, провайдер ${config.provider.name}, '
    'адрес ${config.publicUrl}',
  );
}
