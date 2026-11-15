import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'config.dart';
import 'store.dart';

/// Раздел отчёта: заголовок, абзацы и список.
class ReportSection {
  final String title;
  final List<String> paragraphs;
  final List<String> items;

  const ReportSection(this.title, {this.paragraphs = const [], this.items = const []});

  bool get isEmpty => paragraphs.isEmpty && items.isEmpty;
}

/// Отчёты, которые не помещаются в SMS: простая HTML-страница по
/// случайной ссылке. Открывается в любом браузере телефона, без
/// приложения; срок жизни — как у пакетов данных.
class ReportService {
  final ServerConfig config;
  final Store store;
  final DateTime Function() clock;
  final Random _random;

  ReportService(this.config, this.store, {DateTime Function()? clock, Random? random})
      : clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  /// 12 случайных байт (96 бит): ссылку нельзя угадать, а в SMS она
  /// занимает немного места.
  String _token() => base64Url
      .encode(List<int>.generate(12, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  String urlFor(String token) => '${config.publicUrl}/r/$token';

  /// Длина ссылки — чтобы заранее оставить для неё место в SMS.
  int get urlLength => urlFor('x' * 16).length;

  Future<String> publish({
    required String ownerHash,
    required String title,
    required List<ReportSection> sections,
    String? footer,
  }) async {
    final now = clock();
    final token = _token();
    final html = render(title: title, sections: sections, footer: footer, createdAt: now);
    await File('${store.reportsDir.path}/$token.html').writeAsString(html);
    store.reports[token] = ReportRecord(
      token: token,
      ownerHash: ownerHash,
      title: title,
      createdAt: now,
      expiresAt: now.add(config.packageTtl),
    );
    await store.save();
    return urlFor(token);
  }

  static String _escape(String text) => const HtmlEscape().convert(text);

  static String render({
    required String title,
    required List<ReportSection> sections,
    String? footer,
    required DateTime createdAt,
  }) {
    final body = StringBuffer();
    for (final section in sections) {
      if (section.isEmpty) {
        continue;
      }
      body.writeln('<h2>${_escape(section.title)}</h2>');
      for (final p in section.paragraphs) {
        body.writeln('<p>${_escape(p)}</p>');
      }
      if (section.items.isNotEmpty) {
        body.writeln('<ul>');
        for (final item in section.items) {
          body.writeln('<li>${_escape(item)}</li>');
        }
        body.writeln('</ul>');
      }
    }
    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${two(createdAt.day)}.${two(createdAt.month)}.${createdAt.year}';

    return '''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${_escape(title)}</title>
<style>
:root{--bg:#fff;--fg:#1b1f1c;--muted:#5d665f;--accent:#276749;--line:#dfe5e0}
@media (prefers-color-scheme:dark){:root{--bg:#121513;--fg:#e8ece9;--muted:#a3ada6;--accent:#7cc79a;--line:#2a302c}}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:680px;margin:0 auto;padding:20px 16px 40px}
h1{font-size:1.35rem;margin:0 0 4px;color:var(--accent)}
.date{color:var(--muted);font-size:.9rem;margin:0 0 16px}
h2{font-size:1.05rem;margin:22px 0 6px;padding-top:12px;border-top:1px solid var(--line)}
p{margin:6px 0}ul{margin:6px 0;padding-left:20px}li{margin:4px 0}
footer{margin-top:28px;color:var(--muted);font-size:.85rem}
</style>
</head>
<body><main>
<h1>${_escape(title)}</h1>
<p class="date">AGROFY · $date</p>
$body<footer>${_escape(footer ?? 'Подсказка, не диагноз. Решение принимает фермер вместе с агрономом.')}</footer>
</main></body>
</html>
''';
  }
}
