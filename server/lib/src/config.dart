import 'dart:io';

enum ProviderKind { twilio, vonage, generic }

/// Настройки сервера из переменных окружения. Секреты в код не попадают.
class ServerConfig {
  final int port;

  /// Внешний адрес сервера (https://…) — для ссылок на пакеты и проверки
  /// подписи Twilio.
  final String publicUrl;

  final String dataDir;
  final ProviderKind provider;

  // Twilio
  final String? twilioAccountSid;
  final String? twilioAuthToken;
  final String? twilioFrom;

  // Vonage (Messages API)
  final String? vonageApiKey;
  final String? vonageApiSecret;
  final String? vonageSignatureSecret;
  final String? vonageFrom;

  // Универсальный шлюз (например, Android-телефон с SMS-шлюзом)
  final String? webhookSecret;
  final String? outboundUrl;

  /// Соль для обезличивания номеров в журнале.
  final String auditSalt;

  final int maxPerHour;
  final int maxPerDay;
  final int maxDataRequestsPerDay;
  final int maxReplySegments;

  /// Давать ли ссылки (отчёт в браузере, файл пакета). По умолчанию нет:
  /// у фермера может не быть интернета, всё приходит текстом по страницам.
  final bool reportLinks;

  /// Сколько страниц (SMS) может быть у одного длинного ответа.
  final int maxPages;
  final Duration packageTtl;
  final Duration contextTtl;

  const ServerConfig({
    this.port = 8080,
    this.publicUrl = 'http://localhost:8080',
    this.dataDir = 'data',
    this.provider = ProviderKind.generic,
    this.twilioAccountSid,
    this.twilioAuthToken,
    this.twilioFrom,
    this.vonageApiKey,
    this.vonageApiSecret,
    this.vonageSignatureSecret,
    this.vonageFrom,
    this.webhookSecret,
    this.outboundUrl,
    this.auditSalt = 'agrofy',
    this.maxPerHour = 20,
    this.maxPerDay = 60,
    this.maxDataRequestsPerDay = 5,
    this.maxReplySegments = 3,
    this.reportLinks = false,
    this.maxPages = 8,
    this.packageTtl = const Duration(days: 7),
    this.contextTtl = const Duration(hours: 24),
  });

  factory ServerConfig.fromEnvironment([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    int number(String key, int fallback) => int.tryParse(e[key] ?? '') ?? fallback;

    return ServerConfig(
      port: number('PORT', 8080),
      publicUrl: (e['AGROFY_PUBLIC_URL'] ?? 'http://localhost:8080')
          .replaceAll(RegExp(r'/+$'), ''),
      dataDir: e['AGROFY_DATA_DIR'] ?? 'data',
      provider: switch (e['AGROFY_SMS_PROVIDER']) {
        'twilio' => ProviderKind.twilio,
        'vonage' => ProviderKind.vonage,
        _ => ProviderKind.generic,
      },
      twilioAccountSid: e['TWILIO_ACCOUNT_SID'],
      twilioAuthToken: e['TWILIO_AUTH_TOKEN'],
      twilioFrom: e['TWILIO_FROM'],
      vonageApiKey: e['VONAGE_API_KEY'],
      vonageApiSecret: e['VONAGE_API_SECRET'],
      vonageSignatureSecret: e['VONAGE_SIGNATURE_SECRET'],
      vonageFrom: e['VONAGE_FROM'],
      webhookSecret: e['AGROFY_WEBHOOK_SECRET'],
      outboundUrl: e['AGROFY_OUTBOUND_URL'],
      auditSalt: e['AGROFY_AUDIT_SALT'] ?? 'agrofy',
      maxPerHour: number('AGROFY_MAX_PER_HOUR', 20),
      maxPerDay: number('AGROFY_MAX_PER_DAY', 60),
      maxDataRequestsPerDay: number('AGROFY_MAX_DATA_PER_DAY', 5),
      maxReplySegments: number('AGROFY_MAX_REPLY_SEGMENTS', 3),
      reportLinks: const {'1', 'true', 'yes', 'on'}
          .contains((e['AGROFY_REPORT_LINKS'] ?? '').toLowerCase()),
      maxPages: number('AGROFY_MAX_PAGES', 8),
    );
  }

  /// Проблемы конфигурации, из-за которых сервер нельзя запускать.
  List<String> problems() {
    return [
      if (provider == ProviderKind.twilio &&
          (twilioAccountSid == null || twilioAuthToken == null || twilioFrom == null))
        'Для Twilio нужны TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN и TWILIO_FROM.',
      if (provider == ProviderKind.vonage &&
          (vonageApiKey == null ||
              vonageApiSecret == null ||
              vonageSignatureSecret == null ||
              vonageFrom == null))
        'Для Vonage нужны VONAGE_API_KEY, VONAGE_API_SECRET, '
            'VONAGE_SIGNATURE_SECRET и VONAGE_FROM.',
      if (provider != ProviderKind.generic && !publicUrl.startsWith('https://'))
        'AGROFY_PUBLIC_URL должен быть публичным адресом https://… — на него '
            'провайдер шлёт вебхуки и по нему строятся ссылки на пакеты.',
      if (provider != ProviderKind.generic && auditSalt.length < 16)
        'Задайте AGROFY_AUDIT_SALT (от 16 символов) — иначе хеши телефонов в '
            'журнале легко подобрать.',
      if (provider == ProviderKind.generic &&
          (webhookSecret == null || webhookSecret!.length < 16))
        'Для универсального шлюза нужен AGROFY_WEBHOOK_SECRET (от 16 символов).',
    ];
  }
}
