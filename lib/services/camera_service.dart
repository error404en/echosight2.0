import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Camera service for real-time frame capture.
/// Uses a single capture for both API and on-device processing to avoid
/// repeated autofocus triggers.
class CameraService extends ChangeNotifier {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isCapturing = false;
  CameraLensDirection _currentDirection = CameraLensDirection.back;

  // Cached last capture — avoids double takePicture()
  Uint8List? _lastRawFrame;
  String? _lastBase64Frame;
  DateTime _lastCaptureTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const int _minMsBetweenFrames = 500; // ~2 FPS max for battery savings

  CameraController? get controller => _controller;
  bool get isInitialized => _isInitialized;
  List<CameraDescription> get cameras => _cameras;

  /// Initialize the camera.
  Future<void> initialize() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        debugPrint('⚠️ No cameras available');
        return;
      }

      // Use the currently selected direction (defaults to back)
      CameraDescription camera;
      try {
        camera = _cameras.firstWhere((c) => c.lensDirection == _currentDirection);
      } catch (_) {
        camera = _cameras.first;
      }

      _controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _controller!.initialize();

      // Lock focus mode to avoid repeated autofocus on each capture
      try {
        await _controller!.setFocusMode(FocusMode.auto);
      } catch (e) {
        debugPrint('⚠️ Could not set focus mode: $e');
      }

      _isInitialized = true;
      notifyListeners();
      debugPrint('✅ Camera initialized');
    } catch (e) {
      debugPrint('❌ Camera initialization failed: $e');
      _isInitialized = false;
      notifyListeners();
    }
  }

  /// Pause the camera feed.
  Future<void> pausePreview() async {
    if (_isInitialized && _controller != null) {
      await _controller!.pausePreview();
      notifyListeners();
    }
  }

  /// Resume the camera feed.
  Future<void> resumePreview() async {
    if (_isInitialized && _controller != null) {
      await _controller!.resumePreview();
      notifyListeners();
    }
  }

  /// Flips the camera between Front and Back.
  Future<void> switchCamera() async {
    _currentDirection = _currentDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;

    _isInitialized = false;
    await _controller?.dispose();
    _controller = null;
    _lastRawFrame = null;
    _lastBase64Frame = null;
    notifyListeners();

    await initialize();
  }

  /// Take a single picture and cache both raw + base64 results.
  /// Subsequent calls to captureFrame() and captureRawFrame() within
  /// the throttle window will reuse this cached data instead of
  /// triggering another autofocus cycle.
  Future<bool> _captureOnce() async {
    if (!_isInitialized || _controller == null || _isCapturing) return false;

    final now = DateTime.now();
    if (now.difference(_lastCaptureTime).inMilliseconds < _minMsBetweenFrames) {
      // Use cached frame if within throttle window
      return _lastRawFrame != null;
    }

    try {
      _isCapturing = true;
      final XFile file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();

      // Cache both raw and resized
      _lastRawFrame = bytes;
      final resized = await compute(_resizeImage, bytes);
      _lastBase64Frame = base64Encode(resized);

      _lastCaptureTime = DateTime.now();
      _isCapturing = false;
      return true;
    } catch (e) {
      debugPrint('❌ Frame capture failed: $e');
      _isCapturing = false;
      return false;
    }
  }

  /// Capture a single frame as base64 JPEG (for sending to the Groq vision API).
  Future<String?> captureFrame() async {
    final ok = await _captureOnce();
    return ok ? _lastBase64Frame : null;
  }

  /// Capture raw bytes for on-device processing (YOLO/OCR).
  /// Reuses the same capture as captureFrame() — no double autofocus.
  Future<Uint8List?> captureRawFrame() async {
    final ok = await _captureOnce();
    return ok ? _lastRawFrame : null;
  }

  /// Force a fresh capture (invalidates cache).
  void invalidateCache() {
    _lastRawFrame = null;
    _lastBase64Frame = null;
    _lastCaptureTime = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Resize image in an isolate to keep UI smooth.
  static Uint8List _resizeImage(Uint8List bytes) {
    final image = img.decodeImage(bytes);
    if (image == null) return bytes;

    // Resize to max 640px width for API efficiency
    final resized = img.copyResize(image, width: 640);
    return Uint8List.fromList(img.encodeJpg(resized, quality: 75));
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}
