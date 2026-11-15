import '../decision/observation_interpreter.dart';
import 'text_features.dart';

/// Правила, по которым локальная языковая модель поясняет ответ
/// ассистента, и проверка, что она не добавила ничего от себя.
///
/// Модель маленькая и может ошибаться или терять суть, поэтому она не
/// источник фактов: точный ответ ассистента показывается всегда, а модель
/// добавляет к нему короткое пояснение простыми словами.
class LlmGrounding {
  static const String systemPrompt =
      'Ты помощник фермера. Тебе дают вопрос и факты. Объясни фермеру суть '
      'ответа по-русски, простыми словами, в двух коротких предложениях. '
      'Используй только данные факты. Не добавляй чисел, культур и советов, '
      'которых нет в фактах. Не используй списки и заголовки.';

  /// Самые длинные ответы обрезаются, чтобы уложиться в контекст модели.
  static const int maxFactsLength = 1400;

  static String userPrompt(String question, String facts) {
    final trimmed = facts.length > maxFactsLength
        ? facts.substring(0, maxFactsLength)
        : facts;
    return 'Вопрос: $question\n\nФакты:\n$trimmed\n\nСуть простыми словами:';
  }

  static final RegExp _number = RegExp(r'\d+(?:[.,]\d+)?');

  static Set<String> numbers(String text) {
    return _number
        .allMatches(text)
        .map((match) => match.group(0)!.replaceAll(',', '.'))
        .toSet();
  }

  /// Числа из ответа модели, которых нет ни в фактах, ни в вопросе.
  static Set<String> inventedNumbers(
    String output, {
    required String facts,
    String question = '',
  }) {
    final known = {...numbers(facts), ...numbers(question)};
    return numbers(output).difference(known);
  }

  /// Доля кириллицы среди букв: маленькие модели иногда сбиваются
  /// на английский или китайский.
  static double cyrillicShare(String text) {
    var letters = 0;
    var cyrillic = 0;

    for (final rune in text.runes) {
      final isCyrillic = rune >= 0x0400 && rune <= 0x04FF;
      final isLatin = (rune >= 0x41 && rune <= 0x5A) ||
          (rune >= 0x61 && rune <= 0x7A);
      final isCjk = rune >= 0x3040 && rune <= 0x9FFF;

      if (isCyrillic || isLatin || isCjk) {
        letters++;
        if (isCyrillic) {
          cyrillic++;
        }
      }
    }

    return letters == 0 ? 0 : cyrillic / letters;
  }

  /// Какая доля значимых слов ответа модели взята из фактов или вопроса.
  /// Низкая доля значит, что модель ушла от темы.
  static double overlap(
    String output, {
    required String facts,
    String question = '',
  }) {
    final known = {
      ...TextFeatures.stems(facts),
      ...TextFeatures.stems(question),
    };
    final words = TextFeatures.stems(output)
        .where((stem) => stem.length >= 4)
        .toList();

    if (words.isEmpty) {
      return 0;
    }
    return words.where(known.contains).length / words.length;
  }

  /// Культуры, которые модель назвала, хотя их нет в фактах. Культура из
  /// вопроса не в счёт: модель могла посоветовать её снова вопреки расчёту
  /// («хлопок после хлопка»).
  static Set<String> inventedCrops(String output, {required String facts}) {
    final known = ObservationInterpreter.mentionedCropIds(facts).toSet();
    return ObservationInterpreter.mentionedCropIds(output)
        .toSet()
        .difference(known);
  }

  /// Можно ли показать пояснение модели рядом с точным ответом.
  static bool isAcceptable(
    String output, {
    required String facts,
    String question = '',
  }) {
    final text = output.trim();

    return text.length >= 40 &&
        cyrillicShare(text) >= 0.8 &&
        overlap(text, facts: facts, question: question) >= 0.3 &&
        inventedCrops(text, facts: facts).isEmpty &&
        inventedNumbers(text, facts: facts, question: question).isEmpty;
  }
}
