import 'dart:typed_data';
import 'dart:ui' show Size;
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../models/ocr_result.dart' as app_ocr;

/// OCR service using Google ML Kit for on-device text recognition.
class OcrService {
  TextRecognizer? _recognizer;
  bool _isInitialized = false;
  bool _isProcessing = false;

  bool get isInitialized => _isInitialized;
  bool get isProcessing => _isProcessing;

  /// Initialize the OCR engine.
  void initialize() {
    _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    _isInitialized = true;
    debugPrint('📝 OCR service initialized');
  }

  /// Process an image file and extract text.
  Future<app_ocr.OcrResult> processImageFile(String filePath) async {
    if (!_isInitialized || _isProcessing) {
      return app_ocr.OcrResult(fullText: '');
    }

    _isProcessing = true;

    try {
      final inputImage = InputImage.fromFilePath(filePath);
      final recognized = await _recognizer!.processImage(inputImage);

      final blocks = <app_ocr.TextBlock>[];
      for (final block in recognized.blocks) {
        final rect = block.boundingBox;
        blocks.add(app_ocr.TextBlock(
          text: block.text,
          x: rect.left,
          y: rect.top,
          width: rect.width,
          height: rect.height,
        ));
      }

      _isProcessing = false;
      return app_ocr.OcrResult(
        fullText: recognized.text,
        blocks: blocks,
      );
    } catch (e) {
      debugPrint('❌ OCR error: $e');
      _isProcessing = false;
      return app_ocr.OcrResult(fullText: '');
    }
  }

  /// Process raw image bytes.
  Future<app_ocr.OcrResult> processBytes(Uint8List bytes, {
    required int width,
    required int height,
    required InputImageRotation rotation,
    required InputImageFormat format,
    required int bytesPerRow,
  }) async {
    if (!_isInitialized || _isProcessing) {
      return app_ocr.OcrResult(fullText: '');
    }

    _isProcessing = true;

    try {
      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(width.toDouble(), height.toDouble()),
          rotation: rotation,
          format: format,
          bytesPerRow: bytesPerRow,
        ),
      );
      final recognized = await _recognizer!.processImage(inputImage);

      final blocks = <app_ocr.TextBlock>[];
      for (final block in recognized.blocks) {
        final rect = block.boundingBox;
        blocks.add(app_ocr.TextBlock(
          text: block.text,
          x: rect.left,
          y: rect.top,
          width: rect.width,
          height: rect.height,
        ));
      }

      _isProcessing = false;
      return app_ocr.OcrResult(
        fullText: recognized.text,
        blocks: blocks,
      );
    } catch (e) {
      debugPrint('❌ OCR bytes error: $e');
      _isProcessing = false;
      return app_ocr.OcrResult(fullText: '');
    }
  }

  void dispose() {
    _recognizer?.close();
  }
}
