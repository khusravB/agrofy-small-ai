import 'dart:convert';

import '../ai/text_features.dart';
import '../data/assistant_training.dart';
import 'observation.dart';

/// Small AI Interpreter: свободный текст фермера → структурированные
/// наблюдения с источником и статусом.
///
/// Основной путь — компактный словарный разбор: он детерминирован, работает
/// всегда и без сети. Языковая модель, если она скачана, может добавить
/// признаки, но только по строгой схеме и только со статусом
/// «предположение» — её вывод не становится фактом.
class ObservationInterpreter {
  const ObservationInterpreter();

  /// Корни слов для однозначных признаков. Слово совпадает, если
  /// начинается с корня; корень с «=» должен совпасть со словом целиком
  /// (короткие таджикские слова, чтобы не путать с русскими). Длинные
  /// корни допускают одну опечатку.
  ///
  /// Таджикские слова добавлены разработчиками и требуют проверки
  /// носителем языка.
  static const Map<ObservationAttribute, Map<String, List<String>>> _lexicon = {
    ObservationAttribute.leaves: {
      'yellowing': [
        'желт', 'пожелт', 'жолт', 'бледн', 'посветл', 'хлороз', //
        '=зард', 'зардшуд', 'зардгашт',
      ],
      'wilting': [
        'вян', 'увяд', 'завял', 'поник', 'скруч', 'скрутил', 'свернул',
        'сворач', 'обвис', 'пажмурд',
      ],
      'spots': [
        'пятн', 'налет', 'ржавч', 'крапин', 'гнил', 'плесен', 'мучнист',
        '=доғ',
      ],
    },
    ObservationAttribute.soil: {
      'crusted': ['корк', 'уплотн'],
    },
    ObservationAttribute.weather: {
      'hot': ['жар', 'зной', 'пекл', 'духот', 'палит', 'солнцепек', '=гарм',
          '=гармо', 'гармӣ'],
      'cold': ['холод', 'похолод', 'прохлад', 'хунук', '=сард'],
      'frost': ['заморозк', 'заморозок', 'мороз', 'иней', 'сармо', '=ях',
          'яхбанд'],
      'rain': ['дожд', 'ливн', 'ливен', 'борон'],
      'wind': ['ветер', 'ветр', 'суховей', 'ураган', 'шамол'],
    },
    ObservationAttribute.pests: {
      'present': [
        'вредител', 'тля', 'тли', 'клещ', 'гусениц', 'жук', 'насеком',
        'долгоносик', 'саранч', 'трипс', 'белокрылк', 'совк', 'медведк',
        'червец', 'слизн', 'улитк', 'паутин', 'ҳашарот', 'зараррасон',
        '=кирм',
      ],
    },
    ObservationAttribute.growth: {
      'slow': ['отста', 'замедл', 'чахл', 'низкоросл'],
      'lodging': ['полег', '=легла', '=легли'],
    },
  };

  static const List<String> _leafSubjects = [
    'лист', 'ботв', 'растен', 'куст', 'всход', 'стебл', 'барг',
  ];
  static const List<String> _soilSubjects = [
    'почв', 'почьв', 'земл', 'грунт', 'грядк', 'поле', 'поля', 'участ',
    '=хок', 'хоки', 'замин',
  ];
  static const List<String> _growthSubjects = ['рост', 'раст', 'развит', 'всход'];

  /// «Сухой» относится и к почве, и к листьям — решает предмет в той же
  /// части фразы.
  static const List<String> _dryRoots = [
    'сух', 'пересох', 'пересых', 'сохн', 'засох', 'засых', 'усых',
    'потрескал', 'трещин', 'засух', 'пожух', 'побурел', 'буре', '=хушк',
    'хушкид', 'хушкшуд',
  ];
  static const List<String> _dryPlantRoots = [
    'сохн', 'засох', 'засых', 'усых', 'пожух', 'побурел', 'буре', 'хушкид',
  ];
  static const List<String> _wetRoots = [
    'мокр', 'сыр', 'переувлажн', 'залит', 'луж', 'болот', 'затоп', 'подтоп',
    'заболоч', '=тар', 'намнок',
    // «Влажная почва» — описание; «влажность почвы 15%» — замер, поэтому
    // только точные формы прилагательного.
    '=влажная', '=влажный', '=влажное', '=влажные', '=влажно',
  ];
  static const List<String> _healthyRoots = ['здоров', 'зелен', 'хорош'];
  static const List<String> _weakRoots = ['слаб', 'плохо', 'медлен', '=суст'];

