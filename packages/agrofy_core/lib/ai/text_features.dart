/// Подготовка русского текста для небольших моделей: нормализация,
/// грубый стемминг и символьные триграммы (устойчивы к опечаткам).
class TextFeatures {
  static const List<String> _endings = [
    'иями', 'ями', 'ами', 'ого', 'его', 'ому', 'ему', 'ыми', 'ими', //
    'ией', 'иях', 'ах', 'ях', 'ов', 'ев', 'ей', 'ой', 'ий', 'ый', //
    'ая', 'яя', 'ое', 'ее', 'ые', 'ие', 'ам', 'ям', 'ом', 'ем', //
    'ую', 'юю', 'ть', 'ся', 'а', 'я', 'о', 'е', 'ы', 'и', 'у', 'ю', 'ь',
  ];

  static const Set<String> _stopWords = {
    'и', 'в', 'во', 'на', 'с', 'со', 'по', 'для', 'а', 'но', 'или', //
    'ли', 'же', 'бы', 'это', 'мне', 'мой', 'моя', 'мое', 'у', 'к', 'о',
    'об', 'от', 'до', 'за', 'из', 'не', 'да',
  };

  static String normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll('ё', 'е')
        .replaceAll(RegExp(r'[^a-zа-яҷқғҳӯӣ0-9]+'), ' ')
        .trim();
  }

  static List<String> tokens(String text) {
    final normalized = normalize(text);
    if (normalized.isEmpty) {
      return const [];
    }
    return normalized.split(' ');
  }

  static String stem(String token) {
    if (token.length <= 4) {
      return token;
    }
    for (final ending in _endings) {
      if (token.endsWith(ending) && token.length - ending.length >= 3) {
        return token.substring(0, token.length - ending.length);
      }
    }
    return token;
  }

  /// Основы значимых слов.
  static List<String> stems(String text) {
    return [
      for (final token in tokens(text))
        if (!_stopWords.contains(token)) stem(token),
    ];
  }

  /// Признаки для классификатора: основы слов и символьные триграммы.
  static List<String> features(String text) {
    final result = <String>[];

    for (final token in tokens(text)) {
      if (_stopWords.contains(token)) {
        continue;
      }
      result.add('w:${stem(token)}');

      final padded = '#$token#';
      for (var i = 0; i + 3 <= padded.length; i++) {
        result.add('g:${padded.substring(i, i + 3)}');
      }
    }

    return result;
  }
}
