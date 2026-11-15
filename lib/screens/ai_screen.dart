import 'package:material_ui/material_ui.dart';

import '../ai/climate_pattern_model.dart';
import '../ai/farm_assistant.dart';
import '../app_events.dart';
import '../data/crop_catalog.dart';
import '../models/climate_summary.dart';
import '../models/crop_season.dart';
import '../models/farmer_priorities.dart';
import '../models/field.dart';
import '../models/terrain_info.dart';
import '../services/database_service.dart';
import '../services/nasa_power_service.dart';
import '../services/rotation_advisor.dart';
import '../services/terrain_service.dart';
import 'assistant_chat.dart';

const _green = Color(0xFF276749);

/// Small AI: офлайн-советник по севообороту.
class AIScreen extends StatefulWidget {
  const AIScreen({super.key});

  @override
  State<AIScreen> createState() => _AIScreenState();
}

class _AIScreenState extends State<AIScreen> {
  static const _advisor = RotationAdvisor();
  static const _patternModel = ClimatePatternModel();

  final _db = DatabaseService.instance;
  final _power = NasaPowerService();
  final _terrainService = TerrainService();

  bool _loading = true;
  List<Field> _fields = const [];
  Field? _field;

  ClimateSummary? _climate;
  ClimatePatterns? _patterns;
  TerrainInfo? _terrain;
  bool _climateLoading = false;
  String? _climateError;

  /// Год → запись жизненного цикла культуры.
  Map<int, CropSeason> _history = {};
  FarmerPriorities _priorities = const FarmerPriorities();

  double _rainFactor = 1.0;
  double _tempDelta = 0.0;

  List<int> get _historyYears {
    final year = DateTime.now().year;
    return [year - 2, year - 1, year];
  }

  @override
  void initState() {
    super.initState();
    dataRevision.addListener(_loadFields);
    _loadFields();
  }

  @override
  void dispose() {
    dataRevision.removeListener(_loadFields);
    super.dispose();
  }

