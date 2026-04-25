import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'location_service.dart';
import 'websocket_service.dart';
import 'tts_service.dart';

/// Navigation state for the UI.
enum NavigationState {
  inactive,
  fetchingRoute,
  active,
  arrived,
  error,
}

/// Manages live walking navigation with continuous GPS updates.
class NavigationService extends ChangeNotifier {
  final LocationService locationService;
  final WebSocketService webSocketService;
  final TtsService ttsService;

  NavigationState _state = NavigationState.inactive;
  String _destination = '';
  Map<String, dynamic>? _routeData;
  String _currentInstruction = '';
  String _distanceRemaining = '';
  int _currentStep = 0;
  int _totalSteps = 0;
  String _errorMessage = '';
  Timer? _locationPollTimer;

  // Getters
  NavigationState get state => _state;
  String get destination => _destination;
  Map<String, dynamic>? get routeData => _routeData;
  String get currentInstruction => _currentInstruction;
  String get distanceRemaining => _distanceRemaining;
  int get currentStep => _currentStep;
  int get totalSteps => _totalSteps;
  String get errorMessage => _errorMessage;
  bool get isNavigating => _state == NavigationState.active;
  String get staticMapUrl => _routeData?['static_map_url'] ?? '';

  NavigationService({
    required this.locationService,
    required this.webSocketService,
    required this.ttsService,
  });

  /// Start navigation to a destination.
  /// Fetches the route from the backend, then enters continuous guidance mode.
  Future<bool> startNavigation(String destination, String sessionId) async {
    if (destination.trim().isEmpty) {
      _errorMessage = 'Please provide a destination.';
      ttsService.speak(_errorMessage);
      notifyListeners();
      return false;
    }

    _setState(NavigationState.fetchingRoute);
    _destination = destination;
    ttsService.speak('Finding route to $destination');

    try {
      // 1. Get current location
      final location = await locationService.getCurrentLocation();
      if (location == null) {
        _errorMessage = 'Could not get your current location. Please enable GPS.';
        ttsService.speak(_errorMessage);
        _setState(NavigationState.error);
        return false;
      }

      // 2. Ask backend to fetch route
      final baseUrl = webSocketService.httpBaseUrl;
      final response = await http.post(
        Uri.parse('$baseUrl/api/navigate/start'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'session_id': sessionId,
          'destination': destination,
          'latitude': location['latitude'],
          'longitude': location['longitude'],
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _routeData = data['route'];
        _currentStep = _routeData?['current_step_index'] ?? 0;
        _totalSteps = _routeData?['total_steps'] ?? 0;
        _currentInstruction = _routeData?['current_step']?['instruction'] ?? '';
        _distanceRemaining = _routeData?['total_distance'] ?? '';

        final duration = _routeData?['total_duration'] ?? 'unknown';
        ttsService.speak(
          'Route found. Total distance: $_distanceRemaining, '
          'estimated time: $duration. '
          'Starting navigation now. $_currentInstruction',
        );

        _setState(NavigationState.active);

        // 3. Start continuous location polling (every 5 seconds)
        _startLocationPolling();
        return true;
      } else {
        final errorData = jsonDecode(response.body);
        _errorMessage = errorData['detail'] ?? 'Could not find a route.';
        ttsService.speak(_errorMessage);
        _setState(NavigationState.error);
        return false;
      }
    } catch (e) {
      debugPrint('❌ Navigation start failed: $e');
      _errorMessage = 'Failed to start navigation. Check your connection.';
      ttsService.speak(_errorMessage);
      _setState(NavigationState.error);
      return false;
    }
  }

  /// Stop active navigation.
  Future<void> stopNavigation(String sessionId) async {
    _locationPollTimer?.cancel();
    _locationPollTimer = null;

    try {
      final baseUrl = webSocketService.httpBaseUrl;
      await http.post(
        Uri.parse('$baseUrl/api/navigate/stop'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'session_id': sessionId}),
      );
    } catch (e) {
      debugPrint('⚠️ Stop navigation request failed: $e');
    }

    ttsService.speak('Navigation stopped.');
    _setState(NavigationState.inactive);
    _routeData = null;
    _destination = '';
    _currentInstruction = '';
  }

  /// Repeat the current instruction.
  void repeatCurrentInstruction() {
    if (_state == NavigationState.active && _currentInstruction.isNotEmpty) {
      ttsService.speak('Current step: $_currentInstruction. Distance remaining: $_distanceRemaining.');
    } else if (_state == NavigationState.arrived) {
      ttsService.speak('You have arrived at your destination.');
    } else {
      ttsService.speak('No active navigation instruction.');
    }
  }

  /// Called when the backend sends [NAV_ARRIVED].
  void handleArrival() {
    _locationPollTimer?.cancel();
    ttsService.speak(
      'You have arrived at your destination, $_destination. '
      'Navigation complete.',
    );
    _setState(NavigationState.arrived);
  }

  /// Continuously poll GPS to keep location data fresh for the backend.
  void _startLocationPolling() {
    _locationPollTimer?.cancel();
    _locationPollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) async {
        if (_state != NavigationState.active) return;
        // Location is attached to each WebSocket message in FusionEngine,
        // so we just need to make sure the service stays active.
        final loc = await locationService.getCurrentLocation();
        if (loc != null) {
          debugPrint('📍 Nav GPS: ${loc['latitude']}, ${loc['longitude']} heading: ${loc['heading']}');
        }
      },
    );
  }

  void _setState(NavigationState s) {
    _state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _locationPollTimer?.cancel();
    super.dispose();
  }
}
