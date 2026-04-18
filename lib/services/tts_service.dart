import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// TTS service with dual mode:
///   1. Cloud mode — plays Edge-TTS audio chunks from the backend
///   2. Local fallback — uses on-device flutter_tts when backend is unavailable
class TtsService extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _localTts = FlutterTts();
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

  /// Initialize both cloud audio player and local TTS engine.
  Future<void> initialize() async {
    try {
      // Cloud audio player
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

      // Local TTS engine (fallback)
      await _localTts.setLanguage('en-US');
      await _localTts.setSpeechRate(_speechRate * 0.5); // flutter_tts uses 0-1 range
      await _localTts.setPitch(_pitch);
      await _localTts.setVolume(1.0);

      _localTts.setCompletionHandler(() {
        _isSpeaking = false;
        notifyListeners();
        onSpeakingComplete?.call();
      });

      _localTts.setErrorHandler((msg) {
        debugPrint('❌ Local TTS error: $msg');
        _isSpeaking = false;
        notifyListeners();
      });

      _isInitialized = true;
      notifyListeners();
      debugPrint('🔊 TTS service initialized (cloud + local fallback)');
    } catch (e) {
      debugPrint('❌ TTS init failed: $e');
    }
  }

  /// Speak text using the local on-device TTS engine (offline fallback).
  Future<void> speak(String text) async {
    if (!_isInitialized || text.trim().isEmpty) return;

    try {
      _isSpeaking = true;
      notifyListeners();
      await _localTts.speak(text);
    } catch (e) {
      debugPrint('❌ Local TTS speak failed: $e');
      _isSpeaking = false;
      notifyListeners();
      onSpeakingComplete?.call();
    }
  }

  /// Add Base64 audio (edge-tts from backend) to the queue for playback.
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

  /// Process the audio stream queue (cloud TTS chunks).
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

  /// Stop all audio — both cloud player and local TTS.
  Future<void> stop() async {
    _shouldStop = true;
    _audioQueue.clear();
    await _player.stop();
    await _localTts.stop();
    _isSpeaking = false;
    notifyListeners();
    // Allow queueing again
    _shouldStop = false;
  }

  Future<void> setSpeechRate(double rate) async {
    _speechRate = rate;
    await _player.setPlaybackRate(rate);
    await _localTts.setSpeechRate(rate * 0.5); // flutter_tts 0-1 scale
    notifyListeners();
  }

  Future<void> setPitch(double pitch) async {
    _pitch = pitch;
    await _localTts.setPitch(pitch);
    notifyListeners();
  }

  @override
  void dispose() {
    _player.dispose();
    _localTts.stop();
    super.dispose();
  }
}
