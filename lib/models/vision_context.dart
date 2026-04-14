import 'detected_object.dart';
import 'ocr_result.dart';

/// Structured vision context combining object detection + OCR.
class VisionContext {
  final List<DetectedObject> objects;
  final OcrResult? ocrResult;
  final String environment;
  final DateTime timestamp;

  VisionContext({
    this.objects = const [],
    this.ocrResult,
    this.environment = 'unknown',
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get hasObjects => objects.isNotEmpty;
  bool get hasText => ocrResult?.hasText ?? false;
  bool get isEmpty => !hasObjects && !hasText;

  /// Convert to JSON for sending to backend.
  Map<String, dynamic> toJson() => {
        'objects': objects.map((o) => o.toJson()).toList(),
        'text': ocrResult?.fullText ?? '',
        'environment': environment,
      };

  /// Generate a human-readable summary.
  String get summary {
    final parts = <String>[];
    if (hasObjects) {
      final labels = objects.map((o) => o.label).toSet().toList();
      parts.add('Objects: ${labels.join(", ")}');
    }
    if (hasText) {
      final text = ocrResult!.fullText;
      final preview = text.length > 50 ? '${text.substring(0, 50)}...' : text;
      parts.add('Text: "$preview"');
    }
    parts.add('Environment: $environment');
    return parts.join(' | ');
  }
}
