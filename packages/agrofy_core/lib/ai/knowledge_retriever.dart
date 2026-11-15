import 'dart:math' as math;

import '../data/knowledge_base.dart';
import 'text_features.dart';

class RetrievedArticle {
  final KnowledgeArticle article;
  final double score;

  const RetrievedArticle(this.article, this.score);
}

/// Поиск статьи базы знаний по вопросу: ранжирование BM25 по основам слов.
/// Заголовок учитывается с тройным весом.
class KnowledgeRetriever {
  static const double _k1 = 1.4;
  static const double _b = 0.75;

  final List<KnowledgeArticle> _articles;
  final List<Map<String, int>> _termCounts = [];
  final List<int> _lengths = [];
  final Map<String, int> _documentFrequency = {};
  double _averageLength = 0;

  KnowledgeRetriever([List<KnowledgeArticle>? articles])
      : _articles = articles ?? KnowledgeBase.articles {
    for (final article in _articles) {
      final terms = [
        for (var i = 0; i < 3; i++) ...TextFeatures.stems(article.title),
        ...TextFeatures.stems(article.body),
      ];

      final counts = <String, int>{};
      for (final term in terms) {
        counts[term] = (counts[term] ?? 0) + 1;
      }

      _termCounts.add(counts);
      _lengths.add(terms.length);
      for (final term in counts.keys) {
        _documentFrequency[term] = (_documentFrequency[term] ?? 0) + 1;
      }
    }

    _averageLength = _lengths.isEmpty
        ? 0
        : _lengths.reduce((a, b) => a + b) / _lengths.length;
  }

  /// Вопросительные слова не несут смысла для поиска статьи.
  static const Set<String> _questionWords = {
    'что', 'так', 'такое', 'как', 'зачем', 'почему', 'значит', 'означа',
    'означает', 'объясн', 'объясни', 'расскаж', 'расскажи', 'про', 'нужен',
    'нужн', 'чем', 'работа', 'термин',
  };

  List<RetrievedArticle> search(String query, {int limit = 2}) {
    final terms = TextFeatures.stems(query)
        .where((term) => !_questionWords.contains(term))
        .toSet();
    final results = <RetrievedArticle>[];

    for (var i = 0; i < _articles.length; i++) {
      var score = 0.0;

      for (final term in terms) {
        final frequency = _termCounts[i][term];
        if (frequency == null) {
          continue;
        }

        final df = _documentFrequency[term]!;
        final idf = math.log(1 + (_articles.length - df + 0.5) / (df + 0.5));
        score += idf *
            frequency *
            (_k1 + 1) /
            (frequency + _k1 * (1 - _b + _b * _lengths[i] / _averageLength));
      }

      if (score > 0) {
        results.add(RetrievedArticle(_articles[i], score));
      }
    }

    results.sort((a, b) => b.score.compareTo(a.score));
    return results.take(limit).toList();
  }
}
