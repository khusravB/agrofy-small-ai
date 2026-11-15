import 'package:material_ui/material_ui.dart';

import '../ai/local_llm.dart';
import '../app_events.dart';
import 'package:agrofy_core/data/crop_catalog.dart';
import 'package:agrofy_core/decision/crop_lifecycle.dart';
import 'package:agrofy_core/decision/decision_engine.dart';
import 'package:agrofy_core/decision/evidence_validator.dart';
import 'package:agrofy_core/decision/observation.dart';
import 'package:agrofy_core/decision/observation_interpreter.dart';
import 'package:agrofy_core/decision/saved_observation.dart';
import 'package:agrofy_core/models/climate_summary.dart';
import 'package:agrofy_core/models/crop_season.dart';
import 'package:agrofy_core/models/field.dart';
import 'package:agrofy_core/models/field_event.dart';
import '../services/database_service.dart';

const _green = Color(0xFF276749);
const _amber = Color(0xFFB45309);

/// Наблюдение фермера → признаки → проверка данных → решение → план.
///
/// Экран только собирает ввод и показывает результат: правила живут
/// в слое `decision`.
class ObservationTab extends StatefulWidget {
  final Field? field;
  final ClimateSummary? climate;

  const ObservationTab({super.key, required this.field, this.climate});

  @override
  State<ObservationTab> createState() => _ObservationTabState();
}

