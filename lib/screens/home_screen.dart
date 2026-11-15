
import 'package:material_ui/material_ui.dart';

import '../app_events.dart';
import 'package:agrofy_core/models/climate_summary.dart';
import 'package:agrofy_core/models/field.dart';
import '../services/database_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Первый участок фермера и его климат из локального кэша.
  Field? _field;
  ClimateSummary? _climate;

  @override
  void initState() {
    super.initState();
    dataRevision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    dataRevision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final fields = await DatabaseService.instance.getFields();
      final field = fields.isEmpty ? null : fields.first;
      final id = field?.id;
      final climate = id == null
          ? null
          : await DatabaseService.instance.getCachedClimate(id);

      if (!mounted) {
        return;
      }
      setState(() {
        _field = field;
        _climate = climate;
      });
    } on Object {
      // Без базы данных главный экран показывает пример.
    }
  }

  @override
  Widget build(BuildContext context) {
    final field = _field;
    final climate = _climate;
    final month = DateTime.now().month - 1;
    final wetness = climate?.rootWetness;

    const green = Color(0xFF276749);
    const dark = Color(0xFF1D3025);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: green,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.eco,
                      color: Colors.white,
                      size: 27,
                    ),
                  ),
                  const SizedBox(width: 11),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AGROFY',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          color: dark,
                        ),
                      ),
                      Text(
                        'Smart Agriculture',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5F2E8),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.wifi_off, size: 15, color: green),
                        SizedBox(width: 5),
                        Text(
                          'Offline',
                          style: TextStyle(
                            color: green,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 30),

              // Greeting
              const Text(
                'Добро пожаловать!',
                style: TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w800,
                  color: dark,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Управляйте своими полями и принимайте '
                'обоснованные решения.',
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: Colors.black54,
                ),
              ),

              const SizedBox(height: 25),

              // Field card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: green,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.landscape,
                          color: Colors.white70,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'МОЁ ПОЛЕ',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            field == null ? 'Пример данных' : 'Ваш участок',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text(
                      field?.name ?? 'Участок №1',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      field?.location ?? 'Худжанд, Таджикистан',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 23),
                    const Divider(color: Colors.white30),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _FieldInfo(
                          icon: Icons.square_foot,
                          label: 'Площадь',
                          value: '${field?.area ?? 2.5} га',
                        ),
                        const SizedBox(width: 30),
                        _FieldInfo(
                          icon: Icons.grass,
                          label: 'Культура',
                          value: field?.crop ?? 'Не выбрана',
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 25),

              // Field condition
              const Text(
                'Состояние участка',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: dark,
                ),
              ),
              const SizedBox(height: 13),

              Row(
                children: [
                  Expanded(
                    child: _InfoCard(
                      icon: Icons.thermostat,
                      label: 'Температура',
                      value: climate == null
                          ? '— °C'
                          : '${climate.tMean[month].round()} °C',
                      description: climate == null
                          ? 'Нет данных'
                          : 'Норма месяца, NASA',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _InfoCard(
                      icon: Icons.water_drop_outlined,
                      label: 'Влажность',
                      value: wetness == null
                          ? '— %'
                          : '${(wetness[month] * 100).round()} %',
                      description: wetness == null
                          ? 'Нет данных'
                          : 'Почва, норма месяца',
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 25),

              // Tools
              const Text(
                'Инструменты',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: dark,
                ),
              ),
              const SizedBox(height: 13),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: const Color(0xFFE8ECE5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.analytics_outlined,
                          color: green,
                          size: 25,
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Анализ участка',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: dark,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Получите рекомендации по выращиванию '
                      'культур на основе данных вашего участка.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        // Вкладка «AI» — советник по севообороту.
                        onPressed: () => requestedTab.value = 3,
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Начать анализ'),
                        style: FilledButton.styleFrom(
                          backgroundColor: green,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),

      
      
    );
  }
}

class _FieldInfo extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _FieldInfo({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 19),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String description;

  const _InfoCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFE8ECE5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            color: const Color(0xFF276749),
            size: 23,
          ),
          const SizedBox(height: 13),
          Text(
            label,
            style: const TextStyle(
              color: Colors.black54,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFF1D3025),
              fontSize: 21,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            description,
            style: const TextStyle(
              color: Colors.black45,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
