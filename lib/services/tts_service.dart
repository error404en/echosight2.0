import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';

/// Next-gen TTS service that streams edge-tts audio payloads directly from the AI backend.
class TtsService extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();
  bool _isSpeaking = false;
  bool _isInitialized = false;
  
  double _speechRate = 1.0;
  double _pitch = 1.0;
  
  final Queue<Uint8List> _audioQueue = Queue();
  bool _shouldStop = false;

  bool get isSpeaking => _isSpeaking;
  bool get isInitialized => _isInitialized;
  double get speechRate => _speechRate;
  double get pitch => _pitch;

  // Callbacks
  VoidCallback? onSpeakingComplete;

  /// Initialize Audio engine.
  Future<void> initialize() async {
    try {
      _player.onPlayerStateChanged.listen((state) {
        if (state == PlayerState.playing) {
          _isSpeaking = true;
          notifyListeners();
        } else if (state == PlayerState.completed) {
          _isSpeaking = false;
          notifyListeners();
          _processQueue();
        }
      });
      _isInitialized = true;
      notifyListeners();
      debugPrint('🔊 Audio player initialized');
    } catch (e) {
      debugPrint('❌ Audio init failed: $e');
    }
  }

  /// Speak text natively as a fallback.
  Future<void> speak(String text) async {
    // If the server fails, we ideally want a local fallback. 
    // For now, this is a no-op as the backend handles TTS natively.
    debugPrint('Fallback TTS requested: $text');
  }

  /// Add Base64 audio to the queue for playback.
  void playAudioBase64(String base64Audio) {
    if (!_isInitialized) return;

    try {
      final bytes = base64Decode(base64Audio);
      _audioQueue.add(bytes);

      // Start playing if idle
      if (!_isSpeaking && _player.state != PlayerState.playing) {
        _processQueue();
      }
    } catch (e) {
      debugPrint('❌ Failed to queue audio: $e');
    }
  }

  /// The old text enqueueing function, left for compatibility (now does nothing as backend sends audio)
  void enqueueText(String text) {
    // Deprecated for Cloud TTS pipeline.
  }

  /// Process the audio stream queue.
  Future<void> _processQueue() async {
    if (_shouldStop || _audioQueue.isEmpty) {
      if (_audioQueue.isEmpty) {
        onSpeakingComplete?.call();
      }
      return;
    }

    try {
      final nextChunk = _audioQueue.removeFirst();
      await _player.play(BytesSource(nextChunk));
    } catch (e) {
      debugPrint('❌ Chunk playback failed: $e');
      _processQueue(); // Skip and play next
    }
  }

  /// Stop playing and clear the queue.
  Future<void> stop() async {
    _shouldStop = true;
    _audioQueue.clear();
    await _player.stop();
    _isSpeaking = false;
    notifyListeners();
    // Allow queueing again
    _shouldStop = false; 
  }

  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate;
    await _player.setPlaybackRate(rate);
    notifyListeners();
  }

  Future<void> setPitch(double pitch) async {
    _pitch = pitch;
    notifyListeners(); // Pitch shifting requires advanced engines, simple state for now
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}
