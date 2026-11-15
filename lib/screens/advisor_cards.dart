import 'package:material_ui/material_ui.dart';

import 'package:agrofy_core/models/crop_economics.dart';
import 'package:agrofy_core/models/crop_profile.dart';
import 'package:agrofy_core/models/soil_profile.dart';
import 'package:agrofy_core/services/rotation_advisor.dart';
import 'package:agrofy_core/services/yield_calibration.dart';

const _green = Color(0xFF276749);

class AdvisorCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const AdvisorCard({
    super.key,
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

double? _parse(String text) =>
    double.tryParse(text.trim().replaceAll(' ', '').replaceAll(',', '.'));

String _number(double? value) {
  if (value == null) {
    return '';
  }
  return value == value.roundToDouble()
      ? value.round().toString()
      : value.toString();
}

// ----------------------------------------
// Почва участка
// ----------------------------------------

class SoilCard extends StatelessWidget {
  final SoilProfile? soil;
  final ValueChanged<SoilProfile> onSave;

  const SoilCard({super.key, required this.soil, required this.onSave});

  @override
  Widget build(BuildContext context) {
    final profile = soil;
    final filled = profile != null && !profile.isEmpty;

    return AdvisorCard(
      icon: Icons.layers_outlined,
      title: 'Почва участка',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            filled
                ? '${profile.summary().join(', ')} (${profile.sourceLabel}).'
                : 'Засоление, грунтовые воды и питание со спутника не '
                    'определить. Укажите, что знаете, — советник учтёт '
                    'солеустойчивость культур и риск подъёма солей.',
            style: const TextStyle(height: 1.4),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _edit(context),
            icon: const Icon(Icons.edit_outlined),
            label: Text(filled ? 'Изменить' : 'Заполнить'),
          ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final result = await showModalBottomSheet<SoilProfile>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SoilForm(initial: soil),
    );
    if (result != null) {
      onSave(result);
    }
  }
}

class _SoilForm extends StatefulWidget {
  final SoilProfile? initial;

  const _SoilForm({required this.initial});

  @override
  State<_SoilForm> createState() => _SoilFormState();
}

class _SoilFormState extends State<_SoilForm> {
  Salinity? _salinity;
  NutrientLevel? _nitrogen;
  NutrientLevel? _phosphorus;
  NutrientLevel? _potassium;
  bool _lab = false;
  late final TextEditingController _groundwater;
  late final TextEditingController _humus;

  @override
  void initState() {
    super.initState();
    final soil = widget.initial;
    _salinity = soil?.salinity;
    _nitrogen = soil?.nitrogen;
    _phosphorus = soil?.phosphorus;
    _potassium = soil?.potassium;
    _lab = soil?.fromLabTest ?? false;
    _groundwater = TextEditingController(text: _number(soil?.groundwaterM));
    _humus = TextEditingController(text: _number(soil?.humusPct));
  }

  @override
  void dispose() {
    _groundwater.dispose();
    _humus.dispose();
    super.dispose();
  }

  Widget _choice<T>(
    String label,
    T? value,
    List<T> values,
    String Function(T) name,
    ValueChanged<T?> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DropdownButtonFormField<T?>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          DropdownMenuItem<T?>(value: null, child: const Text('Не знаю')),
          for (final item in values)
            DropdownMenuItem<T?>(value: item, child: Text(name(item))),
        ],
        onChanged: onChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Почва участка',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Оставьте «Не знаю», если данных нет: это не то же самое, '
              'что «в норме».',
              style: TextStyle(color: Colors.black54, height: 1.4),
            ),
            const SizedBox(height: 12),
            _choice(
              'Засоление',
              _salinity,
              Salinity.values,
              (s) => '${s.label} (около ${s.ece.round()} дС/м)',
              (v) => setState(() => _salinity = v),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: _groundwater,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Глубина грунтовых вод, м',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: _humus,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Гумус, %',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            _choice(
              'Азот',
              _nitrogen,
              NutrientLevel.values,
              (n) => n.label,
              (v) => setState(() => _nitrogen = v),
            ),
            _choice(
              'Фосфор',
              _phosphorus,
              NutrientLevel.values,
              (n) => n.label,
              (v) => setState(() => _phosphorus = v),
            ),
            _choice(
              'Калий',
              _potassium,
              NutrientLevel.values,
              (n) => n.label,
              (v) => setState(() => _potassium = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('По лабораторному анализу'),
              value: _lab,
              onChanged: (v) => setState(() => _lab = v),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _green),
                onPressed: () {
                  Navigator.pop(
                    context,
                    SoilProfile(
                      salinity: _salinity,
                      groundwaterM: _parse(_groundwater.text),
                      humusPct: _parse(_humus.text),
                      nitrogen: _nitrogen,
                      phosphorus: _phosphorus,
                      potassium: _potassium,
                      fromLabTest: _lab,
                      updatedAt: DateTime.now(),
                    ),
                  );
                },
                child: const Text('Сохранить'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------
// Экономика культур
// ----------------------------------------

class EconomicsCard extends StatelessWidget {
  final List<CropProfile> crops;

  /// Введённые фермером значения.
  final Map<String, CropEconomics> entered;

  /// С урожайностью из записей фермера.
  final Map<String, CropEconomics> effective;

  final String currency;
  final ValueChanged<CropEconomics> onSave;
  final ValueChanged<String> onClear;

  const EconomicsCard({
    super.key,
    required this.crops,
    required this.entered,
    required this.effective,
    required this.currency,
    required this.onSave,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return AdvisorCard(
      icon: Icons.payments_outlined,
      title: 'Экономика культур',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Введите цену, урожайность и затраты — доход будет считаться '
            'в $currency с гектара. Без них доход — условный индекс 1–5. '
            'Встроенных цен нет.',
            style: const TextStyle(color: Colors.black54, height: 1.4),
          ),
          const SizedBox(height: 6),
          for (final crop in crops) _row(context, crop),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, CropProfile crop) {
    final item = effective[crop.id];
    final margin = item?.margin();

    String subtitle;
    if (item == null) {
      subtitle = 'не задано';
    } else {
      final parts = [
        if (item.pricePerT != null)
          'цена ${RotationAdvisor.formatMoney(item.pricePerT!, currency)}/т',
        if (item.yieldTHa != null)
          'урожай ${item.yieldTHa!.toStringAsFixed(1)} т/га'
              '${item.yieldFromRecords ? ' (ваши записи, ${item.recordYears} г.)' : ''}',
        if (item.costPerHa != null)
          'затраты ${RotationAdvisor.formatMoney(item.costPerHa!, currency)}/га',
      ];
      subtitle = parts.join(' · ');
      if (margin != null) {
        subtitle += '\nмаржа ${RotationAdvisor.formatMoney(margin, currency)}/га';
      } else {
        subtitle += '\nне хватает данных для расчёта';
      }
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(crop.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle, style: const TextStyle(height: 1.3)),
      trailing: const Icon(Icons.edit_outlined, size: 20),
      onTap: () => _edit(context, crop),
    );
  }

  Future<void> _edit(BuildContext context, CropProfile crop) async {
    final base = entered[crop.id];
    final fromRecords = effective[crop.id]?.yieldFromRecords ?? false;
    final price = TextEditingController(text: _number(base?.pricePerT));
    final yieldField = TextEditingController(text: _number(base?.yieldTHa));
    final cost = TextEditingController(text: _number(base?.costPerHa));

    InputDecoration decoration(String label) => InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        );

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(crop.name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: price,
                keyboardType: TextInputType.number,
                decoration: decoration('Цена, $currency за тонну'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: yieldField,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: decoration('Урожайность, т/га'),
              ),
              if (fromRecords)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'В расчёте используется средний урожай из ваших '
                    'записей по годам.',
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 10),
              TextField(
                controller: cost,
                keyboardType: TextInputType.number,
                decoration: decoration('Затраты, $currency на гектар'),
              ),
            ],
          ),
        ),
        actions: [
          if (base != null)
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Очистить'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _green),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );

    if (saved == true) {
      onSave(
        CropEconomics(
          cropId: crop.id,
          pricePerT: _parse(price.text),
          yieldTHa: _parse(yieldField.text),
          costPerHa: _parse(cost.text),
        ),
      );
    } else if (saved == false) {
      onClear(crop.id);
    }

    price.dispose();
    yieldField.dispose();
    cost.dispose();
  }
}

// ----------------------------------------
// Урожаи и оценки
// ----------------------------------------

class CalibrationCard extends StatelessWidget {
  final YieldCalibration calibration;

  const CalibrationCard({super.key, required this.calibration});

  @override
  Widget build(BuildContext context) {
    return AdvisorCard(
      icon: Icons.fact_check_outlined,
      title: 'Ваши урожаи и оценки',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (calibration.checks.isEmpty)
            const Text(
              'Укажите урожайность в «Что росло на участке» — советник '
              'сравнит её со своей оценкой погоды того же года.',
              style: TextStyle(height: 1.4),
            ),
          for (final check in calibration.checks)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${check.year} · ${check.crop.name}: '
                '${check.yieldTHa.toStringAsFixed(1)} т/га '
                '(${_relative(check.relativeYield)} к вашему среднему) · '
                '${check.climateFit == null ? 'нет истории погоды за год' : 'погода года подходила на ${(check.climateFit! * 100).round()}%'}',
                style: const TextStyle(height: 1.4),
              ),
            ),
          if (calibration.checks.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              calibration.verdict,
              style: const TextStyle(color: Colors.black54, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  String _relative(double value) {
    final percent = ((value - 1) * 100).round();
    return '${percent >= 0 ? '+' : '−'}${percent.abs()}%';
  }
}
