import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'camera_service.dart';
import 'detection_service.dart';
import 'ocr_service.dart';
import 'vision_context_builder.dart';
import 'websocket_service.dart';
import 'tts_service.dart';
import 'location_service.dart';

/// Verbosity level for how much detail the surroundings mode provides.
enum SurroundingsVerbosity {
  minimal,   // Safety only — like a radar
  standard,  // Safety + spatial + people
  immersive, // Full sensory painting
}

extension SurroundingsVerbosityX on SurroundingsVerbosity {
  String get label {
    switch (this) {
      case SurroundingsVerbosity.minimal:
        return 'Minimal';
      case SurroundingsVerbosity.standard:
        return 'Standard';
      case SurroundingsVerbosity.immersive:
        return 'Immersive';
    }
  }

  String get description {
    switch (this) {
      case SurroundingsVerbosity.minimal:
        return 'Safety alerts only';
      case SurroundingsVerbosity.standard:
        return 'Safety + people + layout';
      case SurroundingsVerbosity.immersive:
        return 'Full sensory experience';
    }
  }

  /// Scan interval in seconds — more detail = slightly slower to avoid overwhelming
  int get scanIntervalSeconds {
    switch (this) {
      case SurroundingsVerbosity.minimal:
        return 3;
      case SurroundingsVerbosity.standard:
        return 5;
      case SurroundingsVerbosity.immersive:
        return 7;
    }
  }
}

/// The Surroundings Service provides continuous, proactive environmental
/// awareness — functioning as a digital eye replacement.
///
/// Unlike other modes where the user must ask, this mode continuously
/// captures camera frames and sends them to Gemini with a delta-aware
/// prompt, speaking only about what has CHANGED since the last scan.
const _kSurroundingsVerbosityKey = 'surroundings_verbosity';

class SurroundingsService extends ChangeNotifier {
  final CameraService cameraService;
  final DetectionService detectionService;
  final OcrService ocrService;
  final WebSocketService webSocketService;
  final TtsService ttsService;
  final LocationService locationService;
  late final VisionContextBuilder _contextBuilder;

  // State
  bool _isActive = false;
  bool _isPaused = false;
  SurroundingsVerbosity _verbosity = SurroundingsVerbosity.standard;
  Timer? _scanTimer;
  int _scanCount = 0;

  // Scene memory — what Gemini last described, sent back with next frame
  // so it only reports deltas
  String _lastSceneDescription = '';
  List<String> _lastDetectedObjects = [];
  String _lastOcrText = '';
  String _backendWsMode = 'surroundings';

  // Getters
  bool get isActive => _isActive;
  bool get isPaused => _isPaused;
  SurroundingsVerbosity get verbosity => _verbosity;
  int get scanCount => _scanCount;
  String get lastSceneDescription => _lastSceneDescription;
  String get backendWsMode => _backendWsMode;

  SurroundingsService({
    required this.cameraService,
    required this.detectionService,
    required this.ocrService,
    required this.webSocketService,
    required this.ttsService,
    required this.locationService,
  }) {
    _contextBuilder = VisionContextBuilder(
      detectionService: detectionService,
      ocrService: ocrService,
    );
    _loadVerbosity();
  }

