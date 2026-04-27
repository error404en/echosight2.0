import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Service to fetch GPS coordinates and physical address for Emergency and Navigation protocols.
class LocationService extends ChangeNotifier {
  bool _isAvailable = false;
  bool get isAvailable => _isAvailable;

  Future<bool> initialize() async {
    try {
      bool serviceEnabled;
      LocationPermission permission;

      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('⚠️ Location services are disabled.');
        return false;
      }

      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          debugPrint('⚠️ Location permissions are denied');
          return false;
        }
      }
      
      if (permission == LocationPermission.deniedForever) {
        debugPrint('⚠️ Location permissions are permanently denied');
        return false;
      }

      _isAvailable = true;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('❌ Location init failed: $e');
      return false;
    }
  }

  /// Get current location coordinates
  Future<Map<String, dynamic>?> getCurrentLocation() async {
    if (!_isAvailable) return null;
    try {
      Position? position;
      try {
        // Use medium accuracy for much faster locks (less than 1 second)
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
        ).timeout(const Duration(seconds: 2));
      } catch (_) {
        // Fallback to last known if current times out
        position = await Geolocator.getLastKnownPosition();
      }
      
      if (position == null) {
        return null;
      }
      
      return {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'heading': position.heading,
        'speed': position.speed,
      };
    } catch (e) {
      debugPrint('❌ Failed to get location: $e');
      return null;
    }
  }
}
