/// Data model for objects detected by YOLOv8.
class DetectedObject {
  final String label;
  final double confidence;
  final double x; // Normalized 0-1
  final double y;
  final double width;
  final double height;
  final String position; // "left", "center", "right"
  final String distance; // "near", "mid", "far"

  DetectedObject({
    required this.label,
    required this.confidence,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.position = 'center',
    this.distance = 'mid',
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'confidence': confidence,
        'position': position,
        'distance': distance,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };

  /// Compute spatial position based on normalized x coordinate.
  static String computePosition(double normX) {
    if (normX < 0.33) return 'left';
    if (normX > 0.66) return 'right';
    return 'center';
  }

  /// Estimate distance based on bounding box size.
  static String estimateDistance(double normArea) {
    if (normArea > 0.15) return 'near';
    if (normArea > 0.05) return 'mid';
    return 'far';
  }
}
