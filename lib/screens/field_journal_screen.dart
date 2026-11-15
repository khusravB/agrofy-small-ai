
import 'package:material_ui/material_ui.dart';

import '../models/field.dart';
import '../models/field_event.dart';
import '../services/database_service.dart';

class FieldJournalScreen extends StatefulWidget {
  final Field field;

  const FieldJournalScreen({
    super.key,
    required this.field,
  });

  @override
  State<FieldJournalScreen> createState() =>
      _FieldJournalScreenState();
}

class _FieldJournalScreenState extends State<FieldJournalScreen> {
  List<FieldEvent> _events = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    if (widget.field.id == null) {
      setState(() {
        _isLoading = false;
        _error = 'У участка отсутствует ID';
      });
      return;
    }

    try {
      final events = await DatabaseService.instance
          .getFieldEvents(widget.field.id!);

      if (!mounted) return;

      setState(() {
        _events = events;
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _addEvent() async {
    final event = await showDialog<FieldEvent>(
      context: context,
      builder: (_) => _EventDialog(
        fieldId: widget.field.id!,
      ),
    );

    if (event == null) return;

    try {
      await DatabaseService.instance.insertFieldEvent(event);
      await _loadEvents();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Событие сохранено'),
        ),
      );
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _editEvent(FieldEvent event) async {
    final updatedEvent = await showDialog<FieldEvent>(
      context: context,
      builder: (_) => _EventDialog(
        fieldId: widget.field.id!,
        event: event,
      ),
    );

    if (updatedEvent == null) return;

    try {
      await DatabaseService.instance.updateFieldEvent(
        updatedEvent,
      );
      await _loadEvents();
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _deleteEvent(FieldEvent event) async {
    if (event.id == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить событие?'),
        content: Text('Удалить "${event.title}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await DatabaseService.instance.deleteFieldEvent(event.id!);
      await _loadEvents();
    } catch (e) {
      _showError(e);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Ошибка: $error'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Журнал участка'),
        actions: [
          IconButton(
            onPressed: _loadEvents,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addEvent,
        icon: const Icon(Icons.add),
        label: const Text('Добавить запись'),
      ),
      body: Column(
        children: [
          _buildFieldHeader(),
          Expanded(
            child: _buildJournal(),
          ),
        ],
      ),
    );
  }

  Widget _buildFieldHeader() {
    return Card(
      margin: const EdgeInsets.all(16),
      child: ListTile(
        leading: const CircleAvatar(
          child: Icon(Icons.agriculture),
        ),
        title: Text(
          widget.field.name,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          '${widget.field.crop} • ${widget.field.area} га',
        ),
      ),
    );
  }

  Widget _buildJournal() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Ошибка загрузки: $_error'),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _loadEvents,
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }

    if (_events.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.event_note,
                size: 64,
                color: Colors.grey,
              ),
              SizedBox(height: 16),
              Text(
                'Журнал пока пуст',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Добавляйте записи о посадке, поливе, '
                'удобрениях и состоянии растений.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadEvents,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
        itemCount: _events.length,
        itemBuilder: (context, index) {
          final event = _events[index];

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: ListTile(
              leading: CircleAvatar(
                child: Icon(_eventIcon(event.type)),
              ),
              title: Text(
                event.title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_eventTypeName(event.type)),
                    const SizedBox(height: 4),
                    Text(_formatDate(event.date)),
                    if (event.description.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(event.description),
                    ],
                    if (event.quantity != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Количество: ${event.quantity} '
                        '${event.unit ?? ''}',
                      ),
                    ],
                  ],
                ),
              ),
              isThreeLine: true,
              trailing: PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'edit') {
                    _editEvent(event);
                  } else if (value == 'delete') {
                    _deleteEvent(event);
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text('Редактировать'),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Удалить'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  IconData _eventIcon(FieldEventType type) {
    switch (type) {
      case FieldEventType.planting:
        return Icons.grass;
      case FieldEventType.irrigation:
        return Icons.water_drop;
      case FieldEventType.fertilization:
        return Icons.science;
      case FieldEventType.observation:
        return Icons.visibility;
      case FieldEventType.pestOrDisease:
        return Icons.bug_report;
      case FieldEventType.stageChange:
        return Icons.timeline;
    }
  }

  String _eventTypeName(FieldEventType type) {
    switch (type) {
      case FieldEventType.planting:
        return 'Посадка';
      case FieldEventType.irrigation:
        return 'Полив';
      case FieldEventType.fertilization:
        return 'Удобрение';
      case FieldEventType.observation:
        return 'Наблюдение';
      case FieldEventType.pestOrDisease:
        return 'Вредители и болезни';
      case FieldEventType.stageChange:
        return 'Этап культуры';
    }
  }

  String _formatDate(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');

    return '$day.$month.${date.year}';
  }
}

// --------------------------------------------------
// EVENT FORM
// --------------------------------------------------

class _EventDialog extends StatefulWidget {
  final int fieldId;
  final FieldEvent? event;

  const _EventDialog({
    required this.fieldId,
    this.event,
  });

  @override
  State<_EventDialog> createState() => _EventDialogState();
}

class _EventDialogState extends State<_EventDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _titleController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _quantityController;
  late final TextEditingController _unitController;

  late FieldEventType _type;
  late DateTime _date;

  bool get _isEditing => widget.event != null;

  @override
  void initState() {
    super.initState();

    final event = widget.event;

    _titleController = TextEditingController(
      text: event?.title ?? '',
    );

    _descriptionController = TextEditingController(
      text: event?.description ?? '',
    );

    _quantityController = TextEditingController(
      text: event?.quantity?.toString() ?? '',
    );

    _unitController = TextEditingController(
      text: event?.unit ?? '',
    );

    _type = event?.type ?? FieldEventType.observation;
    _date = event?.date ?? DateTime.now();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _quantityController.dispose();
    _unitController.dispose();

    super.dispose();
  }

  double? _parseQuantity() {
    final text = _quantityController.text.trim();

    if (text.isEmpty) return null;

    return double.tryParse(
      text.replaceAll(',', '.'),
    );
  }

  String? _validateQuantity(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }

    final number = double.tryParse(
      value.trim().replaceAll(',', '.'),
    );

    if (number == null ||
        !number.isFinite ||
        number < 0) {
      return 'Введите корректное количество';
    }

    return null;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final event = FieldEvent(
      id: widget.event?.id,
      fieldId: widget.fieldId,
      type: _type,
      title: _titleController.text.trim(),
      description: _descriptionController.text.trim(),
      date: _date,
      quantity: _parseQuantity(),
      unit: _unitController.text.trim().isEmpty
          ? null
          : _unitController.text.trim(),
    );

    Navigator.pop(context, event);
  }

  Future<void> _selectDate() async {
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(
        const Duration(days: 365),
      ),
    );

    if (selectedDate != null) {
      setState(() {
        _date = DateTime(
          selectedDate.year,
          selectedDate.month,
          selectedDate.day,
          _date.hour,
          _date.minute,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        _isEditing ? 'Редактировать запись' : 'Новое событие',
      ),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<FieldEventType>(
                  initialValue: _type,
                  decoration: const InputDecoration(
                    labelText: 'Тип события',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: FieldEventType.planting,
                      child: Text('Посадка'),
                    ),
                    DropdownMenuItem(
                      value: FieldEventType.irrigation,
                      child: Text('Полив'),
                    ),
                    DropdownMenuItem(
                      value: FieldEventType.fertilization,
                      child: Text('Удобрение'),
                    ),
                    DropdownMenuItem(
                      value: FieldEventType.observation,
                      child: Text('Наблюдение'),
                    ),
                    DropdownMenuItem(
                      value: FieldEventType.pestOrDisease,
                      child: Text('Вредители и болезни'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _type = value;
                      });
                    }
                  },
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: _titleController,
                  decoration: const InputDecoration(
                    labelText: 'Название события *',
                    hintText: 'Например, Полив пшеницы',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Введите название события';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: _descriptionController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Описание',
                    hintText: 'Дополнительная информация...',
                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: _quantityController,
                  keyboardType:
                      const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Количество (необязательно)',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateQuantity,
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: _unitController,
                  decoration: const InputDecoration(
                    labelText: 'Единица измерения',
                    hintText: 'Например, литр, кг, га',
                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 12),

                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
                  title: const Text('Дата события'),
                  subtitle: Text(
                    '${_date.day.toString().padLeft(2, '0')}.'
                    '${_date.month.toString().padLeft(2, '0')}.'
                    '${_date.year}',
                  ),
                  trailing: const Icon(Icons.edit_calendar),
                  onTap: _selectDate,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
