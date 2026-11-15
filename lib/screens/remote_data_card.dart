import 'dart:io';

import 'package:agrofy_core/models/field.dart';
import 'package:agrofy_core/remote/ndvi_summary.dart';
import 'package:agrofy_core/remote/sms_command.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../services/database_service.dart';
import '../services/package_importer.dart';
import '../services/sms_launcher.dart';
import 'advisor_cards.dart';

const _green = Color(0xFF276749);

/// Запрашивает номер AGROFY для SMS. Номер не встроен в приложение:
/// его выдаёт оператор сервиса.
Future<String?> askSmsNumber(BuildContext context, String? current) async {
  final controller = TextEditingController(text: current ?? '');
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Номер AGROFY для SMS'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Номер, на который сервис AGROFY принимает SMS. Его сообщает '
            'организатор сервиса (кооператив, агрослужба).',
            style: TextStyle(color: Colors.black54, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Номер',
              hintText: '+992…',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _green),
          onPressed: () {
            final value = controller.text.trim();
            if (SmsLauncher.validNumber(value)) {
              Navigator.pop(context, SmsLauncher.normalize(value));
            }
          },
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (result != null) {
    await DatabaseService.instance.setSetting(SmsLauncher.numberKey, result);
  }
  return result;
}

/// Открывает SMS с готовым текстом; если номера нет — сначала спрашивает его.
Future<void> composeSms(BuildContext context, String text) async {
  var number = await DatabaseService.instance.getSetting(SmsLauncher.numberKey);
  if (number == null) {
    if (!context.mounted) {
      return;
    }
    number = await askSmsNumber(context, null);
    if (number == null) {
      return;
    }
  }
  final opened = await SmsLauncher.open(number, text);
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Не удалось открыть приложение сообщений.')),
    );
  }
}

/// SMS-канал и спутниковые данные: регистрация поля, запрос NASA-данных
/// и импорт пакета, ссылка на который приходит по SMS.
class RemoteDataCard extends StatefulWidget {
  final Field field;
  final List<NdviPoint> ndvi;
  final int packageCount;
  final VoidCallback onImported;

  const RemoteDataCard({
    super.key,
    required this.field,
    required this.ndvi,
    required this.packageCount,
    required this.onImported,
  });

  @override
  State<RemoteDataCard> createState() => _RemoteDataCardState();
}

