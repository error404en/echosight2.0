/// Data model for OCR results.
class OcrResult {
  final String fullText;
  final List<TextBlock> blocks;
  final DateTime timestamp;

  OcrResult({
    required this.fullText,
    this.blocks = const [],
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get hasText => fullText.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'text': fullText,
        'blockCount': blocks.length,
      };
}

class TextBlock {
  final String text;
  final double x;
  final double y;
  final double width;
  final double height;

  TextBlock({
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });
}
