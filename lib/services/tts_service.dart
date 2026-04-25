import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// TTS service with dual mode:
///   1. Cloud mode — plays Edge-TTS audio chunks from the backend
///   2. Local fallback — uses on-device flutter_tts when backend is unavailable
///
/// Includes pre-buffering to eliminate gaps between audio chunks and
/// interrupt-safe stop for seamless voice assistant experience.
class TtsService extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();
  final FlutterTts _localTts = FlutterTts();
  bool _isSpeaking = false;
  bool _isInitialized = false;

  double _speechRate = 1.0;
  double _pitch = 1.0;
  
  String _cloudVoiceName = 'en-US-JennyNeural';
  String _cloudTtsRate = '+0%';

  final Queue<Uint8List> _audioQueue = Queue();
  bool _shouldStop = false;
  bool _isPlayingChunk = false;

  // Pre-buffer: wait until we have enough chunks before starting playback
  // to eliminate gaps between chunks
  static const int _preBufferCount = 1;
  bool _preBuffering = false;
  Timer? _preBufferTimer;

  bool get isSpeaking => _isSpeaking;
  bool get isInitialized => _isInitialized;
  double get speechRate => _speechRate;
  double get pitch => _pitch;
  String get cloudVoiceName => _cloudVoiceName;
  String get cloudTtsRate => _cloudTtsRate;

  // Callbacks
  VoidCallback? onSpeakingComplete;

  /// Initialize both cloud audio player and local TTS engine.
  Future<void> initialize() async {
    try {
      // Cloud audio player
      _player.onPlayerStateChanged.listen((state) {
        if (state == PlayerState.playing) {
          _isPlayingChunk = true;
          if (!_isSpeaking) {
            _isSpeaking = true;
            notifyListeners();
          }
        } else if (state == PlayerState.completed) {
          _isPlayingChunk = false;
          // Don't set _isSpeaking = false here — wait for queue to drain
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
        HapticFeedback.lightImpact();
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

    // Stop any current audio first to prevent overlap
    await stop();

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
  /// Uses pre-buffering to collect chunks before starting playback,
  /// eliminating gaps between chunks.
  void playAudioBase64(String base64Audio) {
    if (!_isInitialized || _shouldStop) return;

    try {
      final bytes = base64Decode(base64Audio);
      _audioQueue.add(bytes);

      if (!_isSpeaking && !_isPlayingChunk) {
        if (!_preBuffering) {
          _preBuffering = true;
          // Start a short pre-buffer timer: either collect enough chunks
          // or start playing after 200ms, whichever comes first
          _preBufferTimer?.cancel();
          _preBufferTimer = Timer(const Duration(milliseconds: 200), () {
            _preBuffering = false;
            _processQueue();
          });
        }

        // If we've collected enough chunks, start immediately
        if (_audioQueue.length >= _preBufferCount) {
          _preBufferTimer?.cancel();
          _preBuffering = false;
          _processQueue();
        }
      }
    } catch (e) {
      debugPrint('❌ Failed to queue audio: $e');
    }
  }

  /// Process the audio stream queue (cloud TTS chunks).
  Future<void> _processQueue() async {
    if (_shouldStop || _audioQueue.isEmpty) {
      if (_audioQueue.isEmpty && !_isPlayingChunk) {
        // Queue fully drained AND no chunk playing — we're truly done
        if (_isSpeaking) {
          _isSpeaking = false;
          notifyListeners();
          HapticFeedback.lightImpact();
          onSpeakingComplete?.call();
        }
      }
      return;
    }

    if (_isPlayingChunk) return; // Wait for current chunk to finish

    try {
      _isPlayingChunk = true;
      _isSpeaking = true;
      notifyListeners();

      final nextChunk = _audioQueue.removeFirst();
      await _player.play(BytesSource(nextChunk));
    } catch (e) {
      debugPrint('❌ Chunk playback failed: $e');
      _isPlayingChunk = false;
      _processQueue(); // Skip and play next
    }
  }

  /// Stop all audio — both cloud player and local TTS.
  /// Interrupt-safe: clears everything immediately.
  Future<void> stop() async {
    _shouldStop = true;
    _preBufferTimer?.cancel();
    _preBuffering = false;
    _audioQueue.clear();
    _isPlayingChunk = false;
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

  void setCloudVoice(String voiceName) {
    _cloudVoiceName = voiceName;
    notifyListeners();
  }

  void setCloudTtsRate(String rate) {
    _cloudTtsRate = rate;
    notifyListeners();
  }

  @override
  void dispose() {
    _preBufferTimer?.cancel();
    _player.dispose();
    _localTts.stop();
    super.dispose();
  }
}
