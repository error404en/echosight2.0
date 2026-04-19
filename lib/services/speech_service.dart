import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

enum SpeechInputMode {
  onDevice,
  cloudWhisper,
}

/// Speech service that supports both on-device STT and cloud STT (via Whisper).
class SpeechService extends ChangeNotifier {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final stt.SpeechToText _speechToText = stt.SpeechToText();

  bool _isAvailable = false;
  bool _isListening = false;
  SpeechInputMode _inputMode = SpeechInputMode.onDevice;
  String _currentText = '';

  bool get isAvailable => _isAvailable;
  bool get isListening => _isListening;
  String get currentText => _currentText;
  SpeechInputMode get inputMode => _inputMode;

  // Callbacks
  Function(String base64Audio)? onAudioCaptured; // Used for Cloud
  Function(String text)? onTextResult;           // Used for On-Device
  Function(String text)? onPartialResult;

  /// Initialize permissions
  Future<bool> initialize() async {
    try {
      bool recordPerm = await _audioRecorder.hasPermission();
      bool sttInit = false;
      try {
        sttInit = await _speechToText.initialize(
          onError: (err) => debugPrint('STT Error: $err'),
          onStatus: (status) => debugPrint('STT Status: $status'),
        );
      } catch (e) {
        debugPrint('STT Initialize Exception: $e');
      }
      
      if (recordPerm && !sttInit) {
        // Fallback to cloud if local STT fails
        _inputMode = SpeechInputMode.cloudWhisper;
        _isAvailable = true;
      } else {
        _isAvailable = recordPerm && sttInit;
      }

      notifyListeners();
      debugPrint('🎤 Microphone & STT ready: $_isAvailable (Local STT: $sttInit)');
      return _isAvailable;
    } catch (e) {
      debugPrint('❌ Mic init failed: $e');
      _isAvailable = false;
      notifyListeners();
      return false;
    }
  }

  void toggleInputMode() {
    _inputMode = _inputMode == SpeechInputMode.onDevice 
        ? SpeechInputMode.cloudWhisper 
        : SpeechInputMode.onDevice;
    notifyListeners();
  }

  void setInputMode(SpeechInputMode mode) {
    if (_inputMode != mode) {
      _inputMode = mode;
      notifyListeners();
    }
  }

  /// Start capturing audio or listening to speech.
  Future<void> startListening() async {
    if (!_isAvailable || _isListening) return;

    _currentText = 'Listening...';
    _isListening = true;
    notifyListeners();

    try {
      if (_inputMode == SpeechInputMode.onDevice) {
        await _speechToText.listen(
          onResult: (result) {
            _currentText = result.recognizedWords;
            onPartialResult?.call(_currentText);
            notifyListeners();
            
            // If the user stops speaking, finalize the result automatically
            if (result.finalResult) {
              _isListening = false;
              onTextResult?.call(_currentText);
              notifyListeners();
            }
          },
          listenMode: stt.ListenMode.dictation,
          pauseFor: const Duration(seconds: 2), // Auto stop after 2 secs of silence
        );
        debugPrint('🎤 On-device listening started');
      } else {
        // Cloud Whisper mode
        final dir = await getTemporaryDirectory();
        final path = '${dir.path}/speech_input.wav';
        
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }

        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            bitRate: 128000,
            sampleRate: 16000,
          ),
          path: path,
        );
        debugPrint('🎤 Recording started to $path');
      }
    } catch (e) {
      debugPrint('❌ Start listening failed: $e');
      _isListening = false;
      notifyListeners();
    }
  }

  /// Stop capturing manually.
  Future<void> stopListening() async {
    if (!_isListening) return;

    try {
      if (_inputMode == SpeechInputMode.onDevice) {
        await _speechToText.stop();
        _isListening = false;
        notifyListeners();
        
        // Emitting the result is handled by the onResult callback's finalResult flag,
        // but if stopped manually, we might need to emit what we have.
        if (_currentText.isNotEmpty && _currentText != 'Listening...') {
          onTextResult?.call(_currentText);
        }
      } else {
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
            await file.delete();
          }
        }
      }
    } catch (e) {
      debugPrint('❌ Stop listening failed: $e');
      _isListening = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _audioRecorder.dispose();
    _speechToText.cancel();
    super.dispose();
  }
}