  static const Set<String> _negations = {'не', 'нет', 'без', 'ни', 'нест'};

  /// Совпадение слова с корнем. Корни от 6 букв допускают одну опечатку
  /// (замена, пропуск или лишняя буква в начале слова).
  static bool matches(String token, String root) {
    if (root.startsWith('=')) {
      return token == root.substring(1);
    }
    if (token.startsWith(root)) {
      return true;
    }
    if (root.length < 6 || token.length < root.length - 1) {
      return false;
    }

    for (final length in [root.length - 1, root.length, root.length + 1]) {
      if (length <= token.length &&
          _distance(token.substring(0, length), root) <= 1) {
        return true;
      }
    }
    return false;
  }

  static bool matchesAny(String token, List<String> roots) =>
      roots.any((root) => matches(token, root));

  /// Расстояние Левенштейна (короткие строки).
  static int _distance(String a, String b) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        current[j] = [
          previous[j] + 1,
          current[j - 1] + 1,
          previous[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      previous = current;
    }
    return previous[b.length];
  }

  static const List<String> _hedges = [
    'кажет', 'вроде', 'похоже', 'наверн', 'возможн', 'может', 'видимо',
  ];

  static final RegExp _clauseBreak = RegExp(r'[,.;!?\n]| но | а ');

  static final RegExp _moisture = RegExp(
    r'влажн\S*\s+(?:почв\S*\s+)?(?:около\s+|примерно\s+)?(\d{1,3})\s*%'
    r'|(\d{1,3})\s*%\s+влажн',
  );

  FieldObservation interpret(
    String text, {
    required DateTime date,
    String? fieldCropId,
  }) {
    final normalized = TextFeatures.normalize(text);
    final hedged = normalized.split(' ').any(
          (token) => _hedges.any(token.startsWith),
        );

    final facts = <ObservedFact>[];

    // Фраза делится на части по знакам препинания и союзам: признак
    // связывается с предметом только внутри своей части.
    final clauses = text
        .toLowerCase()
        .replaceAll('ё', 'е')
        .split(_clauseBreak)
        .map(TextFeatures.normalize)
        .where((clause) => clause.isNotEmpty);

    for (final clause in clauses) {
      final tokens = clause.split(' ');

      bool any(List<String> roots) =>
          tokens.any((token) => matchesAny(token, roots));

      void add(ObservationAttribute attribute, String value) {
        final exists = facts.any(
          (fact) => fact.attribute == attribute && fact.value == value,
        );
        if (!exists) {
          facts.add(
            ObservedFact(
              attribute: attribute,
              value: value,
              source: EvidenceSource.farmerReport,
              status: EvidenceStatus.observed,
              quote: clause,
              hedged: hedged,
            ),
          );
        }
      }

      /// Отрицание рядом со словом: «не сухая», «вредителей нет».
      bool negated(int index) {
        for (var i = index - 2; i <= index + 1; i++) {
          if (i >= 0 &&
              i < tokens.length &&
              i != index &&
              _negations.contains(tokens[i])) {
            return true;
          }
        }
        return false;
      }

      final leafSubject = any(_leafSubjects);
      final soilSubject = any(_soilSubjects);

      for (var index = 0; index < tokens.length; index++) {
        final token = tokens[index];
        bool starts(List<String> roots) => matchesAny(token, roots);

        _lexicon.forEach((attribute, values) {
          values.forEach((value, roots) {
            if (!starts(roots)) {
              return;
            }
            if (negated(index)) {
              // Явное отрицание имеет смысл только для вредителей.
              // В остальных случаях отрицание не превращается
              // в противоположный факт: значение остаётся неизвестным.
              if (attribute == ObservationAttribute.pests) {
                add(attribute, 'absent');
              }
              return;
            }
            add(attribute, value);
          });
        });

        if (negated(index)) {
          continue;
        }

        if (starts(_dryRoots)) {
          final plantVerb = starts(_dryPlantRoots);
          if (leafSubject && !soilSubject) {
            add(ObservationAttribute.leaves, 'drying');
          } else if (soilSubject && !leafSubject) {
            add(ObservationAttribute.soil, 'dry');
          } else if (plantVerb) {
            add(ObservationAttribute.leaves, 'drying');
          } else {
            add(ObservationAttribute.soil, 'dry');
          }
        }

        if (starts(_wetRoots) && !(leafSubject && !soilSubject)) {
          add(ObservationAttribute.soil, 'wet');
        }

        if (starts(_healthyRoots) && leafSubject) {
          add(ObservationAttribute.leaves, 'healthy');
        }

        if (starts(_weakRoots) && any(_growthSubjects)) {
          add(ObservationAttribute.growth, 'slow');
        }
      }
    }

    final moisture = _moisture.firstMatch(normalized.replaceAll(' %', '%')) ??
        _moisture.firstMatch(text.toLowerCase());
    if (moisture != null) {
      final raw = moisture.group(1) ?? moisture.group(2)!;
      final value = double.tryParse(raw);
      if (value != null && value <= 100) {
        facts.add(
          ObservedFact(
            attribute: ObservationAttribute.soilMoisture,
            value: raw,
            source: EvidenceSource.measurement,
            status: EvidenceStatus.observed,
            quote: moisture.group(0),
          ),
        );
      }
    }

    final mentioned = mentionedCropIds(text);

    return FieldObservation(
      text: text,
      date: date,
      cropId: mentioned.isNotEmpty ? mentioned.first : fieldCropId,
      cropSource: mentioned.isNotEmpty
          ? EvidenceSource.farmerReport
          : EvidenceSource.selectedByUser,
      facts: facts,
    );
  }

