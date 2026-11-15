import 'package:agrofy_core/ai/llm_grounding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const facts = 'Советую вариант «Экономия воды»: Хлопок → Ячмень яровой → '
      'Нут. Оценка 71 из 100 против 48 у текущего севооборота. Полив около '
      '439 мм в год.';

  test('пересказ с числами из фактов принимается', () {
    const output = 'Лучше всего подойдёт севооборот хлопок, ячмень и нут. '
        'Он получил 71 балл из 100, а нынешний только 48. Воды на полив '
        'понадобится около 439 мм в год.';

    expect(LlmGrounding.isAcceptable(output, facts: facts), isTrue);
  });

  test('выдуманное число отклоняется', () {
    const output = 'Севооборот хлопок, ячмень и нут даст урожай 35 центнеров '
        'с гектара и получил 71 балл из 100.';

    expect(
      LlmGrounding.inventedNumbers(output, facts: facts),
      contains('35'),
    );
    expect(LlmGrounding.isAcceptable(output, facts: facts), isFalse);
  });

  test('число из вопроса не считается выдуманным', () {
    const output = 'На 5 гектарах лучше всего сеять хлопок, ячмень и нут, '
        'этот вариант получил 71 из 100.';

    expect(
      LlmGrounding.isAcceptable(
        output,
        facts: facts,
        question: 'Что посеять на 5 гектарах?',
      ),
      isTrue,
    );
  });

  test('десятичная запятая и точка считаются одним числом', () {
    expect(
      LlmGrounding.inventedNumbers('уклон 1,2%', facts: 'уклон 1.2%'),
      isEmpty,
    );
  });

  test('ответ не на русском отклоняется', () {
    const output = 'The best rotation is cotton, barley and chickpea with a '
        'score of 71 out of 100.';

    expect(LlmGrounding.cyrillicShare(output), lessThan(0.1));
    expect(LlmGrounding.isAcceptable(output, facts: facts), isFalse);
  });

  test('ответ не по теме отклоняется', () {
    const output = 'Погода в горах переменчива, поэтому туристам стоит брать '
        'тёплую одежду и запас еды на несколько дней.';

    expect(LlmGrounding.overlap(output, facts: facts), lessThan(0.3));
    expect(LlmGrounding.isAcceptable(output, facts: facts), isFalse);
  });

  test('культура не из фактов отклоняется, даже если она в вопросе', () {
    // Реальный ответ Qwen2.5-0.5B на Android-эмуляторе.
    const facts = 'Советую вариант «Экономия воды»: Пшеница озимая → '
        'Бахчевые (дыня, арбуз) → Нут. Оценка 75 из 100 против 59.';
    const output = 'Посаживать хлопку можно после хлопка. Это культура '
        'высокой засухоустойчивости. Можно использовать бахчевые (дыня, '
        'арбуз) или нут.';

    expect(LlmGrounding.inventedCrops(output, facts: facts), {'cotton'});
    expect(
      LlmGrounding.isAcceptable(
        output,
        facts: facts,
        question: 'Что посеять после хлопка?',
      ),
      isFalse,
    );
  });

  test('пустой или слишком короткий ответ отклоняется', () {
    expect(LlmGrounding.isAcceptable('', facts: facts), isFalse);
    expect(LlmGrounding.isAcceptable('Да.', facts: facts), isFalse);
  });

  test('слишком длинные факты обрезаются под контекст модели', () {
    final prompt = LlmGrounding.userPrompt('Вопрос?', 'а' * 5000);

    expect(prompt.length, lessThan(LlmGrounding.maxFactsLength + 100));
  });
}