  Future<void> _loadFields() async {
    if (_fields.isEmpty) {
      setState(() => _loading = true);
    }

    try {
      final fields = await _db.getFields();
      if (!mounted) {
        return;
      }

      Field? selected;
      for (final field in fields) {
        if (field.id == _field?.id) {
          selected = field;
        }
      }
      selected ??= fields.isEmpty ? null : fields.first;

      setState(() {
        _fields = fields;
        _loading = false;
      });

      await _selectField(selected);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _loading = false);
      _showMessage('Не удалось загрузить участки: $error');
    }
  }

  Future<void> _selectField(Field? field) async {
    if (field?.id == null) {
      setState(() {
        _field = null;
        _climate = null;
        _patterns = null;
        _terrain = null;
        _history = {};
      });
      return;
    }

    final id = field!.id!;
    final sameField = _field?.id == id;
    final climate = await _db.getCachedClimate(id);
    final history = await _db.getClimateHistory(id);
    final terrain = await _db.getTerrain(id);
    final seasons = await _db.getCropSeasons(id);
    final priorities = await _db.getPriorities(id);

    if (!mounted) {
      return;
    }

    setState(() {
      _field = field;
      _climate = climate;
      // Модель типов лет обучается на устройстве при открытии участка.
      _patterns = history == null ? null : _patternModel.train(history);
      _terrain = terrain;
      _climateError = null;
      _history = {for (final season in seasons) season.year: season};
      _priorities = priorities;
      if (!sameField) {
        _rainFactor = 1.0;
        _tempDelta = 0.0;
      }
    });
  }

  Future<void> _fetchClimate() async {
    final field = _field;
    final latitude = field?.latitude;
    final longitude = field?.longitude;

    if (field?.id == null || latitude == null || longitude == null) {
      return;
    }

    setState(() {
      _climateLoading = true;
      _climateError = null;
    });

    final id = field!.id!;

    try {
      final climate = await _power.fetchClimatology(
        latitude: latitude,
        longitude: longitude,
      );
      await _db.saveClimate(id, climate);

      if (!mounted) {
        return;
      }
      setState(() => _climate = climate);

      // История и рельеф — дополнительные данные: если они не загрузились,
      // советник продолжает работать на климатологии.
      var partial = false;

      try {
        final history = await _power.fetchHistory(
          latitude: latitude,
          longitude: longitude,
        );
        await _db.saveClimateHistory(id, history);
        if (mounted) {
          setState(() {
                  _patterns = _patternModel.train(history);
          });
        }
      } on Object {
        partial = true;
      }

      try {
        final terrain = await _terrainService.fetch(
          latitude: latitude,
          longitude: longitude,
        );
        await _db.saveTerrain(id, terrain);
        if (mounted) {
          setState(() => _terrain = terrain);
        }
      } on Object {
        partial = true;
      }

      if (partial && mounted) {
        setState(() {
          _climateError = 'Климат загружен, но история по годам или рельеф '
              'не получены. Повторите позже — советник пока работает '
              'без них.';
        });
      }
      notifyDataChanged();
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() {
        _climateError = _climate == null
            ? 'Не удалось загрузить данные NASA POWER. Проверьте '
                'интернет и повторите — после первой загрузки советник '
                'работает офлайн.'
            : 'Обновить не удалось — используются сохранённые данные.';
      });
    } finally {
      if (mounted) {
        setState(() => _climateLoading = false);
      }
    }
  }

  Future<void> _setHistory(int year, String? cropId) async {
    final id = _field?.id;
    if (id == null) {
      return;
    }

    final season = cropId == null
        ? null
        : (_history[year]?.copyWith(cropId: cropId) ??
            CropSeason(
              fieldId: id,
              year: year,
              cropId: cropId,
              stage: year < DateTime.now().year
                  ? CropStage.harvested
                  : CropStage.planned,
            ));

    setState(() {
      if (season == null) {
        _history.remove(year);
      } else {
        _history[year] = season;
      }
    });

    if (season == null) {
      await _db.deleteCropSeason(id, year);
    } else {
      await _db.saveCropSeason(season);
    }
  }

  Future<void> _setStage(int year, CropStage stage) async {
    final season = _history[year]?.copyWith(stage: stage);
    if (season == null) {
      return;
    }

    setState(() => _history[year] = season);
    await _db.saveCropSeason(season);
  }

  void _setPriorities(FarmerPriorities priorities) {
    setState(() => _priorities = priorities);

    final id = _field?.id;
    if (id != null) {
      _db.savePriorities(id, priorities);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  AdvisorResult _advise(Field field) {
    final years = _history.keys.toList()..sort();

    return _advisor.advise(
      field: field,
      historyCropIds: [for (final year in years) _history[year]!.cropId],
      climate: _climate?.adjusted(
        rainFactor: _rainFactor,
        tempDelta: _tempDelta,
      ),
      priorities: _priorities,
      // Сценарий «что если» сдвигает климатологию; типы лет считаются
      // по фактической истории, поэтому в сценарии не используются.
      patterns: _rainFactor == 1.0 && _tempDelta == 0.0 ? _patterns : null,
      terrain: _terrain,
    );
  }

  AssistantContext _assistantContext() {
    final field = _field;

    return AssistantContext(
      field: field,
      result: field == null ? null : _advise(field),
      climate: _climate,
      patterns: _patterns,
      terrain: _terrain,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'AGROFY AI',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          actions: [
            IconButton(
              tooltip: 'Обновить список участков',
              onPressed: _loadFields,
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: const TabBar(
            labelColor: _green,
            indicatorColor: _green,
            tabs: [
              Tab(text: 'Советник'),
              Tab(text: 'Вопросы'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildBody(),
            AssistantChat(contextProvider: _assistantContext),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final field = _field;

    if (_fields.isEmpty || field == null) {
      return const _EmptyState();
    }

    final result = _advise(field);
    final best = result.best;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Советник по севообороту',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        const Text(
          'Сравнивает ваш севооборот с альтернативами по климату NASA, '
          'свойствам участка и вашим приоритетам. Работает без сети.',
          style: TextStyle(color: Colors.black54, height: 1.4),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<int>(
          key: ValueKey('field-${field.id}'),
          initialValue: field.id,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Участок',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final item in _fields)
              DropdownMenuItem(
                value: item.id,
                child: Text(
                  '${item.name} · ${item.crop}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (id) {
            _selectField(_fields.firstWhere((item) => item.id == id));
          },
        ),
        if (result.region != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.place_outlined, size: 16, color: _green),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${result.region!.name}: культуры подобраны под регион',
                  style: const TextStyle(color: _green, fontSize: 13),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        _buildClimateCard(field),
        _buildHistoryCard(field),
        _buildPrioritiesCard(),
        if (_climate != null) _buildScenarioCard(),
        if (result.insights.isNotEmpty)
          _Section(
            icon: Icons.insights,
            title: 'Что видно по участку',
            child: _Bullets(result.insights),
          ),
        if (result.blocker != null)
          _Section(
            icon: Icons.info_outline,
            title: 'Нужны данные',
            child: Text(result.blocker!, style: const TextStyle(height: 1.4)),
          ),
        if (result.strategies.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text(
            'Сравнение стратегий',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          for (final strategy in result.strategies)
            _StrategyCard(
              strategy: strategy,
              isBest: identical(strategy, best),
            ),
        ],
        const SizedBox(height: 8),
        const _Disclaimer(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildClimateCard(Field field) {
    final climate = _climate;
    final hasCoordinates = field.latitude != null && field.longitude != null;

    return _Section(
      icon: Icons.satellite_alt,
      title: 'Данные NASA по участку',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!hasCoordinates)
            const Text(
              'У участка нет координат. Укажите их в карточке участка, '
              'чтобы загрузить климат. Пока оценка идёт по справочнику.',
              style: TextStyle(height: 1.4),
            )
          else if (climate == null)
            const Text(
              'Данные ещё не загружены. Нужен интернет один раз — затем '
              'они хранятся на устройстве.',
              style: TextStyle(height: 1.4),
            )
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Stat('Осадки', '${climate.annualPrecipMm.round()} мм/год'),
                _Stat('Испарение', '${climate.annualEt0Mm.round()} мм/год'),
                _Stat(
                  'Заморозки',
                  '${climate.annualFrostDays.round()} дн./год',
                ),
                if (_terrain != null)
                  _Stat(
                    'Уклон (SRTM)',
                    '${_terrain!.slopePercent.toStringAsFixed(1)}%',
                  ),
              ],
            ),
            if (_patterns != null) ...[
              const SizedBox(height: 10),
              _YearTypesBar(patterns: _patterns!),
            ],
            const SizedBox(height: 8),
            Text(
              'Сохранено на устройстве '
              '${_formatDate(climate.fetchedAt)}. Многолетние средние.',
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
          ],
          if (_climateError != null) ...[
            const SizedBox(height: 8),
            Text(
              _climateError!,
              style: const TextStyle(color: Color(0xFFB45309), height: 1.4),
            ),
          ],
          if (hasCoordinates) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _climateLoading ? null : _fetchClimate,
              icon: _climateLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_download_outlined),
              label: Text(
                climate == null ? 'Загрузить данные NASA' : 'Обновить данные',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHistoryCard(Field field) {
    return _Section(
      icon: Icons.history,
      title: 'Что росло на участке',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Укажите культуры по годам — это ваш текущий севооборот. '
            'Если оставить пустым, берётся культура из карточки участка.',
            style: TextStyle(color: Colors.black54, height: 1.4),
          ),
          const SizedBox(height: 12),
          for (final year in _historyYears)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DropdownButtonFormField<String?>(
                key: ValueKey('history-${field.id}-$year'),
                initialValue: _history[year]?.cropId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: '$year год',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Не указано'),
                  ),
                  for (final crop in CropCatalog.mainCrops)
                    DropdownMenuItem<String?>(
                      value: crop.id,
                      child: Text(crop.name),
                    ),
                ],
                onChanged: (cropId) => _setHistory(year, cropId),
              ),
            ),
          if (_history[_historyYears.last] != null) ...[
            const SizedBox(height: 4),
            Text(
              'Этап в ${_historyYears.last} году',
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final stage in CropStage.values)
                  ChoiceChip(
                    label: Text(stage.label),
                    selected: _history[_historyYears.last]!.stage == stage,
                    onSelected: (_) => _setStage(_historyYears.last, stage),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPrioritiesCard() {
    final p = _priorities;

    return _Section(
      icon: Icons.tune,
      title: 'Ваши приоритеты',
      child: Column(
        children: [
          _LabeledSlider(
            label: 'Экономия воды',
            value: p.water,
            onChanged: (v) => _setPriorities(p.copyWith(water: v)),
          ),
          _LabeledSlider(
            label: 'Здоровье почвы',
            value: p.soil,
            onChanged: (v) => _setPriorities(p.copyWith(soil: v)),
          ),
          _LabeledSlider(
            label: 'Доход',
            value: p.income,
            onChanged: (v) => _setPriorities(p.copyWith(income: v)),
          ),
          _LabeledSlider(
            label: 'Устойчивость к погоде',
            value: p.resilience,
            onChanged: (v) => _setPriorities(p.copyWith(resilience: v)),
          ),
        ],
      ),
    );
  }

  Widget _buildScenarioCard() {
    final rainPercent = ((_rainFactor - 1) * 100).round();

    return _Section(
      icon: Icons.science_outlined,
      title: 'Сценарий «что если»',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _LabeledSlider(
            label: 'Осадки',
            valueLabel: '${rainPercent > 0 ? '+' : ''}$rainPercent%',
            value: _rainFactor,
            min: 0.6,
            max: 1.2,
            divisions: 12,
            onChanged: (v) => setState(() => _rainFactor = v),
          ),
          _LabeledSlider(
            label: 'Температура',
            valueLabel: '+${_tempDelta.toStringAsFixed(1)} °C',
            value: _tempDelta,
            min: 0,
            max: 3,
            divisions: 6,
            onChanged: (v) => setState(() => _tempDelta = v),
          ),
          const Text(
            'Сценарий — упрощённый сдвиг многолетних средних, а не прогноз.',
            style: TextStyle(color: Colors.black54, fontSize: 13),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(date.day)}.${two(date.month)}.${date.year}';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy, size: 48, color: _green),
            SizedBox(height: 16),
            Text(
              'Советник по севообороту',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              'Добавьте участок на вкладке «Поля» и нажмите «Обновить» — '
              'советник сравнит для него варианты севооборота.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _Section({
    required this.icon,
    required this.title,
    required this.child,
  });

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

class _Stat extends StatelessWidget {
  final String label;
  final String value;

  const _Stat(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF4EE),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.black54, fontSize: 12),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  final String label;
  final String? valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  const _LabeledSlider({
    required this.label,
    this.valueLabel,
    required this.value,
    this.min = 0,
    this.max = 1,
    this.divisions = 10,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text(
              valueLabel ?? '${(value * 100).round()}%',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          activeColor: _green,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _Bullets extends StatelessWidget {
  final List<String> items;

  const _Bullets(this.items);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(
                  child: Text(item, style: const TextStyle(height: 1.4)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StrategyCard extends StatelessWidget {
  final RotationStrategy strategy;
  final bool isBest;

  const _StrategyCard({required this.strategy, required this.isBest});

  @override
  Widget build(BuildContext context) {
    final scores = strategy.scores;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isBest ? _green : Colors.transparent,
          width: 2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strategy.title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (isBest)
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Text(
                            'Лучше всего отвечает вашим приоритетам',
                            style: TextStyle(color: _green, fontSize: 13),
                          ),
                        ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${strategy.total.round()}',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: _green,
                      ),
                    ),
                    const Text(
                      'из 100',
                      style: TextStyle(color: Colors.black54, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              strategy.sequenceLabel,
              style: const TextStyle(fontWeight: FontWeight.w600, height: 1.4),
            ),
            const SizedBox(height: 4),
            Text(
              'Полив: около ${strategy.avgIrrigationMm.round()} мм/год · '
              'голое поле: ${strategy.avgBareMonths.toStringAsFixed(1)} '
              'мес./год',
              style: const TextStyle(color: Colors.black54, fontSize: 13),
            ),
            const SizedBox(height: 12),
            _ScoreBar('Вода', scores.water),
            _ScoreBar('Почва', scores.soil),
            _ScoreBar('Вредители', scores.pestBreak),
            _ScoreBar('Доход', scores.income),
            _ScoreBar('Устойчивость', scores.resilience),
            if (strategy.yearOutcomes.isNotEmpty) ...[
              const SizedBox(height: 6),
              _YearOutcomes(outcomes: strategy.yearOutcomes),
            ],
            _Details('Почему предложено', strategy.why, expanded: true),
            _Details('На каких данных', strategy.evidence),
            _Details('Возможные выгоды', strategy.benefits),
            _Details('Чего не хватает в данных', strategy.gaps),
            _Details('Что проверить с агрономом', strategy.risks),
          ],
        ),
      ),
    );
  }
}

class _ScoreBar extends StatelessWidget {
  final String label;
  final double score;

  const _ScoreBar(this.label, this.score);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (score / 100).clamp(0.0, 1.0),
                minHeight: 8,
                color: _green,
                backgroundColor: const Color(0xFFE2E8E4),
              ),
            ),
          ),
          SizedBox(
            width: 34,
            child: Text(
              '${score.round()}',
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _Details extends StatelessWidget {
  final String title;
  final List<String> items;
  final bool expanded;

  const _Details(this.title, this.items, {this.expanded = false});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        children: [_Bullets(items)],
      ),
    );
  }
}

class _Disclaimer extends StatelessWidget {
  const _Disclaimer();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.handshake_outlined, color: Color(0xFFB45309)),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Советник показывает закономерности и варианты, но не заменяет '
              'ваш опыт и местного агронома. Спутниковые и модельные данные '
              'описывают район в среднем, а не конкретное поле: сверяйте '
              'выводы с анализом почвы и наблюдениями на месте.',
              style: TextStyle(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

/// Доли засушливых, обычных и влажных лет по модели типов лет.
class _YearTypesBar extends StatelessWidget {
  final ClimatePatterns patterns;

  const _YearTypesBar({required this.patterns});

  static const _colors = {
    YearKind.dry: Color(0xFFD97706),
    YearKind.normal: Color(0xFF9CA3AF),
    YearKind.wet: Color(0xFF2563EB),
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Типы лет за ${patterns.firstYear}–${patterns.lastYear} '
          '(модель обучена на устройстве)',
          style: const TextStyle(color: Colors.black54, fontSize: 13),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Row(
            children: [
              for (final type in patterns.yearTypes)
                Expanded(
                  flex: (type.share * 1000).round().clamp(1, 1000),
                  child: Container(height: 10, color: _colors[type.kind]),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final type in patterns.yearTypes)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _colors[type.kind],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '${type.label.split(' ').first} '
                    '${(type.share * 100).round()}%',
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// Как стратегия ведёт себя в годы разных типов.
class _YearOutcomes extends StatelessWidget {
  final List<YearTypeOutcome> outcomes;

  const _YearOutcomes({required this.outcomes});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF3F0),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'В разные годы',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 4),
          for (final outcome in outcomes)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${outcome.type.label}: оценка ${outcome.total.round()}, '
                'полив около ${outcome.irrigationMm.round()} мм',
                style: const TextStyle(fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}