class _ObservationTabState extends State<ObservationTab>
    with AutomaticKeepAliveClientMixin {
  static const _interpreter = ObservationInterpreter();
  static const _validator = EvidenceValidator();
  static const _engine = DecisionEngine();

  /// Примеры для быстрого ввода: подпись и текст наблюдения.
  static const _examples = [
    ('Желтеют листья', 'Листья желтеют, почва сухая, последние дни жарко'),
    ('С замером', 'Листья вянут, влажность почвы 15%'),
    ('Вредители', 'На листьях пятна и тля'),
  ];

  final _db = DatabaseService.instance;
  final _controller = TextEditingController();

  List<FieldEvent> _events = const [];
  List<SavedObservation> _saved = const [];
  CropSeason? _season;

  EvidenceReport? _report;
  Recommendation? _recommendation;
  bool _modelWorking = false;
  bool _savedCurrent = false;

  @override
  bool get wantKeepAlive => true;

  int get _year => DateTime.now().year;

  @override
  void initState() {
    super.initState();
    dataRevision.addListener(_load);
    _load();
  }

  @override
  void didUpdateWidget(ObservationTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.field?.id != widget.field?.id) {
      _report = null;
      _recommendation = null;
      _load();
    }
  }

  @override
  void dispose() {
    dataRevision.removeListener(_load);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final id = widget.field?.id;
    if (id == null) {
      return;
    }

    try {
      final events = await _db.getFieldEvents(id);
      final saved = await _db.getObservations(id);
      final seasons = await _db.getCropSeasons(id);

      if (!mounted) {
        return;
      }

      CropSeason? season;
      for (final item in seasons) {
        if (item.year == _year) {
          season = item;
        }
      }

      setState(() {
        _events = events;
        _saved = saved;
        _season = season;
      });
    } on Object {
      // Без базы данных экран остаётся пустым, ввод не блокируется.
    }
  }

  EvidenceContext _context(Field field) {
    return EvidenceContext(
      field: field,
      events: _events,
      climate: widget.climate,
      stageKnown: _season != null,
    );
  }

  /// Последняя рекомендация, результат которой ещё не записан.
  SavedObservation? get _pending {
    if (_saved.isEmpty) {
      return null;
    }
    final last = _saved.first;
    return last.awaitsFollowUp ? last : null;
  }

  Future<void> _interpret() async {
    final field = widget.field;
    final text = _controller.text.trim();
    if (field == null || text.isEmpty) {
      return;
    }

    FocusScope.of(context).unfocus();

    final fieldCrop =
        _season?.cropId ?? CropCatalog.fromFieldCrop(field.crop)?.id;

    // Словарный разбор работает всегда — это запасной путь без модели.
    var observation = _interpreter.interpret(
      text,
      date: DateTime.now(),
      fieldCropId: fieldCrop,
    );

    void apply(FieldObservation value) {
      final report = _validator.validate(value, _context(field));
      setState(() {
        _report = report;
        _recommendation = _engine.decide(report);
        _savedCurrent = false;
      });
    }

    apply(observation);

    // Языковая модель, если скачана, может добавить признаки — только
    // по схеме и только как предположения.
    final llm = LocalLlm.instance;
    if (!LocalLlm.supported) {
      return;
    }
    await llm.refresh();
    if (!llm.available || !mounted) {
      return;
    }

    setState(() => _modelWorking = true);
    try {
      final buffer = StringBuffer();
      await for (final delta in llm.generate(
        system: 'Ты извлекаешь признаки из текста. Отвечай только JSON.',
        user: ObservationInterpreter.llmPrompt(text),
        maxTokens: 90,
      )) {
        buffer.write(delta);
      }

      final parsed = ObservationInterpreter.parseLlmOutput(buffer.toString());
      if (parsed != null && mounted && _controller.text.trim() == text) {
        observation = ObservationInterpreter.mergeLlm(observation, parsed);
        apply(observation);
      }
    } on Object {
      // Некорректный ответ модели отбрасывается, разбор остаётся прежним.
    } finally {
      if (mounted) {
        setState(() => _modelWorking = false);
      }
    }
  }

  Future<void> _save() async {
    final id = widget.field?.id;
    final report = _report;
    final recommendation = _recommendation;
    if (id == null || report == null || recommendation == null) {
      return;
    }

    await _db.insertObservation(
      SavedObservation.from(
        fieldId: id,
        observation: report.observation,
        recommendation: recommendation,
        followsId: _pending?.id,
      ),
    );

    if (!mounted) {
      return;
    }
    setState(() => _savedCurrent = true);
    _controller.clear();
    await _load();
  }

  Future<void> _startCycle() async {
    final field = widget.field;
    final crop = field == null ? null : CropCatalog.fromFieldCrop(field.crop);
    if (field?.id == null || crop == null) {
      return;
    }

    await _db.saveCropSeason(
      CropSeason(
        fieldId: field!.id!,
        year: _year,
        cropId: crop.id,
        stage: CropStage.planning,
      ),
    );
    notifyDataChanged();
  }

  Future<void> _advance(CropStage to) async {
    final season = _season;
    if (season == null) {
      return;
    }

    final now = DateTime.now();
    final next = CropLifecycle.advance(
      season,
      to,
      at: now,
      crop: CropCatalog.byId(season.cropId),
    );

    await _db.saveCropSeason(next);
    // Переход записывается в журнал: прошлые этапы не переписываются.
    await _db.insertFieldEvent(
      FieldEvent(
        fieldId: season.fieldId,
        type: FieldEventType.stageChange,
        title: 'Этап: ${to.label}',
        description: 'Было: ${season.stage.label}',
        date: now,
      ),
    );
    notifyDataChanged();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final field = widget.field;
    if (field == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Добавьте участок на вкладке «Поля», чтобы записывать наблюдения.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54, height: 1.4),
          ),
        ),
      );
    }

    final report = _report;
    final recommendation = _recommendation;
    final pending = _pending;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildLifecycle(field),
        _Card(
          icon: Icons.edit_note,
          title: 'Что вы видите на поле',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  hintText: 'Например: листья желтеют, почва сухая, '
                      'влажность 18%',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final example in _examples)
                    ActionChip(
                      label: Text(example.$1),
                      onPressed: () {
                        _controller.text = example.$2;
                        _interpret();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 6),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: _green),
                onPressed: _interpret,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Разобрать наблюдение'),
              ),
              if (_modelWorking) ...[
                const SizedBox(height: 8),
                const Text(
                  'Языковая модель уточняет признаки…',
                  style: TextStyle(color: Colors.black54, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
        if (report != null && recommendation != null) ...[
          _buildFacts(report),
          if (pending != null) _buildOutcome(pending, report.observation),
          _buildRecommendation(recommendation),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: OutlinedButton.icon(
              onPressed: _savedCurrent ? null : _save,
              icon: Icon(_savedCurrent ? Icons.check : Icons.save_outlined),
              label: Text(
                _savedCurrent
                    ? 'Сохранено в историю поля'
                    : 'Сохранить в историю поля',
              ),
            ),
          ),
        ],
        _buildMemory(),
      ],
    );
  }

  Widget _buildLifecycle(Field field) {
    final season = _season;
    final crop = CropCatalog.byId(season?.cropId);

    if (season == null) {
      final fieldCrop = CropCatalog.fromFieldCrop(field.crop);
      return _Card(
        icon: Icons.timeline,
        title: 'Цикл культуры $_year',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Цикл этого года ещё не начат.',
              style: TextStyle(height: 1.4),
            ),
            const SizedBox(height: 8),
            if (fieldCrop != null)
              OutlinedButton(
                onPressed: _startCycle,
                child: Text('Начать цикл: ${fieldCrop.name}'),
              )
            else
              const Text(
                'Выберите культуру года на вкладке «Советник».',
                style: TextStyle(color: Colors.black54),
              ),
          ],
        ),
      );
    }

    final next = CropLifecycle.allowedNext(season.stage, crop: crop);

    return _Card(
      icon: Icons.timeline,
      title: 'Цикл культуры $_year',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${crop?.name ?? season.cropId} · этап: ${season.stage.label}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: season.stage.index / (CropStage.values.length - 1),
              minHeight: 8,
              color: _green,
              backgroundColor: const Color(0xFFE2E8E4),
            ),
          ),
          const SizedBox(height: 10),
          if (next.isEmpty)
            const Text(
              'Цикл завершён.',
              style: TextStyle(color: Colors.black54),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final stage in next)
                  OutlinedButton(
                    onPressed: () => _advance(stage),
                    child: Text('Перейти: ${stage.label}'),
                  ),
              ],
            ),
          const SizedBox(height: 4),
          const Text(
            'Этапы идут только вперёд; каждый переход записывается в журнал.',
            style: TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildFacts(EvidenceReport report) {
    final observation = report.observation;
    final crop = CropCatalog.byId(observation.cropId);

    return _Card(
      icon: Icons.account_tree_outlined,
      title: 'Что понято из текста',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FactRow(
            label: 'Культура: ${crop?.name ?? 'не определена'}',
            source: observation.cropSource.label,
            status: crop == null
                ? EvidenceStatus.unknown
                : EvidenceStatus.observed,
          ),
          for (final fact in observation.facts)
            _FactRow(
              label: fact.label,
              source: fact.source.label,
              status: fact.status,
            ),
          if (observation.facts.isEmpty)
            const Text(
              'Признаки не выделены.',
              style: TextStyle(color: Colors.black54),
            ),
          if (report.contradictions.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Противоречия в данных',
              style: TextStyle(fontWeight: FontWeight.w600, color: _amber),
            ),
            const SizedBox(height: 4),
            for (final item in report.contradictions)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(item.message, style: const TextStyle(height: 1.4)),
              ),
          ],
          if (report.missing.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Чего не хватает',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            for (final item in report.missing)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('• $item', style: const TextStyle(height: 1.4)),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildOutcome(SavedObservation previous, FieldObservation current) {
    return _Card(
      icon: Icons.compare_arrows,
      title: 'После прошлой рекомендации',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_date(previous.date)}: «${previous.action}»',
            style: const TextStyle(fontWeight: FontWeight.w600, height: 1.4),
          ),
          const SizedBox(height: 6),
          for (final change in OutcomeReview.compare(previous, current))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $change', style: const TextStyle(height: 1.4)),
            ),
          const SizedBox(height: 4),
          const Text(
            OutcomeReview.caveat,
            style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _buildRecommendation(Recommendation r) {
    final color = r.status == DecisionStatus.ready ? _green : _amber;

    return _Card(
      icon: Icons.assignment_turned_in_outlined,
      title: 'Рекомендация',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              r.status.label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            r.action,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(r.reason, style: const TextStyle(height: 1.4)),
          _Block('На чём основано', r.evidence),
          _Block('Варианты', r.alternatives),
          _Block('Ожидаемый результат', [r.expectedOutcome]),
          const SizedBox(height: 10),
          const Text(
            'План действий',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          for (final step in r.plan)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '• ${step.title}\n  срок: ${_due(step.dueInDays)} · '
                'приоритет: ${step.priority.label} · итог: ${step.result}',
                style: const TextStyle(height: 1.4),
              ),
            ),
          const SizedBox(height: 4),
          const Text(
            'Правила составлены разработчиками и не заменяют осмотр '
            'агрономом.',
            style: TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildMemory() {
    final entries = <({DateTime date, IconData icon, String title, String text})>[
      for (final event in _events)
        (
          date: event.date,
          icon: event.type == FieldEventType.irrigation
              ? Icons.water_drop_outlined
              : event.type == FieldEventType.stageChange
                  ? Icons.timeline
                  : Icons.event_note,
          title: event.title,
          text: event.description,
        ),
      for (final item in _saved)
        (
          date: item.date,
          icon: Icons.visibility_outlined,
          title: 'Наблюдение · ${item.status.label}',
          text: '${item.text}\n→ ${item.action}',
        ),
    ]..sort((a, b) => b.date.compareTo(a.date));

    return _Card(
      icon: Icons.history_edu,
      title: 'Память поля',
      child: entries.isEmpty
          ? const Text(
              'Пока нет записей. Наблюдения, поливы и смены этапов будут '
              'появляться здесь.',
              style: TextStyle(color: Colors.black54, height: 1.4),
            )
          : Column(
              children: [
                for (final entry in entries.take(12))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(entry.icon, size: 18, color: _green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_date(entry.date)} · ${entry.title}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (entry.text.isNotEmpty)
                                Text(
                                  entry.text,
                                  style: const TextStyle(
                                    color: Colors.black54,
                                    height: 1.3,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  String _date(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(date.day)}.${two(date.month)}.${date.year}';
  }

  String _due(int days) {
    if (days == 0) {
      return 'сегодня';
    }
    return 'через $days дн.';
  }
}

class _Card extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _Card({required this.icon, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: _green, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  final String label;
  final String source;
  final EvidenceStatus status;

  const _FactRow({
    required this.label,
    required this.source,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      EvidenceStatus.observed => _green,
      EvidenceStatus.inferred => _amber,
      EvidenceStatus.unknown => Colors.grey,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 5),
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  '${status.label} · $source',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  final String title;
  final List<String> items;

  const _Block(this.title, this.items);

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('• $item', style: const TextStyle(height: 1.4)),
            ),
        ],
      ),
    );
  }
}
