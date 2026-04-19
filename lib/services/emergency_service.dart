import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:vibration/vibration.dart';
import 'camera_service.dart';
import 'tts_service.dart';
import 'location_service.dart';
import 'websocket_service.dart';
import 'detection_service.dart';
import 'ocr_service.dart';
import 'vision_context_builder.dart';

/// Emergency state for the UI.
enum EmergencyState {
  inactive,
  active,
  scanning,
}

/// Emergency service that provides continuous hazard scanning,
/// SOS alerts, and immediate danger reporting for blind users.
class EmergencyService extends ChangeNotifier {
  final CameraService cameraService;
  final TtsService ttsService;
  final LocationService locationService;
  final WebSocketService webSocketService;
  final DetectionService detectionService;
  final OcrService ocrService;
  late final VisionContextBuilder _contextBuilder;

  EmergencyState _state = EmergencyState.inactive;
  Timer? _scanTimer;
  int _scanCount = 0;
  String _lastAlert = '';
  String _emergencyLocation = '';
  bool _sosTriggered = false;

  // Getters
  EmergencyState get state => _state;
  int get scanCount => _scanCount;
  String get lastAlert => _lastAlert;
  String get emergencyLocation => _emergencyLocation;
  bool get sosTriggered => _sosTriggered;
  bool get isActive => _state != EmergencyState.inactive;

  EmergencyService({
    required this.cameraService,
    required this.ttsService,
    required this.locationService,
    required this.webSocketService,
    required this.detectionService,
    required this.ocrService,
  }) {
    _contextBuilder = VisionContextBuilder(
      detectionService: detectionService,
      ocrService: ocrService,
    );
  }

  /// Activate emergency mode — starts continuous hazard scanning.
  Future<void> activate() async {
    if (_state != EmergencyState.inactive) return;

    _state = EmergencyState.active;
    _scanCount = 0;
    _sosTriggered = false;
    notifyListeners();

    // Strong haptic burst to confirm activation
    try {
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(pattern: [0, 200, 100, 200, 100, 500]);
      }
    } catch (_) {}

    // Announce activation
    ttsService.speak(
      'Emergency mode activated. I am now continuously scanning for dangers. '
      'Say help at any time for immediate assistance.',
    );

    // Fetch and store current GPS
    try {
      final loc = await locationService.getCurrentLocation();
      if (loc != null) {
        _emergencyLocation =
            'Lat: ${loc['latitude']?.toStringAsFixed(5)}, '
            'Lng: ${loc['longitude']?.toStringAsFixed(5)}';
      }
    } catch (_) {}

    // Start continuous scanning every 8 seconds
    _startContinuousScan();
  }

  /// Deactivate emergency mode.
  void deactivate() {
    _scanTimer?.cancel();
    _scanTimer = null;
    _state = EmergencyState.inactive;
    _sosTriggered = false;
    notifyListeners();

    ttsService.speak('Emergency mode deactivated. Returning to normal.');
  }

  /// Trigger SOS — high urgency alert with location.
  Future<void> triggerSOS() async {
    _sosTriggered = true;
    notifyListeners();

    // Strong continuous vibration
    try {
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(duration: 2000);
      }
    } catch (_) {}

    // Refresh location
    try {
      final loc = await locationService.getCurrentLocation();
      if (loc != null) {
        _emergencyLocation =
            'Lat: ${loc['latitude']?.toStringAsFixed(5)}, '
            'Lng: ${loc['longitude']?.toStringAsFixed(5)}';
      }
    } catch (_) {}

    final sosMessage =
        'SOS ALERT! I need immediate help. '
        'My location is $_emergencyLocation. '
        'If someone is nearby, please call out.';

    _lastAlert = sosMessage;
    ttsService.speak(sosMessage);
    notifyListeners();
  }

  /// Perform a single emergency scan — captures the camera frame,
  /// runs local YOLO detection, and sends it to the backend
  /// with the emergency system prompt for immediate danger assessment.
  Future<void> performScan(String sessionId) async {
    if (!webSocketService.isConnected) {
      // Offline emergency: use local detection only
      await _performOfflineScan();
      return;
    }

    _state = EmergencyState.scanning;
    _scanCount++;
    notifyListeners();

    try {
      // Capture frame
      cameraService.invalidateCache();
      final imageBase64 = await cameraService.captureFrame();

      // Build local vision context
      Map<String, dynamic>? visionContext;
      if (cameraService.isInitialized) {
        final rawFrame = await cameraService.captureRawFrame();
        if (rawFrame != null) {
          final ctx = await _contextBuilder.buildContext(rawFrame);
          visionContext = ctx.toJson();
        }
      }

      // Fetch GPS
      Map<String, double>? gpsData;
      try {
        gpsData = await locationService.getCurrentLocation();
        if (gpsData != null) {
          _emergencyLocation =
              'Lat: ${gpsData['latitude']?.toStringAsFixed(5)}, '
              'Lng: ${gpsData['longitude']?.toStringAsFixed(5)}';
        }
      } catch (_) {}

      // Send to backend with emergency mode
      webSocketService.sendMessage(
        sessionId: sessionId,
        query: 'EMERGENCY SCAN: Analyze the current view for ALL dangers, '
            'obstacles, vehicles, drop-offs, uneven ground, and threats. '
            'Report anything a blind person must know immediately.',
        imageBase64: imageBase64,
        visionContext: visionContext,
        locationData: gpsData,
        mode: 'emergency',
      );
    } catch (e) {
      debugPrint('❌ Emergency scan failed: $e');
    }

    _state = EmergencyState.active;
    notifyListeners();
  }

  /// Offline emergency scan using only local YOLO detection.
  Future<void> _performOfflineScan() async {
    _scanCount++;
    notifyListeners();

    try {
      if (cameraService.isInitialized) {
        final rawFrame = await cameraService.captureRawFrame();
        if (rawFrame != null) {
          final ctx = await _contextBuilder.buildContext(rawFrame);
          if (ctx.hasObjects) {
            final dangerKeywords = [
              'car', 'truck', 'bus', 'motorcycle', 'bicycle',
              'dog', 'cat', 'knife', 'scissors', 'fire hydrant',
            ];

            final nearbyDangers = ctx.objects
                .where((o) => dangerKeywords.contains(o.label.toLowerCase()))
                .map((o) => '${o.label} at ${o.position}')
                .toList();

            if (nearbyDangers.isNotEmpty) {
              final alert = 'Warning: ${nearbyDangers.join(', ')} detected nearby. '
                  'Please be careful.';
              _lastAlert = alert;
              ttsService.speak(alert);

              try {
                if (await Vibration.hasVibrator() ?? false) {
                  Vibration.vibrate(pattern: [0, 300, 200, 300]);
                }
              } catch (_) {}
            }
          }
        }
      }
    } catch (e) {
      debugPrint('❌ Offline scan failed: $e');
    }

    notifyListeners();
  }

  /// Start continuous auto-scanning timer.
  void _startContinuousScan() {
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) {
        if (_state != EmergencyState.inactive) {
          // Session ID will be injected by FusionEngine
          // This timer just triggers the scan loop
          _onAutoScanTick?.call();
        }
      },
    );
  }

  // Callback for FusionEngine to hook into auto-scan
  VoidCallback? _onAutoScanTick;
  void setAutoScanCallback(VoidCallback callback) {
    _onAutoScanTick = callback;
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    super.dispose();
  }
}