  Future<void> _loadVerbosity() async {
    try {
      final p = await SharedPreferences.getInstance();
      final name = p.getString(_kSurroundingsVerbosityKey);
      if (name == null) return;
      SurroundingsVerbosity? parsed;
      for (final e in SurroundingsVerbosity.values) {
        if (e.name == name) {
          parsed = e;
          break;
        }
      }
      if (parsed != null && parsed != _verbosity) {
        _verbosity = parsed;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('⚠️ Surroundings verbosity load failed: $e');
    }
  }

  Future<void> _persistVerbosity() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kSurroundingsVerbosityKey, _verbosity.name);
    } catch (e) {
      debugPrint('⚠️ Surroundings verbosity save failed: $e');
    }
  }

  /// Start the continuous surroundings / sight scan loop.
  /// [backendMode] must be `surroundings` or `sight` (matches backend `mode`).
  void activate({String backendMode = 'surroundings'}) {
    assert(backendMode == 'surroundings' || backendMode == 'sight');
    if (_isActive) return;

    _backendWsMode = backendMode;
    _isActive = true;
    _isPaused = false;
    _scanCount = 0;
    _lastSceneDescription = '';
    _lastDetectedObjects = [];
    _lastOcrText = '';
    notifyListeners();

    final intro = backendMode == 'sight'
        ? 'Sight stream active. Describing your surroundings like clear vision. '
            'Say pause to mute, or switch modes to stop.'
        : 'Surroundings mode active. I am now your eyes. '
            'Say pause to mute, or switch modes to stop.';
    ttsService.speak(intro);

    _startScanLoop();
  }

  /// Switch between surroundings and sight without clearing scene memory.
  void setBackendMode(String backendMode) {
    assert(backendMode == 'surroundings' || backendMode == 'sight');
    if (_backendWsMode == backendMode) return;
    _backendWsMode = backendMode;
    notifyListeners();
  }

  /// Deactivate and clean up.
  void deactivate() {
    _scanTimer?.cancel();
    _scanTimer = null;
    _isActive = false;
    _isPaused = false;
    _lastSceneDescription = '';
    notifyListeners();
  }

  /// Temporarily mute non-critical updates (user said "pause" / "quiet").
  void pause() {
    _isPaused = true;
    notifyListeners();
    ttsService.speak('Surroundings paused. Say resume to continue.');
  }

  /// Resume after pause.
  void resume() {
    _isPaused = false;
    notifyListeners();
    ttsService.speak('Resuming surroundings.');
  }

  /// Change verbosity level.
  void setVerbosity(SurroundingsVerbosity v, {bool speakFeedback = true}) {
    if (_verbosity == v) return;
    _verbosity = v;
    notifyListeners();
    unawaited(_persistVerbosity());

    if (_isActive) {
      _startScanLoop();
    }

    if (speakFeedback) {
      ttsService.speak('Verbosity ${v.label}. ${v.description}.');
    }
  }

  /// Cycle through verbosity levels.
  void cycleVerbosity() {
    final values = SurroundingsVerbosity.values;
    final next = values[(_verbosity.index + 1) % values.length];
    setVerbosity(next, speakFeedback: true);
  }

  /// Start (or restart) the periodic auto-capture timer.
  void _startScanLoop() {
    _scanTimer?.cancel();
    final interval = Duration(seconds: _verbosity.scanIntervalSeconds);
    _scanTimer = Timer.periodic(interval, (_) {
      if (_isActive && !_isPaused) {
        _onScanTick?.call();
      }
    });
  }

  /// Perform a single surroundings / sight scan.
  /// Called by FusionEngine which owns the WebSocket message sending.
  ///
  /// [mode] must match backend: `surroundings` (change-focused) or `sight` (sight-like richness).
  Future<Map<String, dynamic>> buildScanPayload({String? mode}) async {
    final m = mode ?? _backendWsMode;
    _scanCount++;
    notifyListeners();

    String? imageBase64;
    Map<String, dynamic>? visionContext;

    try {
      cameraService.invalidateCache();
      imageBase64 = await cameraService.captureFrame();

      if (cameraService.isInitialized) {
        final rawFrame = await cameraService.captureRawFrame();
        if (rawFrame != null) {
          final ctx = await _contextBuilder.buildContext(rawFrame);
          visionContext = ctx.toJson();

          // Update local object memory
          _lastDetectedObjects = ctx.objects.map((o) => o.label).toList();
          if (ctx.hasText) {
            _lastOcrText = visionContext?['text'] ?? '';
          }
        }
      }
    } catch (e) {
      debugPrint('⚠️ Surroundings scan frame capture failed: $e');
    }

    // Fetch GPS
    Map<String, double>? gpsData;
    try {
      gpsData = await locationService.getCurrentLocation();
    } catch (_) {}

    final query = _buildDeltaQuery(mode: m);

    return {
      'query': query,
      'image': imageBase64,
      'vision_context': visionContext,
      'location': gpsData,
      'mode': m,
      'scene_memory': _lastSceneDescription,
    };
  }

  /// Build the delta-aware query that tells Gemini what was already described.
  String _buildDeltaQuery({String mode = 'surroundings'}) {
    final buf = StringBuffer();
    final label = mode == 'sight' ? 'SIGHT SCAN' : 'SURROUNDINGS SCAN';
    buf.write('$label #$_scanCount. ');

    if (_lastSceneDescription.isEmpty) {
      buf.write('This is the FIRST scan. Describe the complete scene. ');
    } else {
      buf.write(
        'Previous scene description: "$_lastSceneDescription". '
        'ONLY describe what has CHANGED. If nothing changed, say "no changes". '
      );
    }

    buf.write('Verbosity: ${_verbosity.label}.');
    return buf.toString();
  }

  /// Called by FusionEngine when Gemini responds to a surroundings scan.
  void updateSceneMemory(String newDescription) {
    if (newDescription.isNotEmpty &&
        !newDescription.toLowerCase().contains('no changes')) {
      _lastSceneDescription = newDescription;
      notifyListeners();
    }
  }

  // Callback for FusionEngine to hook into auto-scan ticks
  VoidCallback? _onScanTick;
  void setAutoScanCallback(VoidCallback callback) {
    _onScanTick = callback;
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    super.dispose();
  }
}
