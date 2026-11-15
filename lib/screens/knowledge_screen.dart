import 'package:material_ui/material_ui.dart';

import '../data/knowledge_base.dart';

const _green = Color(0xFF276749);

/// Офлайн-база знаний: объяснения терминов и данных NASA простым языком.
class KnowledgeScreen extends StatelessWidget {
  const KnowledgeScreen({super.key});

  static const Map<String, IconData> _icons = {
    KnowledgeBase.crops: Icons.grass,
    KnowledgeBase.irrigation: Icons.water_drop,
    KnowledgeBase.soil: Icons.terrain,
    KnowledgeBase.climate: Icons.cloud,
    KnowledgeBase.data: Icons.satellite_alt,
  };

  static const Map<String, String> _descriptions = {
    KnowledgeBase.crops: 'Севооборот, бобовые, покровные и повторные культуры.',
    KnowledgeBase.irrigation: 'Испаряемость, водный баланс и потери при поливе.',
    KnowledgeBase.soil: 'Плодородие, эрозия, кислотность и засоление.',
    KnowledgeBase.climate: 'Заморозки, типы лет и климатические тренды.',
    KnowledgeBase.data: 'Что измеряют спутники и как читать их данные.',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'База знаний',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Агрономические знания',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'Работает без интернета. Те же статьи использует помощник '
            'на вкладке «AI».',
            style: TextStyle(color: Colors.black54, height: 1.4),
          ),
          const SizedBox(height: 16),
          for (final category in KnowledgeBase.categories)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                leading: Icon(_icons[category], color: _green, size: 28),
                title: Text(
                  category,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(_descriptions[category] ?? ''),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => _CategoryScreen(category: category),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoryScreen extends StatelessWidget {
  final String category;

  const _CategoryScreen({required this.category});

  @override
  Widget build(BuildContext context) {
    final articles = KnowledgeBase.byCategory(category);

    return Scaffold(
      appBar: AppBar(title: Text(category)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final article in articles)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  title: Text(
                    article.title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(article.body, style: const TextStyle(height: 1.5)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
