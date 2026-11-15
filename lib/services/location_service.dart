
import 'package:geolocator/geolocator.dart';

class LocationService {
  // Проверка доступности GPS и разрешений
  Future<Position> getCurrentLocation() async {
    final serviceEnabled =
        await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      throw Exception(
        'Геолокация отключена. Включи GPS на устройстве.',
      );
    }

    LocationPermission permission =
        await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw Exception(
        'Доступ к геолокации отклонён.',
      );
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception(
        'Доступ запрещён навсегда. Разреши геолокацию в настройках приложения.',
      );
    }

    return await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );
  }
}
