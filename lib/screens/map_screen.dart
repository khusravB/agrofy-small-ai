
import 'package:material_ui/material_ui.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../app_events.dart';
import '../models/climate_summary.dart';
import '../models/field.dart';
import '../services/database_service.dart';
import 'field_details_screen.dart';

/// Слой наблюдений NASA из сервиса GIBS (нужен интернет).
class _NasaLayer {
  final String label;
  final String id;
  final String matrixSet;
  final int maxZoom;
  final String hint;

  const _NasaLayer({
    required this.label,
    required this.id,
    required this.matrixSet,
    required this.maxZoom,
    required this.hint,
  });

  String get urlTemplate =>
      'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/$id/default/'
      'default/$matrixSet/{z}/{y}/{x}.png';
}

const _nasaLayers = [
  _NasaLayer(
    label: 'NDVI',
    id: 'MODIS_Terra_L3_NDVI_16Day',
    matrixSet: 'GoogleMapsCompatible_Level9',
    maxZoom: 9,
    hint: 'MODIS: густота зелени. Тёмно-зелёный — здоровая растительность, '
        'бежевый — голая почва.',
  ),
  _NasaLayer(
    label: 'Влажность почвы',
    id: 'SMAP_L4_Analyzed_Root_Zone_Soil_Moisture',
    matrixSet: 'GoogleMapsCompatible_Level6',
    maxZoom: 6,
    hint: 'SMAP: влажность корнеобитаемого слоя. Синий — влажно, '
        'коричневый — сухо. Ячейка около 9 км.',
  ),
  _NasaLayer(
    label: 'Осадки',
    id: 'IMERG_Precipitation_Rate',
    matrixSet: 'GoogleMapsCompatible_Level6',
    maxZoom: 6,
    hint: 'GPM IMERG: интенсивность осадков за последние сутки.',
  ),
  _NasaLayer(
    label: 'Температура',
    id: 'MODIS_Terra_Land_Surface_Temp_Day',
    matrixSet: 'GoogleMapsCompatible_Level7',
    maxZoom: 7,
    hint: 'MODIS: дневная температура поверхности. Красный — жарко: '
        'зоны теплового стресса.',
  ),
];

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  List<Field> _fields = [];
  bool _isLoading = true;
  String? _error;

  /// Выбранный слой NASA; null — только подложка.
  _NasaLayer? _layer;

  /// Климат участков из локального кэша — для цвета маркеров.
  Map<int, ClimateSummary> _climates = {};

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

  /// Цвет маркера по водному стрессу: доля испаряемости, покрытая осадками.
  Color _markerColor(Field field) {
    final climate = _climates[field.id];
    if (climate == null) {
      return Colors.grey;
    }

    final ratio = climate.annualPrecipMm / climate.annualEt0Mm;
    if (ratio < 0.35) {
      return Colors.red;
    }
    if (ratio < 0.7) {
      return Colors.orange;
    }
    return Colors.green;
  }

  Future<void> _loadFields() async {
    try {
      final fields = await DatabaseService.instance.getFields();

      final climates = <int, ClimateSummary>{};
      for (final field in fields) {
        final id = field.id;
        if (id == null) {
          continue;
        }
        final climate = await DatabaseService.instance.getCachedClimate(id);
        if (climate != null) {
          climates[id] = climate;
        }
      }

      if (!mounted) return;

      setState(() {
        _climates = climates;
        _fields = fields;
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

  List<Field> get _fieldsWithCoordinates {
    return _fields.where((field) {
      return field.latitude != null &&
          field.longitude != null;
    }).toList();
  }

  List<LatLng> get _coordinates {
    return _fieldsWithCoordinates.map((field) {
      return LatLng(
        field.latitude!,
        field.longitude!,
      );
    }).toList();
  }

  LatLng get _initialCenter {
    final fields = _fieldsWithCoordinates;

    if (fields.isNotEmpty) {
      return LatLng(
        fields.first.latitude!,
        fields.first.longitude!,
      );
    }

    return const LatLng(38.5598, 68.7870);
  }

  void _openField(Field field) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FieldDetailsScreen(field: field),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Карта участков'),
        actions: [
          IconButton(
            onPressed: _loadFields,
            icon: const Icon(Icons.refresh),
            tooltip: 'Обновить',
          ),
        ],
      ),
      body: _buildBody(),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Ошибка загрузки: $_error'),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _loadFields,
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: _initialCenter,
            initialZoom: 12,
            initialCameraFit: _coordinates.length > 1
                ? CameraFit.coordinates(
                    coordinates: _coordinates,
                    padding: const EdgeInsets.all(70),
                    maxZoom: 15,
                  )
                : null,
          ),
          children: [
            TileLayer(
              urlTemplate:
                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.agrofy_small_ai',
            ),

            if (_layer != null)
              Opacity(
                opacity: 0.65,
                child: TileLayer(
                  key: ValueKey(_layer!.id),
                  urlTemplate: _layer!.urlTemplate,
                  maxNativeZoom: _layer!.maxZoom,
                  userAgentPackageName: 'com.example.agrofy_small_ai',
                ),
              ),

            MarkerLayer(
              markers: _fieldsWithCoordinates.map((field) {
                return Marker(
                  point: LatLng(
                    field.latitude!,
                    field.longitude!,
                  ),
                  width: 150,
                  height: 65,
                  child: GestureDetector(
                    onTap: () => _openField(field),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.location_on,
                          color: _markerColor(field),
                          size: 38,
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(6),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 4,
                              ),
                            ],
                          ),
                          child: Text(
                            field.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),

            RichAttributionWidget(
              attributions: [
                TextSourceAttribution(
                  'OpenStreetMap contributors',
                ),
                TextSourceAttribution(
                  'NASA GIBS / EOSDIS',
                ),
              ],
            ),
          ],
        ),

        Positioned(
          left: 16,
          right: 16,
          top: 16,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.landscape),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Участков на карте: '
                          '${_fieldsWithCoordinates.length}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Слои NASA (нужен интернет)',
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final layer in _nasaLayers)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(layer.label),
                              selected: _layer == layer,
                              onSelected: (selected) {
                                setState(() {
                                  _layer = selected ? layer : null;
                                });
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _layer?.hint ??
                        'Цвет маркера — водный стресс участка по климату '
                            'NASA: красный — сильный дефицит влаги, '
                            'оранжевый — умеренный, зелёный — влаги хватает, '
                            'серый — климат не загружен.',
                    style: const TextStyle(fontSize: 12, height: 1.3),
                  ),
                ],
              ),
            ),
          ),
        ),

        if (_fieldsWithCoordinates.isEmpty)
          Positioned(
            left: 20,
            right: 20,
            bottom: 24,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: const Text(
                  'Пока нет участков с GPS-координатами. '
                  'Добавьте координаты участка, чтобы увидеть '
                  'его на карте.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
