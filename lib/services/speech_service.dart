import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

/// Speech service that captures raw microphone audio for cloud STT.
class SpeechService extends ChangeNotifier {
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isAvailable = false;
  bool _isListening = false;
  
  bool get isAvailable => _isAvailable;
  bool get isListening => _isListening;
  String get currentText => _isListening ? 'Listening...' : '';

  // Callbacks
  Function(String base64Audio)? onAudioCaptured;
  Function(String text)? onPartialResult;

  /// Initialize permissions
  Future<bool> initialize() async {
    try {
      _isAvailable = await _audioRecorder.hasPermission();
      notifyListeners();
      debugPrint('🎤 Microphone permission: $_isAvailable');
      return _isAvailable;
    } catch (e) {
      debugPrint('❌ Mic init failed: $e');
      _isAvailable = false;
      notifyListeners();
      return false;
    }
  }

  /// Start capturing audio.
  Future<void> startListening() async {
    if (!_isAvailable || _isListening) return;

    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/speech_input.m4a';
      
      // Delete old file if exists
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }

      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc, // Optimal for Whisper APIs
          bitRate: 128000,
          sampleRate: 16000,
        ),
        path: path,
      );
      
      _isListening = true;
      notifyListeners();
      debugPrint('🎤 Recording started to $path');
    } catch (e) {
      debugPrint('❌ Recording failed: $e');
      _isListening = false;
      notifyListeners();
    }
  }

  /// Stop capturing and return Base64.
  Future<void> stopListening() async {
    if (!_isListening) return;

    try {
      final path = await _audioRecorder.stop();
      _isListening = false;
      notifyListeners();
      debugPrint('🎤 Recording stopped');

      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final base64Audio = base64Encode(bytes);
          onAudioCaptured?.call(base64Audio);
          
          // Cleanup
          await file.delete();
        }
      }
    } catch (e) {
      debugPrint('❌ Stop recording failed: $e');
      _isListening = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _audioRecorder.dispose();
    super.dispose();
  }
}
