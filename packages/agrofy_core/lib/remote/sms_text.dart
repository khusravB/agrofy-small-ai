/// Длина SMS и подгонка ответа под заданное число частей.
///
/// Латиница и базовые знаки идут в кодировке GSM-7: 160 знаков в одном SMS,
/// 153 в каждой части длинного. Кириллица — в UCS-2: 70 и 67. Каждая часть
/// оплачивается отдельно, поэтому ответы сжимаются.
class SmsText {
  static const String _gsmBasic =
      '@£\$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?'
      '¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà';
  static const String _gsmExtension = '^{}\\[~]|€';

  static bool isGsm(String text) {
    for (final rune in text.runes) {
      final char = String.fromCharCode(rune);
      if (!_gsmBasic.contains(char) && !_gsmExtension.contains(char)) {
        return false;
      }
    }
    return true;
  }

  /// Длина в единицах кодировки (символ расширения GSM занимает две).
  static int units(String text) {
    if (isGsm(text)) {
      var count = 0;
      for (final rune in text.runes) {
        count += _gsmExtension.contains(String.fromCharCode(rune)) ? 2 : 1;
      }
      return count;
    }
    return text.length; // UTF-16: эмодзи занимает две единицы, как в UCS-2.
  }

  static int segments(String text) {
    if (text.isEmpty) {
      return 1;
    }
    final gsm = isGsm(text);
    final single = gsm ? 160 : 70;
    final part = gsm ? 153 : 67;
    final length = units(text);
    return length <= single ? 1 : (length / part).ceil();
  }

  /// Максимальная длина в единицах, которая помещается в [maxSegments].
  static int capacity(String text, int maxSegments) {
    final gsm = isGsm(text);
    if (maxSegments <= 1) {
      return gsm ? 160 : 70;
    }
    return (gsm ? 153 : 67) * maxSegments;
  }

  /// Предложения текста. Точка внутри числа («0.13», «40.28,69.62») не
  /// считается концом предложения.
  static List<String> sentences(String text) => [
        for (final s in text.trim().split(RegExp(r'(?<=[.!?…])\s+')))
          if (s.trim().isNotEmpty) s.trim(),
      ];

  /// Собирает ответ из частей по порядку важности, целыми предложениями:
  /// предложение добавляется, только если весь текст (вместе с [suffix])
  /// остаётся в пределах [maxSegments]; на первом не поместившемся
  /// предложении часть заканчивается и начинается следующая. Обрезается по
  /// слову только первое предложение, если оно одно длиннее лимита.
  /// [suffix] — то, что всегда стоит в конце (например, ссылка).
  static String fit(List<String> parts, {int maxSegments = 3, String suffix = ''}) {
    bool fits(String text) => segments('$text$suffix') <= maxSegments;

    var text = '';
    for (final part in parts) {
      for (final sentence in sentences(part)) {
        final candidate = text.isEmpty ? sentence : '$text $sentence';
        if (fits(candidate)) {
          text = candidate;
        } else {
          if (text.isEmpty) {
            text = truncate(sentence, maxSegments, reserve: suffix);
          }
          break;
        }
      }
    }
    // Заголовок списка («Тренды за 35 лет:»), за которым ничего не
    // поместилось, не оставляем.
    final kept = sentences(text);
    while (kept.length > 1 && kept.last.endsWith(':')) {
      kept.removeLast();
    }
    return '${kept.join(' ')}$suffix';
  }

  /// Обрезает текст по границе слова, чтобы он вместе с [reserve]
  /// поместился в [maxSegments].
  static String truncate(String text, int maxSegments, {String reserve = ''}) {
    if (segments('$text$reserve') <= maxSegments) {
      return text;
    }
    final limit = capacity('$text$reserve', maxSegments) - reserve.length - 1;
    var cut = text.substring(0, limit.clamp(0, text.length));
    final space = cut.lastIndexOf(' ');
    if (space > limit ~/ 2) {
      cut = cut.substring(0, space);
    }
    return '$cut…';
  }
}