  /// Культуры, названные в тексте.
  static List<String> mentionedCropIds(String text) {
    final tokens = TextFeatures.tokens(text);
    final found = <String>[];

    AssistantTraining.cropRoots.forEach((cropId, roots) {
      final hit = tokens.any((token) {
        return roots.any((root) {
          return token.startsWith(root) &&
              (root.length > 4 || token.length <= root.length + 2);
        });
      });
      if (hit) {
        found.add(cropId);
      }
    });

    return found;
  }

  // ----------------------------------------
  // Языковая модель: строгий контракт
  // ----------------------------------------

  /// Подсказка для языковой модели: вернуть только JSON по схеме.
  static String llmPrompt(String text) {
    final schema = ObservationSchema.values.entries.map((entry) {
      return '"${entry.key.name}": ${entry.value.keys.join(' | ')}';
    }).join('\n');

    return 'Извлеки из текста фермера признаки. Ответь только JSON-объектом. '
        'Используй только эти ключи и значения, пропускай то, чего нет '
        'в тексте:\n$schema\n\nТекст: $text\n\nJSON:';
  }

  /// Разбирает ответ модели. Любое отклонение от схемы — отказ целиком:
  /// неверный вывод безопасно отбрасывается, исходный текст не теряется.
  static Map<ObservationAttribute, String>? parseLlmOutput(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return null;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(raw.substring(start, end + 1));
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) {
      return null;
    }

    final result = <ObservationAttribute, String>{};

    for (final entry in decoded.entries) {
      ObservationAttribute? attribute;
      for (final candidate in ObservationSchema.values.keys) {
        if (candidate.name == entry.key) {
          attribute = candidate;
        }
      }

      final value = entry.value;
      if (value == null || value == 'unknown' || value == '') {
        continue;
      }
      if (attribute == null ||
          value is! String ||
          !ObservationSchema.isValid(attribute, value)) {
        return null;
      }

      result[attribute] = value;
    }

    return result;
  }

  /// О каких предметах фермер действительно написал.
  static bool _mentions(ObservationAttribute attribute, String text) {
    final roots = switch (attribute) {
      ObservationAttribute.leaves => _leafSubjects,
      ObservationAttribute.soil => _soilSubjects,
      ObservationAttribute.growth => _growthSubjects,
      _ => const <String>[],
    };
    return TextFeatures.tokens(text).any(
      (token) => matchesAny(token, roots),
    );
  }

  /// Добавляет к наблюдению признаки от модели со статусом
  /// «предположение».
  ///
  /// Модель может дополнить только то, о чём фермер сам написал (листья,
  /// почва, рост), но не нашлось в словаре. Признак о предмете, которого
  /// нет в тексте, отбрасывается: маленькая модель склонна выдумывать.
  static FieldObservation mergeLlm(
    FieldObservation observation,
    Map<ObservationAttribute, String> fromModel,
  ) {
    final facts = [...observation.facts];

    fromModel.forEach((attribute, value) {
      // Модель не может спорить с тем, что уже извлечено из слов фермера.
      if (observation.of(attribute).isNotEmpty) {
        return;
      }
      if (!_mentions(attribute, observation.text)) {
        return;
      }
      facts.add(
        ObservedFact(
          attribute: attribute,
          value: value,
          source: EvidenceSource.ai,
          status: EvidenceStatus.inferred,
        ),
      );
    });

    return FieldObservation(
      text: observation.text,
      date: observation.date,
      cropId: observation.cropId,
      cropSource: observation.cropSource,
      facts: facts,
    );
  }
}
