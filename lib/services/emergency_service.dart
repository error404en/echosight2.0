import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';
import 'camera_service.dart';
import 'tts_service.dart';
import 'location_service.dart';
import 'websocket_service.dart';
import 'detection_service.dart';
import 'ocr_service.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'vision_context_builder.dart';
import 'package:permission_handler/permission_handler.dart';

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
  bool get isRecording => _isRecording;
  List<Map<String, String>> get emergencyContacts => _emergencyContacts;
  bool get isCountingDown => _isCountingDown;
  int get countdownSeconds => _countdownSeconds;

  final _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String _recordingPath = '';
  
  List<Map<String, String>> _emergencyContacts = [];
  Timer? _countdownTimer;
  int _countdownSeconds = 10;
  bool _isCountingDown = false;

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
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final names = prefs.getStringList('emergency_names') ?? [];
    final phones = prefs.getStringList('emergency_phones') ?? [];
    
    _emergencyContacts.clear();
    for (int i = 0; i < names.length && i < phones.length; i++) {
      _emergencyContacts.add({'name': names[i], 'phone': phones[i]});
    }
    notifyListeners();
  }

  Future<void> saveContact(String name, String phone) async {
    _emergencyContacts.add({'name': name, 'phone': phone});
    await _saveContactsToPrefs();
  }

  Future<void> removeContact(int index) async {
    if (index >= 0 && index < _emergencyContacts.length) {
      _emergencyContacts.removeAt(index);
      await _saveContactsToPrefs();
    }
  }

  Future<void> _saveContactsToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final names = _emergencyContacts.map((c) => c['name']!).toList();
    final phones = _emergencyContacts.map((c) => c['phone']!).toList();
    await prefs.setStringList('emergency_names', names);
    await prefs.setStringList('emergency_phones', phones);
    notifyListeners();
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
        String address = loc['address'] ?? '';
        _emergencyLocation = address.isNotEmpty ? address : 
            'Lat: ${loc['latitude']?.toStringAsFixed(5)}, Lng: ${loc['longitude']?.toStringAsFixed(5)}';
      }
    } catch (_) {}

    // Start recording audio
    await _startRecording();

    // Start continuous scanning every 8 seconds
    _startContinuousScan();
  }

  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final dir = await getApplicationDocumentsDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        _recordingPath = '${dir.path}/emergency_audio_$timestamp.m4a';
        await _audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc),
          path: _recordingPath,
        );
        _isRecording = true;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('❌ Recording failed: $e');
    }
  }

  Future<void> _stopRecording() async {
    try {
      if (_isRecording) {
        await _audioRecorder.stop();
        _isRecording = false;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Deactivate emergency mode.
  void deactivate() {
    _scanTimer?.cancel();
    _scanTimer = null;
    cancelSOS();
    _state = EmergencyState.inactive;
    _sosTriggered = false;
    _stopRecording();
    notifyListeners();

    ttsService.speak('Emergency mode deactivated. Returning to normal.');
  }

  void cancelSOS() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _isCountingDown = false;
    notifyListeners();
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
        String address = loc['address'] ?? '';
        _emergencyLocation = address.isNotEmpty ? address : 
            'Lat: ${loc['latitude']?.toStringAsFixed(5)}, Lng: ${loc['longitude']?.toStringAsFixed(5)}';
      }
    } catch (_) {}

    // Stop previous timer if any
    cancelSOS();

    _isCountingDown = true;
    _countdownSeconds = 10;
    notifyListeners();
    
    ttsService.speak('SOS Triggered. Sending location to emergency contacts in 10 seconds. Tap cancel to stop.');

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _countdownSeconds--;
      if (_countdownSeconds > 0) {
        // Haptic pulse per second
        Vibration.vibrate(duration: 50);
        if (_countdownSeconds <= 3) {
           ttsService.speak(_countdownSeconds.toString());
        }
      } else {
        cancelSOS();
        _sendEmergencySMS();
      }
      notifyListeners();
    });
  }

  static const _platform = MethodChannel('com.echosight.echosight/sms');

  Future<void> _sendEmergencySMS() async {
    if (_emergencyContacts.isEmpty) {
      if (!isCountingDown) { 
          // Only speak this if we aren't already speaking the countdown
          ttsService.speak('SOS triggered, but no emergency contacts are saved.');
      }
      return;
    }

    // Attempt to get a Maps link
    String mapsLink = '';
    try {
       final loc = await locationService.getCurrentLocation();
       if (loc != null) {
          mapsLink = 'https://maps.google.com/?q=${loc['latitude']},${loc['longitude']}';
       }
    } catch (_) {}
    
    final sosMessage =
        'EMERGENCY: I need help! My location is: $mapsLink '
        'Sent via EchoSight.';

    _lastAlert = 'SOS Message sent to ${_emergencyContacts.length} contacts.';
    ttsService.speak(_lastAlert);
    
    // Request permission to send SMS in background
    if (await Permission.sms.request().isGranted) {
      try {
        // Send SMS to all contacts sequentially
        for (var contact in _emergencyContacts) {
          final phone = contact['phone']!;
          await _platform.invokeMethod('sendSms', {
            'phone': phone,
            'message': sosMessage,
          });
        }
      } catch (e) {
        debugPrint('❌ Failed to send background SMS via channel: $e');
        ttsService.speak('Failed to send text messages in the background.');
      }
    } else {
      ttsService.speak('Permission to send SMS automatically was denied.');
    }
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
      Map<String, dynamic>? gpsData;
      try {
        gpsData = await locationService.getCurrentLocation();
        if (gpsData != null) {
          String address = gpsData['address'] ?? '';
          _emergencyLocation = address.isNotEmpty ? address : 
              'Lat: ${gpsData['latitude']?.toStringAsFixed(5)}, Lng: ${gpsData['longitude']?.toStringAsFixed(5)}';
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