class _RemoteDataCardState extends State<RemoteDataCard> {
  String? _number;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    DatabaseService.instance.getSetting(SmsLauncher.numberKey).then((value) {
      if (mounted) {
        setState(() => _number = value);
      }
    });
  }

  String get _fieldId => SmsCommand.fieldIdForLocal(widget.field.id!);

  GeoPoint? get _point {
    final lat = widget.field.latitude;
    final lon = widget.field.longitude;
    return lat == null || lon == null ? null : GeoPoint(lat, lon);
  }

  Future<void> _editNumber() async {
    final value = await askSmsNumber(context, _number);
    if (value != null && mounted) {
      setState(() => _number = value);
    }
  }

  Future<void> _send(String text) async {
    await composeSms(context, text);
    final number = await DatabaseService.instance.getSetting(SmsLauncher.numberKey);
    if (mounted) {
      setState(() => _number = number);
    }
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json', 'zip'],
    );
    final path = picked?.path;
    if (path == null || !mounted) {
      return;
    }

    setState(() => _importing = true);
    final importer = PackageImporter(DatabaseService.instance);
    try {
      final preview = await importer.preview(File(path), widget.field);
      if (!mounted) {
        return;
      }
      final overwrite = await _confirm(preview);
      if (overwrite == null) {
        return;
      }
      await importer.commit(preview, widget.field, overwriteConflicts: overwrite);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Импортировано: ${preview.newCount} новых наблюдений'
            '${overwrite && preview.conflictCount > 0 ? ', заменено ${preview.conflictCount}' : ''}.',
          ),
        ),
      );
      widget.onImported();
    } on ImportFailure catch (failure) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Пакет не принят'),
            content: Text(failure.errors.join('\n')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Понятно'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  /// Сводка перед импортом. Возвращает «заменять ли отличающиеся
  /// наблюдения» или null, если пользователь отказался.
  Future<bool?> _confirm(ImportPreview preview) {
    final package = preview.package;
    String day(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
    var overwrite = false;

    return showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Импорт пакета данных'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${package.requestId} · ${package.quality.statusLabel}\n'
                  'Период: ${day(package.periodStart)} – ${day(package.periodEnd)}\n'
                  'Источники: ${package.datasets.map((d) => d.source).join(', ')}',
                  style: const TextStyle(height: 1.4),
                ),
                const SizedBox(height: 10),
                Text(
                  'Новых наблюдений: ${preview.newCount}\n'
                  'Уже есть: ${preview.duplicateCount}\n'
                  'Отличаются от сохранённых: ${preview.conflictCount}',
                  style: const TextStyle(height: 1.4),
                ),
                if (preview.alreadyImported)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Этот пакет уже импортирован — дубликаты не появятся.',
                      style: TextStyle(color: Colors.black54),
                    ),
                  ),
                if (preview.warnings.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  for (final (i, warning) in preview.warnings.indexed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '• $warning',
                        style: TextStyle(
                          height: 1.3,
                          color: i < preview.mismatchWarnings
                              ? const Color(0xFFB45309)
                              : Colors.black87,
                        ),
                      ),
                    ),
                ],
                if (preview.conflictCount > 0)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: overwrite,
                    onChanged: (v) => setDialog(() => overwrite = v ?? false),
                    title: const Text('Заменить отличающиеся наблюдения'),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _green),
              onPressed: () => Navigator.pop(context, overwrite),
              child: Text(preview.fieldMismatch ? 'Всё равно импортировать' : 'Импортировать'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final point = _point;
    final summary = NdviSummary.of(widget.ndvi);

    return AdvisorCard(
      icon: Icons.sms_outlined,
      title: 'SMS и спутниковые данные',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Без интернета: запрос уходит обычным SMS, сервер AGROFY берёт '
            'данные NASA и присылает SMS со ссылкой на файл. Отправляете вы '
            'сами; SMS — по тарифу оператора.',
            style: TextStyle(color: Colors.black54, height: 1.4),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _number == null ? 'Номер AGROFY не указан' : 'Номер AGROFY: $_number',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: _editNumber,
                child: Text(_number == null ? 'Указать' : 'Изменить'),
              ),
            ],
          ),
          Text('ID поля для SMS: $_fieldId'),
          const SizedBox(height: 8),
          if (point == null)
            const Text(
              'Укажите координаты участка, чтобы зарегистрировать его и '
              'запрашивать спутниковые данные.',
              style: TextStyle(color: Color(0xFFB45309)),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton(
                  onPressed: () => _send(
                    SmsCommand.formatRegister(_fieldId, point, crop: widget.field.crop),
                  ),
                  child: const Text('Зарегистрировать поле'),
                ),
                OutlinedButton(
                  onPressed: () => _send(SmsCommand.formatInfo(_fieldId)),
                  child: const Text('Всё о поле'),
                ),
                OutlinedButton(
                  onPressed: () => _send(
                    SmsCommand.formatRequest(fieldId: _fieldId, kind: DataRequestKind.ndvi),
                  ),
                  child: const Text('NDVI за 90 дней'),
                ),
                OutlinedButton(
                  onPressed: () => _send(
                    SmsCommand.formatRequest(fieldId: _fieldId, kind: DataRequestKind.climate),
                  ),
                  child: const Text('Климат за год'),
                ),
              ],
            ),
          const SizedBox(height: 4),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _green),
            onPressed: _importing ? null : _import,
            icon: _importing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_download_outlined),
            label: const Text('Импортировать пакет'),
          ),
          if (widget.packageCount > 0 || summary != null) ...[
            const SizedBox(height: 8),
            Text(
              'Импортировано пакетов: ${widget.packageCount}.'
              '${summary == null ? '' : ' ${summary.describe()}'}',
              style: const TextStyle(color: Colors.black54, fontSize: 13, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }
}
