import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Camera service for real-time frame capture.
class CameraService extends ChangeNotifier {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitialized = false;
  bool _isCapturing = false;
  CameraLensDirection _currentDirection = CameraLensDirection.back;
  
  // Smart FPS Limiter
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
    notifyListeners();
    
    await initialize();
  }

  /// Capture a single frame as base64 JPEG.
  Future<String?> captureFrame() async {
    if (!_isInitialized || _controller == null || _isCapturing) return null;

    final now = DateTime.now();
    if (now.difference(_lastCaptureTime).inMilliseconds < _minMsBetweenFrames) {
      return null; // Throttle to save battery
    }

    try {
      _isCapturing = true;
      final XFile file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();

      // Resize for sending to API (reduce bandwidth)
      final resized = await compute(_resizeImage, bytes);
      final base64Image = base64Encode(resized);

      _isCapturing = false;
      _lastCaptureTime = DateTime.now();
      return base64Image;
    } catch (e) {
      debugPrint('❌ Frame capture failed: $e');
      _isCapturing = false;
      return null;
    }
  }

  /// Capture raw bytes for on-device processing (YOLO/OCR).
  Future<Uint8List?> captureRawFrame() async {
    if (!_isInitialized || _controller == null || _isCapturing) return null;

    try {
      _isCapturing = true;
      final XFile file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();
      _isCapturing = false;
      return bytes;
    } catch (e) {
      debugPrint('❌ Raw frame capture failed: $e');
      _isCapturing = false;
      return null;
    }
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
