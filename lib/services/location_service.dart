import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

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

  /// Get current precise location and address
  Future<Map<String, dynamic>?> getCurrentLocation() async {
    if (!_isAvailable) return null;
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high
      );
      
      String address = '';
      try {
        List<Placemark> placemarks = await placemarkFromCoordinates(position.latitude, position.longitude);
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          address = '${p.street}, ${p.locality}, ${p.postalCode}'.replaceAll(RegExp(r'^, |, $'), '').trim();
        }
      } catch (e) {
        debugPrint('❌ Reverse Geocoding failed: $e');
      }

      return {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'heading': position.heading, // Useful for Walk Assist
        'speed': position.speed,
        'address': address,
      };
    } catch (e) {
      debugPrint('❌ Failed to get location: $e');
      return null;
    }
  }
}
