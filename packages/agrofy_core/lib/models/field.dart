
class Field {
  final int? id;

  final String name;
  final String location;
  final double area;
  final String crop;

  final double? latitude;
  final double? longitude;

  final String? soilType;
  final double? soilPh;
  final double? soilMoisture;

  final String? irrigation;
  final double? elevation;

  const Field({
    this.id,
    required this.name,
    required this.location,
    required this.area,
    required this.crop,
    this.latitude,
    this.longitude,
    this.soilType,
    this.soilPh,
    this.soilMoisture,
    this.irrigation,
    this.elevation,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'location': location,
      'area': area,
      'crop': crop,
      'latitude': latitude,
      'longitude': longitude,
      'soil_type': soilType,
      'soil_ph': soilPh,
      'soil_moisture': soilMoisture,
      'irrigation': irrigation,
      'elevation': elevation,
    };
  }

  factory Field.fromMap(Map<String, dynamic> map) {
    return Field(
      id: map['id'] as int?,
      name: map['name'] as String,
      location: map['location'] as String,
      area: (map['area'] as num).toDouble(),
      crop: map['crop'] as String,
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      soilType: map['soil_type'] as String?,
      soilPh: (map['soil_ph'] as num?)?.toDouble(),
      soilMoisture: (map['soil_moisture'] as num?)?.toDouble(),
      irrigation: map['irrigation'] as String?,
      elevation: (map['elevation'] as num?)?.toDouble(),
    );
  }
}
