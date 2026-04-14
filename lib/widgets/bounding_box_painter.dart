import 'package:flutter/material.dart';
import '../models/detected_object.dart';
import '../core/theme.dart';

/// Custom painter for drawing YOLO bounding boxes on camera preview.
class BoundingBoxPainter extends CustomPainter {
  final List<DetectedObject> objects;
  final Size imageSize;
  final bool showLabels;

  BoundingBoxPainter({
    required this.objects,
    required this.imageSize,
    this.showLabels = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (objects.isEmpty) return;

    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    for (final obj in objects) {
      final color = _getColorForLabel(obj.label);

      // Draw bounding box
      final boxPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;

      final rect = Rect.fromLTWH(
        obj.x * size.width,
        obj.y * size.height,
        obj.width * size.width,
        obj.height * size.height,
      );

      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
      canvas.drawRRect(rrect, boxPaint);

      // Draw label background
      if (showLabels) {
        final labelText = '${obj.label} ${(obj.confidence * 100).toInt()}%';
        final textPainter = TextPainter(
          text: TextSpan(
            text: labelText,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        final labelBgRect = Rect.fromLTWH(
          rect.left,
          rect.top - 22,
          textPainter.width + 12,
          22,
        );

        final bgPaint = Paint()..color = color.withOpacity(0.8);
        canvas.drawRRect(
          RRect.fromRectAndRadius(labelBgRect, const Radius.circular(4)),
          bgPaint,
        );

        textPainter.paint(canvas, Offset(rect.left + 6, rect.top - 20));
      }
    }
  }

  Color _getColorForLabel(String label) {
    // Hazard categories get warm colors
    const hazards = {'knife', 'scissors', 'fire hydrant', 'stop sign'};
    if (hazards.contains(label.toLowerCase())) {
      return EchoSightTheme.danger;
    }

    // Navigation objects
    const navigation = {'car', 'truck', 'bus', 'bicycle', 'motorcycle', 'traffic light'};
    if (navigation.contains(label.toLowerCase())) {
      return EchoSightTheme.warning;
    }

    // Furniture / indoor
    const furniture = {'chair', 'table', 'couch', 'bed', 'desk'};
    if (furniture.contains(label.toLowerCase())) {
      return EchoSightTheme.accent;
    }

    // People
    if (label.toLowerCase() == 'person') {
      return EchoSightTheme.primary;
    }

    return EchoSightTheme.primaryLight;
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) {
    return objects != oldDelegate.objects;
  }
}
