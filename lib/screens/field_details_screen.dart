
import 'package:material_ui/material_ui.dart';

import 'package:agrofy_core/models/field.dart';
import 'field_journal_screen.dart';

class FieldDetailsScreen extends StatelessWidget {
  final Field field;

  const FieldDetailsScreen({
    super.key,
    required this.field,
  });

  @override
  Widget build(BuildContext context) {
    final completedSections = [
      field.latitude != null && field.longitude != null,
      field.soilType != null ||
          field.soilPh != null ||
          field.soilMoisture != null,
      field.crop.isNotEmpty,
      field.irrigation != null &&
          field.irrigation != 'Нет данных',
    ].where((value) => value).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Field Profile'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildHeader(context),

          const SizedBox(height: 16),

          _buildProfileCompleteness(completedSections),

          const SizedBox(height: 20),

          _buildSection(
            context,
            title: 'География',
            subtitle: 'Geographical data',
            icon: Icons.public,
            children: [
              _DetailRow(
                label: 'Местоположение',
                value: field.location,
              ),
              _DetailRow(
                label: 'Широта',
                value: _format(field.latitude, '°'),
              ),
              _DetailRow(
                label: 'Долгота',
                value: _format(field.longitude, '°'),
              ),
              _DetailRow(
                label: 'Высота над уровнем моря',
                value: _format(field.elevation, ' м'),
              ),
              _DetailRow(
                label: 'Площадь',
                value: '${field.area} га',
              ),
            ],
          ),

          _buildSection(
            context,
            title: 'Почва',
            subtitle: 'Soil properties',
            icon: Icons.grass,
            children: [
              _DetailRow(
                label: 'Тип почвы',
                value: field.soilType ?? 'Не указано',
              ),
              _DetailRow(
                label: 'pH',
                value: _format(field.soilPh, ''),
              ),
              _DetailRow(
                label: 'Влажность',
                value: _format(field.soilMoisture, '%'),
              ),
            ],
          ),

          _buildSection(
            context,
            title: 'Культура',
            subtitle: 'Crop information',
            icon: Icons.agriculture,
            children: [
              _DetailRow(
                label: 'Текущая культура',
                value: field.crop,
              ),
              const _DetailRow(
                label: 'Сорт',
                value: 'Пока не добавлен',
              ),
              const _DetailRow(
                label: 'Дата посадки',
                value: 'Пока не добавлена',
              ),
              const _DetailRow(
                label: 'Стадия роста',
                value: 'Пока не определена',
              ),
            ],
          ),

          _buildSection(
            context,
            title: 'Орошение',
            subtitle: 'Irrigation',
            icon: Icons.water_drop,
            children: [
              _DetailRow(
                label: 'Тип орошения',
                value: field.irrigation ?? 'Не указано',
              ),
            ],
          ),

          _buildSection(
            context,
            title: 'Климат',
            subtitle: 'Climate information',
            icon: Icons.cloud,
            children: const [
              _DetailRow(
                label: 'Температура',
                value: 'Данные пока недоступны',
              ),
              _DetailRow(
                label: 'Осадки',
                value: 'Данные пока недоступны',
              ),
              _DetailRow(
                label: 'Влажность воздуха',
                value: 'Данные пока недоступны',
              ),
              _DetailRow(
                label: 'Солнечная радиация',
                value: 'Данные пока недоступны',
              ),
            ],
          ),

          // FIELD JOURNAL
          _buildSection(
            context,
            title: 'История участка',
            subtitle: 'Field history',
            icon: Icons.history,
            children: const [
              _DetailRow(
                label: 'Журнал событий',
                value: 'Доступен',
              ),
            ],
          ),

          Card(
            child: ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.event_note),
              ),
              title: const Text(
                'Журнал участка',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: const Text(
                'Посадки, полив, удобрения и наблюдения',
              ),
              trailing: const Icon(
                Icons.arrow_forward_ios,
                size: 16,
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => FieldJournalScreen(
                      field: field,
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 16),

          _buildDataDisclaimer(),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.agriculture,
                    size: 32,
                    color: Colors.green,
                  ),
                ),
                const Spacer(),
                const Chip(
                  avatar: Icon(
                    Icons.verified_user_outlined,
                    size: 16,
                  ),
                  label: Text('Профиль'),
                ),
              ],
            ),

            const SizedBox(height: 20),

            Text(
              field.name,
              style: Theme.of(context).textTheme.headlineSmall,
            ),

            const SizedBox(height: 8),

            Row(
              children: [
                const Icon(
                  Icons.location_on_outlined,
                  size: 18,
                  color: Colors.grey,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    field.location,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: _HeaderMetric(
                    icon: Icons.crop_square,
                    value: '${field.area}',
                    label: 'Площадь (га)',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _HeaderMetric(
                    icon: Icons.grass,
                    value: field.crop,
                    label: 'Культура',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileCompleteness(int completedSections) {
    const totalSections = 4;

    final progress = completedSections / totalSections;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Заполненность профиля',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                Text(
                  '$completedSections/$totalSections',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              borderRadius: BorderRadius.circular(8),
            ),

            const SizedBox(height: 8),

            const Text(
              'Учитываются география, почва, культура и орошение.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  color: Colors.green,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const Divider(height: 24),

            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildDataDisclaimer() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.info_outline,
                  color: Colors.orange,
                ),
                SizedBox(width: 8),
                Text(
                  'О достоверности данных',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            const Text(
              'Характеристики участка сейчас хранятся '
              'как введённые пользователем данные. '
              'Они не подтверждены лабораторными '
              'измерениями или независимыми источниками.',
            ),

            const SizedBox(height: 10),

            const Text(
              'Климатические показатели и история участка '
              'будут подключены на следующих этапах разработки.',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _format(double? value, String suffix) {
    if (value == null) return 'Не указано';
    return '$value$suffix';
  }
}

class _HeaderMetric extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _HeaderMetric({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 20,
            color: Colors.green,
          ),
          const SizedBox(height: 8),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.grey,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
