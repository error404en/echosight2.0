import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/detected_object.dart';
import '../models/ocr_result.dart';
import '../models/vision_context.dart';
import 'detection_service.dart';
import 'ocr_service.dart';

/// Builds structured vision context by combining object detection + OCR.
class VisionContextBuilder {
  final DetectionService _detectionService;
  final OcrService _ocrService;

  VisionContextBuilder({
    required DetectionService detectionService,
    required OcrService ocrService,
  })  : _detectionService = detectionService,
        _ocrService = ocrService;

  /// Process an image and build a complete vision context.
  Future<VisionContext> buildContext(Uint8List imageBytes) async {
    List<DetectedObject> objects = [];
    OcrResult ocrResult = OcrResult(fullText: '');

    // Run detection and OCR in parallel
    try {
      final results = await Future.wait([
        _runDetection(imageBytes),
        _runOcr(imageBytes),
      ]);

      objects = results[0] as List<DetectedObject>;
      ocrResult = results[1] as OcrResult;
    } catch (e) {
      debugPrint('❌ Vision context build error: $e');
    }

    // Estimate environment
    final environment = _estimateEnvironment(objects, ocrResult);

    return VisionContext(
      objects: objects,
      ocrResult: ocrResult,
      environment: environment,
    );
  }

  /// Quick context build using mock data (when model not available).
  VisionContext buildMockContext() {
    return VisionContext(
      objects: [],
      ocrResult: OcrResult(fullText: ''),
      environment: 'indoor, well-lit',
    );
  }

  Future<List<DetectedObject>> _runDetection(Uint8List imageBytes) async {
    if (!_detectionService.isInitialized) return [];
    return await _detectionService.detectObjects(imageBytes);
  }

  Future<OcrResult> _runOcr(Uint8List imageBytes) async {
    // OCR requires a file path in current ML Kit version
    // For streaming frames, we'd save to temp file first
    return OcrResult(fullText: '');
  }

  /// Estimate the environment from detected objects and text.
  String _estimateEnvironment(List<DetectedObject> objects, OcrResult ocr) {
    final labels = objects.map((o) => o.label.toLowerCase()).toSet();

    // Indoor indicators
    final indoorItems = {'chair', 'table', 'couch', 'bed', 'tv', 'laptop', 
                         'book', 'clock', 'vase', 'toilet', 'sink', 'oven',
                         'refrigerator', 'microwave'};
    // Outdoor indicators
    final outdoorItems = {'car', 'truck', 'bus', 'bicycle', 'motorcycle',
                          'traffic light', 'stop sign', 'fire hydrant', 'bench'};

    final hasIndoor = labels.intersection(indoorItems).isNotEmpty;
    final hasOutdoor = labels.intersection(outdoorItems).isNotEmpty;

    String location = 'unknown';
    if (hasIndoor && !hasOutdoor) {
      location = 'indoor';
    } else if (hasOutdoor && !hasIndoor) {
      location = 'outdoor';
    } else if (hasIndoor && hasOutdoor) {
      location = 'near entrance/exit';
    }

    // Check for text/signs
    final hasText = ocr.hasText;
    final textInfo = hasText ? ', text visible' : '';

    // Check for potential hazards
    final hazardItems = {'knife', 'scissors', 'fire hydrant'};
    final hasHazard = labels.intersection(hazardItems).isNotEmpty;
    final hazardInfo = hasHazard ? ', potential hazards detected' : '';

    return '$location$textInfo$hazardInfo';
  }
}
