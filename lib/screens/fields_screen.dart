
import 'package:material_ui/material_ui.dart';

import 'package:agrofy_core/models/field.dart';
import '../services/database_service.dart';
import '../services/location_service.dart';
import 'field_details_screen.dart';

class FieldsScreen extends StatefulWidget {
  const FieldsScreen({super.key});

  @override
  State<FieldsScreen> createState() => _FieldsScreenState();
}

class _FieldsScreenState extends State<FieldsScreen> {
  List<Field> _fields = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFields();
  }

  Future<void> _loadFields() async {
    try {
      final fields = await DatabaseService.instance.getFields();

      if (!mounted) return;

      setState(() {
        _fields = fields;
        _isLoading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _addField() async {
    final field = await showDialog<Field>(
      context: context,
      builder: (context) => const _FieldDialog(),
    );

    if (field == null) return;

    try {
      await DatabaseService.instance.insertField(field);
      await _loadFields();
    } catch (e) {
      _showMessage('Ошибка сохранения: $e');
    }
  }

  Future<void> _editField(Field field) async {
    final updatedField = await showDialog<Field>(
      context: context,
      builder: (context) => _FieldDialog(field: field),
    );

    if (updatedField == null) return;

    try {
      await DatabaseService.instance.updateField(updatedField);
      await _loadFields();
    } catch (e) {
      _showMessage('Ошибка обновления: $e');
    }
  }

  Future<void> _deleteField(Field field) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить участок?'),
        content: Text(
          'Вы действительно хотите удалить "${field.name}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Удалить',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || field.id == null) return;

    try {
      await DatabaseService.instance.deleteField(field.id!);
      await _loadFields();
    } catch (e) {
      _showMessage('Ошибка удаления: $e');
    }
  }

  Future<void> _openFieldDetails(Field field) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FieldDetailsScreen(field: field),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Мои участки'),
        actions: [
          IconButton(
            onPressed: _loadFields,
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addField,
        icon: const Icon(Icons.add),
        label: const Text('Добавить участок'),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text(
                'Не удалось загрузить участки:\n$_error',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadFields,
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }

    if (_fields.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.landscape_outlined,
                size: 64,
                color: Colors.grey,
              ),
              const SizedBox(height: 16),
              const Text(
                'У вас пока нет участков',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Добавьте первый участок, чтобы начать работу.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _addField,
                icon: const Icon(Icons.add),
                label: const Text('Добавить участок'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFields,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        itemCount: _fields.length,
        itemBuilder: (context, index) {
          final field = _fields[index];

          return Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _openFieldDetails(field),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.landscape,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            field.name,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => _editField(field),
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: 'Редактировать',
                        ),
                        IconButton(
                          onPressed: () => _deleteField(field),
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                          ),
                          tooltip: 'Удалить',
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _FieldInfoRow(
                      icon: Icons.location_on_outlined,
                      text: field.location,
                    ),
                    const SizedBox(height: 6),
                    _FieldInfoRow(
                      icon: Icons.crop_square,
                      text: '${field.area} га',
                    ),
                    const SizedBox(height: 6),
                    _FieldInfoRow(
                      icon: Icons.grass,
                      text: field.crop,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Нажмите, чтобы посмотреть подробности',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FieldInfoRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _FieldInfoRow({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}

// --------------------------------------------------
// FIELD FORM
// --------------------------------------------------

class _FieldDialog extends StatefulWidget {
  final Field? field;

  const _FieldDialog({this.field});

  @override
  State<_FieldDialog> createState() => _FieldDialogState();
}

class _FieldDialogState extends State<_FieldDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _locationController;
  late final TextEditingController _areaController;

  late final TextEditingController _latitudeController;
  late final TextEditingController _longitudeController;
  late final TextEditingController _elevationController;

  late final TextEditingController _soilPhController;
  late final TextEditingController _soilMoistureController;

  String _crop = 'Пшеница';
  String _soilType = 'Суглинистая';
  String _irrigation = 'Нет данных';

  bool _isGettingLocation = false;

  bool get _isEditing => widget.field != null;

  @override
  void initState() {
    super.initState();

    final field = widget.field;

    _nameController = TextEditingController(
      text: field?.name ?? '',
    );

    _locationController = TextEditingController(
      text: field?.location ?? '',
    );

    _areaController = TextEditingController(
      text: field?.area.toString() ?? '',
    );

    _latitudeController = TextEditingController(
      text: field?.latitude?.toString() ?? '',
    );

    _longitudeController = TextEditingController(
      text: field?.longitude?.toString() ?? '',
    );

    _elevationController = TextEditingController(
      text: field?.elevation?.toString() ?? '',
    );

    _soilPhController = TextEditingController(
      text: field?.soilPh?.toString() ?? '',
    );

    _soilMoistureController = TextEditingController(
      text: field?.soilMoisture?.toString() ?? '',
    );

    const crops = [
      'Пшеница',
      'Кукуруза',
      'Хлопок',
      'Рис',
      'Картофель',
      'Овощи',
      'Фрукты',
      'Другое',
    ];

    const soilTypes = [
      'Песчаная',
      'Супесчаная',
      'Суглинистая',
      'Глинистая',
      'Чернозём',
      'Другое',
    ];

    const irrigationTypes = [
      'Нет данных',
      'Капельное',
      'Дождевальное',
      'Поверхностное',
      'Без орошения',
    ];

    if (field != null) {
      if (crops.contains(field.crop)) {
        _crop = field.crop;
      }

      if (field.soilType != null &&
          soilTypes.contains(field.soilType)) {
        _soilType = field.soilType!;
      }

      if (field.irrigation != null &&
          irrigationTypes.contains(field.irrigation)) {
        _irrigation = field.irrigation!;
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    _areaController.dispose();

    _latitudeController.dispose();
    _longitudeController.dispose();
    _elevationController.dispose();

    _soilPhController.dispose();
    _soilMoistureController.dispose();

    super.dispose();
  }

  double? _parseOptionalNumber(String value) {
    if (value.trim().isEmpty) return null;

    return double.tryParse(
      value.trim().replaceAll(',', '.'),
    );
  }

  String? _validateNumber(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }

    final number = _parseOptionalNumber(value);

    if (number == null || !number.isFinite) {
      return 'Введите корректное число';
    }

    return null;
  }

  String? _validateArea(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Введите площадь участка';
    }

    final number = _parseOptionalNumber(value);

    if (number == null || !number.isFinite || number <= 0) {
      return 'Площадь должна быть больше 0';
    }

    return null;
  }

  String? _validateLatitude(String? value) {
    final error = _validateNumber(value);
    if (error != null) return error;

    if (value == null || value.trim().isEmpty) {
      return null;
    }

    final number = _parseOptionalNumber(value)!;

    if (number < -90 || number > 90) {
      return 'Широта должна быть от -90 до 90';
    }

    return null;
  }

  String? _validateLongitude(String? value) {
    final error = _validateNumber(value);
    if (error != null) return error;

    if (value == null || value.trim().isEmpty) {
      return null;
    }

    final number = _parseOptionalNumber(value)!;

    if (number < -180 || number > 180) {
      return 'Долгота должна быть от -180 до 180';
    }

    return null;
  }

  String? _validatePh(String? value) {
    final error = _validateNumber(value);
    if (error != null) return error;

    if (value == null || value.trim().isEmpty) {
      return null;
    }

    final number = _parseOptionalNumber(value)!;

    if (number < 0 || number > 14) {
      return 'pH должен быть от 0 до 14';
    }

    return null;
  }

  String? _validateMoisture(String? value) {
    final error = _validateNumber(value);
    if (error != null) return error;

    if (value == null || value.trim().isEmpty) {
      return null;
    }

    final number = _parseOptionalNumber(value)!;

    if (number < 0 || number > 100) {
      return 'Влажность должна быть от 0 до 100%';
    }

    return null;
  }

  Future<void> _getCurrentLocation() async {
    setState(() {
      _isGettingLocation = true;
    });

    try {
      final position =
          await LocationService().getCurrentLocation();

      if (!mounted) return;

      setState(() {
        _latitudeController.text =
            position.latitude.toStringAsFixed(6);

        _longitudeController.text =
            position.longitude.toStringAsFixed(6);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Координаты успешно определены!'),
        ),
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.toString().replaceFirst('Exception: ', ''),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isGettingLocation = false;
        });
      }
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final latitudeText = _latitudeController.text.trim();
    final longitudeText = _longitudeController.text.trim();

    if (latitudeText.isEmpty != longitudeText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Укажите и широту, и долготу либо оставьте оба поля пустыми.',
          ),
        ),
      );
      return;
    }

    final field = Field(
      id: widget.field?.id,
      name: _nameController.text.trim(),
      location: _locationController.text.trim(),
      area: _parseOptionalNumber(_areaController.text)!,
      crop: _crop,
      latitude: _parseOptionalNumber(latitudeText),
      longitude: _parseOptionalNumber(longitudeText),
      elevation: _parseOptionalNumber(
        _elevationController.text,
      ),
      soilType: _soilType,
      soilPh: _parseOptionalNumber(
        _soilPhController.text,
      ),
      soilMoisture: _parseOptionalNumber(
        _soilMoistureController.text,
      ),
      irrigation: _irrigation,
    );

    Navigator.pop(context, field);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        _isEditing ? 'Редактировать участок' : 'Новый участок',
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionTitle('Основная информация'),

                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Название участка *',
                    hintText: 'Например, Участок №1',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Введите название участка';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: _locationController,
                  decoration: const InputDecoration(
                    labelText: 'Местоположение *',
                    hintText: 'Город, район, село',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Укажите местоположение';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: _areaController,
                  keyboardType:
                      const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Площадь (га) *',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateArea,
                ),

                const SizedBox(height: 12),

                DropdownButtonFormField<String>(
                  initialValue: _crop,
                  decoration: const InputDecoration(
                    labelText: 'Культура',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    'Пшеница',
                    'Кукуруза',
                    'Хлопок',
                    'Рис',
                    'Картофель',
                    'Овощи',
                    'Фрукты',
                    'Другое',
                  ].map((crop) {
                    return DropdownMenuItem(
                      value: crop,
                      child: Text(crop),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _crop = value;
                      });
                    }
                  },
                ),

                const SizedBox(height: 20),

                const _SectionTitle('Географические данные'),

                TextFormField(
                  controller: _latitudeController,
                  keyboardType:
                      const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Широта (Latitude)',
                    hintText: 'Например, 40.2833',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateLatitude,
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: _longitudeController,
                  keyboardType:
                      const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Долгота (Longitude)',
                    hintText: 'Например, 69.6333',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateLongitude,
                ),

                const SizedBox(height: 12),

                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _isGettingLocation
                        ? null
                        : _getCurrentLocation,
                    icon: _isGettingLocation
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.my_location),
                    label: Text(
                      _isGettingLocation
                          ? 'Определяем местоположение...'
                          : 'Определить координаты GPS',
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: _elevationController,
                  keyboardType:
                      const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Высота над уровнем моря (м)',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateNumber,
                ),

                const SizedBox(height: 20),

                const _SectionTitle('Характеристики почвы'),

                DropdownButtonFormField<String>(
                  initialValue: _soilType,
                  decoration: const InputDecoration(
                    labelText: 'Тип почвы',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    'Песчаная',
                    'Супесчаная',
                    'Суглинистая',
                    'Глинистая',
                    'Чернозём',
                    'Другое',
                  ].map((soil) {
                    return DropdownMenuItem(
                      value: soil,
                      child: Text(soil),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _soilType = value;
                      });
                    }
                  },
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: _soilPhController,
                  keyboardType:
                      const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'pH почвы (0–14)',
                    hintText: 'Например, 6.5',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validatePh,
                ),

                const SizedBox(height: 12),

                TextFormField(
                  controller: _soilMoistureController,
                  keyboardType:
                      const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Влажность почвы (%)',
                    hintText: 'Например, 35',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateMoisture,
                ),

                const SizedBox(height: 20),

                const _SectionTitle('Орошение'),

                DropdownButtonFormField<String>(
                  initialValue: _irrigation,
                  decoration: const InputDecoration(
                    labelText: 'Тип орошения',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    'Нет данных',
                    'Капельное',
                    'Дождевальное',
                    'Поверхностное',
                    'Без орошения',
                  ].map((irrigation) {
                    return DropdownMenuItem(
                      value: irrigation,
                      child: Text(irrigation),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _irrigation = value;
                      });
                    }
                  },
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
        ElevatedButton.icon(
          onPressed: _save,
          icon: const Icon(Icons.save),
          label: const Text('Сохранить'),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
