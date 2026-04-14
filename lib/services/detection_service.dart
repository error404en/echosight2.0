import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import '../models/detected_object.dart';
import 'dart:math';

/// YOLOv8 object detection service using TFLite.
class DetectionService extends ChangeNotifier {
  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _isInitialized = false;
  bool _isProcessing = false;

  static const int _inputSize = 640;
  static const double _confidenceThreshold = 0.45;
  static const double _nmsThreshold = 0.5;

  bool get isInitialized => _isInitialized;
  bool get isProcessing => _isProcessing;
  List<String> get labels => _labels;

  /// Initialize the YOLO model and labels.
  Future<void> initialize() async {
    try {
      // Load model
      _interpreter = await Interpreter.fromAsset(
        'assets/models/yolov8n_float16.tflite',
        options: InterpreterOptions()..threads = 4,
      );

      // Load labels
      final labelData = await rootBundle.loadString('assets/labels/coco_labels.txt');
      _labels = labelData.split('\n').where((l) => l.trim().isNotEmpty).toList();

      _isInitialized = true;
      notifyListeners();
      debugPrint('🎯 YOLO detection initialized (${_labels.length} classes)');
    } catch (e) {
      debugPrint('❌ Detection init failed: $e');
      debugPrint('   This is expected if model files are not bundled yet.');
      _isInitialized = false;
      notifyListeners();
    }
  }

  /// Run object detection on image bytes.
  Future<List<DetectedObject>> detectObjects(Uint8List imageBytes) async {
    if (!_isInitialized || _interpreter == null || _isProcessing) {
      return [];
    }
    _isProcessing = true;

    try {
      // 1. Preprocess
      final image = img.decodeImage(imageBytes);
      if (image == null) {
        _isProcessing = false;
        return [];
      }

      final resized = img.copyResize(image, width: _inputSize, height: _inputSize);
      
      // YOLOv8 inputs [1, 640, 640, 3] Float32
      var inputBuffer = List.generate(
        1, 
        (b) => List.generate(
          _inputSize, 
          (y) => List.generate(
            _inputSize, 
            (x) => List.filled(3, 0.0)
          )
        )
      );
      
      for (var y = 0; y < _inputSize; y++) {
        for (var x = 0; x < _inputSize; x++) {
          var pixel = resized.getPixel(x, y);
          inputBuffer[0][y][x][0] = pixel.r / 255.0;
          inputBuffer[0][y][x][1] = pixel.g / 255.0;
          inputBuffer[0][y][x][2] = pixel.b / 255.0;
        }
      }

      // YOLOv8 outputs [1, 84, 8400]
      var outputBuffer = List.generate(1, (_) => List.generate(84, (_) => List.filled(8400, 0.0)));
      
      // 2. Inference
      _interpreter!.run(inputBuffer, outputBuffer);

      // 3. Postprocess
      List<DetectedObject> detections = [];
      var tensorOut = outputBuffer[0];
      
      for (var col = 0; col < 8400; col++) {
         double bestScore = 0;
         int bestClassId = -1;
         
         for (var cls = 0; cls < 80; cls++) {
             double score = tensorOut[cls + 4][col];
             if (score > bestScore) {
                 bestScore = score;
                 bestClassId = cls;
             }
         }
         
         if (bestScore > _confidenceThreshold) {
             double cx = tensorOut[0][col];
             double cy = tensorOut[1][col];
             double w = tensorOut[2][col];
             double h = tensorOut[3][col];
             
             double left = (cx - w / 2) / 640.0;
             double top = (cy - h / 2) / 640.0;
             double width = w / 640.0;
             double height = h / 640.0;
             
             double area = width * height;
             String distance = area > 0.4 ? 'near' : (area > 0.1 ? 'mid' : 'far');
             String position = left < 0.33 ? 'left' : (left > 0.66 ? 'right' : 'center');
             
             detections.add(DetectedObject(
                 label: _labels[bestClassId],
                 confidence: bestScore,
                 x: left.clamp(0.0, 1.0),
                 y: top.clamp(0.0, 1.0),
                 width: width.clamp(0.0, 1.0),
                 height: height.clamp(0.0, 1.0),
                 position: position,
                 distance: distance,
             ));
         }
      }

      // Simple NMS (Non-Max-Suppression)
      detections.sort((a, b) => b.confidence.compareTo(a.confidence));
      List<DetectedObject> finalDetections = [];
      
      for (var d in detections) {
          bool keep = true;
          for (var fd in finalDetections) {
              if (fd.label == d.label) {
                 double iou = _calculateIoU(d, fd);
                 if (iou > _nmsThreshold) { 
                     keep = false; 
                     break; 
                 }
              }
          }
          if (keep) finalDetections.add(d);
      }
      
      _isProcessing = false;
      notifyListeners();
      return finalDetections;
      
    } catch (e) {
      debugPrint('❌ Detection error: $e');
      _isProcessing = false;
      notifyListeners();
      return [];
    }
  }

  double _calculateIoU(DetectedObject a, DetectedObject b) {
      double x1 = max(a.x, b.x);
      double y1 = max(a.y, b.y);
      double x2 = min(a.x + a.width, b.x + b.width);
      double y2 = min(a.y + a.height, b.y + b.height);
      
      double interArea = max(0, x2 - x1) * max(0, y2 - y1);
      double unionArea = a.width * a.height + b.width * b.height - interArea;
      
      return interArea / unionArea;
  }

  @override
  void dispose() {
    _interpreter?.close();
    super.dispose();
  }
}
