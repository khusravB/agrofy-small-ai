import 'dart:math' as math;

import 'text_features.dart';

class IntentPrediction {
  final String intent;

  /// Уверенность модели, 0–1.
  final double confidence;

  const IntentPrediction(this.intent, this.confidence);
}

/// Small AI №2: классификатор намерений вопроса.
///
/// Мультиномиальный наивный байесовский классификатор по основам слов и
/// символьным триграммам. Обучается на устройстве за миллисекунды на
/// встроенных примерах вопросов, работает без сети и занимает килобайты.
class IntentClassifier {
  final Map<String, Map<String, int>> _counts = {};
  final Map<String, int> _totals = {};
  final Map<String, int> _documents = {};
  final Set<String> _vocabulary = {};
  int _documentCount = 0;

  IntentClassifier();

  factory IntentClassifier.trained(Map<String, List<String>> examples) {
    final classifier = IntentClassifier();
    examples.forEach((intent, phrases) {
      for (final phrase in phrases) {
        classifier.learn(intent, phrase);
      }
    });
    return classifier;
  }

  void learn(String intent, String phrase) {
    final counts = _counts.putIfAbsent(intent, () => {});

    for (final feature in TextFeatures.features(phrase)) {
      counts[feature] = (counts[feature] ?? 0) + 1;
      _totals[intent] = (_totals[intent] ?? 0) + 1;
      _vocabulary.add(feature);
    }

    _documents[intent] = (_documents[intent] ?? 0) + 1;
    _documentCount++;
  }

  List<String> get intents => _counts.keys.toList();

  IntentPrediction? predict(String text) {
    final features = TextFeatures.features(text)
        .where(_vocabulary.contains)
        .toList();

    if (features.isEmpty || _documentCount == 0) {
      return null;
    }

    final scores = <String, double>{};
    final vocabularySize = _vocabulary.length;

    _counts.forEach((intent, counts) {
      var score = math.log(_documents[intent]! / _documentCount);
      final total = _totals[intent] ?? 0;

      for (final feature in features) {
        score += math.log(
          ((counts[feature] ?? 0) + 0.5) / (total + 0.5 * vocabularySize),
        );
      }

      // Средняя лог-вероятность на признак: длинные вопросы не должны
      // давать ложную сверхуверенность.
      scores[intent] = score / features.length;
    });

    final best = scores.entries.reduce((a, b) => b.value > a.value ? b : a);

    // Softmax с «температурой» переводит оценки в уверенность.
    var sum = 0.0;
    for (final value in scores.values) {
      sum += math.exp((value - best.value) * 4);
    }

    return IntentPrediction(best.key, 1 / sum);
  }
}
