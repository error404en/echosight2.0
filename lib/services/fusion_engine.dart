import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/assistant_mode.dart';
import '../models/chat_message.dart';
import '../models/vision_context.dart';
import 'camera_service.dart';
import 'detection_service.dart';
import 'ocr_service.dart';
import 'vision_context_builder.dart';
import 'websocket_service.dart';
import 'speech_service.dart';
import 'surroundings_service.dart';
import 'tts_service.dart';
import 'location_service.dart';

/// The main fusion engine — orchestrates vision + voice + AI.
/// On user speech: capture frame → run YOLO + OCR → build context → send to backend → speak response.
///
/// This engine is the central nervous system of EchoSight, ensuring all services
/// work together seamlessly with no overlap or disconnected behavior.
class FusionEngine extends ChangeNotifier {
  final CameraService cameraService;
  final DetectionService detectionService;
  final OcrService ocrService;
  final WebSocketService webSocketService;
  final SpeechService speechService;
  final TtsService ttsService;
  final SurroundingsService surroundingsService;
  final LocationService locationService = LocationService();
  late final VisionContextBuilder _contextBuilder;

  // State
  AssistantState _state = AssistantState.idle;
  AssistantMode _currentMode = AssistantMode.auto;
  String _sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
  final List<ChatMessage> _messages = [];
  String _currentCaption = '';
  String _streamingResponse = '';
  VisionContext? _lastVisionContext;
  bool _continuousMode = false;
  StreamSubscription? _responseSubscription;
  bool _isInitialized = false;
  bool _sceneUnchangedSkipDone = false;
  bool _surroundingsScanInFlight = false;
  Timer? _heartbeatTimer;
  Timer? _stateTimeoutTimer;
  Timer? _speakingWatchdog;
  DateTime _lastVoiceInputTime = DateTime.fromMillisecondsSinceEpoch(0);
  int _unchangedCounter = 0;


  // Callback for screen navigation (set by HomeScreen)
  void Function(String screenName)? onNavigateToScreen;

  // Getters
  AssistantState get state => _state;
  AssistantMode get currentMode => _currentMode;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  String get currentCaption => _currentCaption;
  String get streamingResponse => _streamingResponse;
  VisionContext? get lastVisionContext => _lastVisionContext;
  bool get continuousMode => _continuousMode;
  String get sessionId => _sessionId;
  bool get isInitialized => _isInitialized;

  FusionEngine({
    required this.cameraService,
    required this.detectionService,
    required this.ocrService,
    required this.webSocketService,
    required this.speechService,
    required this.surroundingsService,
    required this.ttsService,
  }) {
    _contextBuilder = VisionContextBuilder(
      detectionService: detectionService,
      ocrService: ocrService,
    );
    _setupCallbacks();
    setSceneMemoryCallback((memory) {
      if (surroundingsService.isActive) {
        surroundingsService.updateSceneMemory(memory);
      }
    });
    surroundingsService.setAutoScanCallback(() {
      scheduleMicrotask(() => unawaited(runProactiveSurroundingsScan()));
    });
  }

  static bool _isProactiveMode(AssistantMode m) =>
      m == AssistantMode.surroundings || m == AssistantMode.sight || m == AssistantMode.auto;

  void setMode(AssistantMode newMode, {bool announce = true}) {
    if (_currentMode == newMode) return;

    final wasProactive = _isProactiveMode(_currentMode);
    final willProactive = _isProactiveMode(newMode);
    _currentMode = newMode;

    // Haptic feedback on mode switch
    HapticFeedback.mediumImpact();
    notifyListeners();

    if (willProactive) {
      if (newMode == AssistantMode.auto) {
        // Auto mode uses its own proactive scan loop — not the surroundings service
        // but we do activate surroundings service to reuse its timer/scan infrastructure
        if (!surroundingsService.isActive) {
          surroundingsService.activate(backendMode: 'auto');
        } else {
          surroundingsService.setBackendMode('auto');
        }
      } else {
        final bm = newMode == AssistantMode.sight ? 'sight' : 'surroundings';
        if (!surroundingsService.isActive) {
          surroundingsService.activate(backendMode: bm);
        } else {
          surroundingsService.setBackendMode(bm);
        }
      }
      return;
    }

    if (wasProactive) {
      surroundingsService.deactivate();
    }

    // For navigate and emergency, trigger screen navigation
    if (newMode == AssistantMode.navigate) {
      if (announce) ttsService.speak('${newMode.name} mode. ${newMode.description}. Say your destination.');
      onNavigateToScreen?.call('navigate');
      return;
    }
    if (newMode == AssistantMode.emergency) {
      if (announce) ttsService.speak('${newMode.name} mode. ${newMode.description}.');
      onNavigateToScreen?.call('emergency');
      return;
    }

    if (announce) ttsService.speak('${newMode.name} mode. ${newMode.description}.');

    // Chat mode — just announce and wait for user speech (no camera needed)
    if (newMode == AssistantMode.chat) {
      return;
    }

    // Auto-trigger immediate actions for interactive modes
    if (newMode == AssistantMode.reader) {
      Future.delayed(const Duration(milliseconds: 200), _handleReadCommand);
    } else if (newMode == AssistantMode.identify) {
      Future.delayed(const Duration(milliseconds: 200), () {
        _handleVoiceInput(query: "Please identify and describe the objects in front of me in detail.");
      });
    } else if (newMode == AssistantMode.surroundings || newMode == AssistantMode.sight) {
      surroundingsService.activate();
      Future.delayed(const Duration(milliseconds: 200), () {
        runProactiveSurroundingsScan();
      });
    }
  }

  /// Cycle to the next mode — used by swipe gestures.
  void cycleMode({bool forward = true}) {
    final modes = AssistantMode.values;
    final currentIndex = modes.indexOf(_currentMode);
    final nextIndex = forward
        ? (currentIndex + 1) % modes.length
        : (currentIndex - 1 + modes.length) % modes.length;
    setMode(modes[nextIndex]);
  }

  /// Timer-driven scan for Surroundings / Sight (delta + scene_memory).
  Future<void> runProactiveSurroundingsScan() async {
    if (!surroundingsService.isActive ||
        surroundingsService.isPaused ||
        !webSocketService.isConnected) {
      return;
    }
    if (_surroundingsScanInFlight) return;

    // Instead of bailing when TTS is speaking, schedule retry after TTS completes
    if (ttsService.isSpeaking) {
      _scheduleScanAfterTts();
      return;
    }
    if (state == AssistantState.listening || state == AssistantState.processing) {
      return;
    }

    _surroundingsScanInFlight = true;
    try {
      final payload = await surroundingsService.buildScanPayload();
      _streamingResponse = '';
      webSocketService.sendMessage(
        sessionId: _sessionId,
        query: payload['query'] as String,
        imageBase64: payload['image'] as String?,
        visionContext: payload['vision_context'] as Map<String, dynamic>?,
        locationData: payload['location'] as Map<String, dynamic>?,
        mode: payload['mode'] as String,
        sceneMemory: payload['scene_memory'] as String?,
      );
      _setState(AssistantState.thinking);
    } catch (e) {
      debugPrint('⚠️ Proactive surroundings scan failed: $e');
    } finally {
      _surroundingsScanInFlight = false;
    }
  }

  /// Schedule a scan retry once TTS finishes speaking.
  void _scheduleScanAfterTts() {
    final originalCallback = ttsService.onSpeakingComplete;
    ttsService.onSpeakingComplete = () {
      ttsService.onSpeakingComplete = originalCallback;
      
      // CRITICAL: Execute the original callback to ensure the system returns to 'idle'
      originalCallback?.call();
      
      // Re-check after a brief delay
      Future.delayed(const Duration(milliseconds: 500), () {
        if (surroundingsService.isActive && !surroundingsService.isPaused) {
          runProactiveSurroundingsScan();
        }
      });
    };
  }

  /// Normalize spoken text: strip punctuation, STT artifacts, filler words,
  /// and collapse whitespace so voice commands match naturally.
  static String _normalizeQuery(String raw) {
    var q = raw.toLowerCase().trim();

    // Remove common STT punctuation artifacts
    q = q.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');

    // Remove spoken-out punctuation / symbols that STT sometimes transcribes literally
    final spokenSymbols = [
      'hashtag', 'hash', 'pound sign', 'at sign', 'ampersand',
      'exclamation mark', 'question mark', 'period', 'comma',
      'full stop', 'dot', 'colon', 'semicolon', 'dash',
    ];
    for (final sym in spokenSymbols) {
      q = q.replaceAll(sym, ' ');
    }

    // Remove common filler words that STT captures but add no intent
    final fillers = [
      'um', 'uh', 'uhh', 'umm', 'hmm', 'hm', 'er', 'ah', 'ahh',
      'like', 'you know', 'basically', 'actually', 'so', 'well',
      'okay', 'ok', 'right', 'yeah', 'yep', 'alright',
      'please', 'kindly', 'can you', 'could you', 'would you',
      'i want to', 'i wanna', 'i would like to', 'i need to',
      'hey', 'hi', 'hello', 'yo',
    ];
    for (final f in fillers) {
      // Use word boundaries to avoid removing parts of real words
      q = q.replaceAll(RegExp('\\b${RegExp.escape(f)}\\b'), ' ');
    }

    // Collapse whitespace
    q = q.replaceAll(RegExp(r'\s+'), ' ').trim();
    return q;
  }

  /// Check if normalized query contains ANY of the trigger phrases.
  static bool _matchesAny(String q, List<String> triggers) {
    return triggers.any((t) => q.contains(t));
  }

  /// Process voice commands that work globally across all modes.
  /// Uses normalized text and natural language triggers for seamless voice UX.
  /// Returns true if the command was handled.
  bool _tryGlobalVoiceCommand(String query) {
    final q = _normalizeQuery(query);
    // Keep raw lowercase for exact-match fallbacks
    final raw = query.toLowerCase().trim();

    // ── Navigation ──────────────────────────────────────
    if (_matchesAny(q, [
      'navigate to', 'take me to', 'start navigation',
      'give me directions', 'how do i get to', 'walk me to',
      'guide me to', 'directions to', 'i need to go to',
      'navigation mode', 'go to',
    ])) {
      setMode(AssistantMode.navigate);
      return true;
    }

    // ── Emergency ────────────────────────────────────────
    if (_matchesAny(q, [
      'emergency', 'help me', 'sos', 'i m in danger',
      'i am in danger', 'call for help', 'danger',
      'save me', 'i m lost', 'i am lost', 'panic',
      'i m scared', 'i am scared', 'emergency mode',
    ])) {
      setMode(AssistantMode.emergency);
      return true;
    }

    // ── Reader ───────────────────────────────────────────
    if (_matchesAny(q, [
      'read this', 'read that', 'what does it say',
      'read the text', 'read the sign', 'read out loud',
      'read for me', 'what is written', 'whats written',
      'read the label', 'read the screen', 'read the menu',
      'read mode', 'reader mode', 'read it',
    ])) {
      setMode(AssistantMode.reader);
      return true;
    }

    // ── Surroundings ─────────────────────────────────────
    if (_matchesAny(q, [
      'surroundings', 'scan around', 'what is around me',
      'whats around me', 'look around', 'look around for me',
      'scan my surroundings', 'describe my surroundings',
      'surroundings mode', 'tell me what is around',
      'what do you see around', 'scan the area',
      'describe the area', 'what is nearby',
    ])) {
      setMode(AssistantMode.surroundings);
      return true;
    }

    // ── Sight ────────────────────────────────────────────
    if (_matchesAny(q, [
      'sight mode', 'be my eyes', 'sight stream',
      'see for me', 'i want to see', 'show me everything',
      'full vision', 'vision mode', 'detailed sight',
      'act as my eyes', 'become my eyes', 'lend me your eyes',
    ])) {
      setMode(AssistantMode.sight);
      return true;
    }

    // ── Identify ─────────────────────────────────────────
    if (_matchesAny(q, [
      'identify', 'what is this', 'describe this',
      'what am i holding', 'what is in front of me',
      'tell me about this', 'what is that',
      'identify this', 'identify mode', 'recognize this',
      'what am i looking at', 'what do you see here',
    ])) {
      setMode(AssistantMode.identify);
      return true;
    }

    // ── Auto ─────────────────────────────────────────────
    if (_matchesAny(q, [
      'auto mode', 'automatic mode', 'smart mode',
      'switch to auto', 'go automatic', 'be smart',
      'auto intelligence', 'intelligent mode',
    ])) {
      setMode(AssistantMode.auto);
      return true;
    }

    // ── Assistant ─────────────────────────────────────────
    if (_matchesAny(q, [
      'assistant mode', 'general mode', 'normal mode',
      'default mode', 'regular mode', 'standard mode',
      'go back to normal', 'back to assistant',
      'switch to assistant',
    ])) {
      setMode(AssistantMode.assistant);
      return true;
    }

    // ── Chat ─────────────────────────────────────────────
    if (_matchesAny(q, [
      'chat mode', 'lets chat', 'just talk', 'voice chat',
      'talk to me', 'chat with me', 'have a conversation',
      'general chat', 'free talk', 'conversation mode',
      'talk mode', 'i want to talk', 'lets have a chat',
      'chitchat', 'chit chat', 'just chatting',
    ])) {
      setMode(AssistantMode.chat);
      return true;
    }

    // ── Pause / Resume / Stop (utility) ──────────────────
    if (_matchesAny(q, ['pause', 'quiet', 'mute', 'shh', 'hush', 'silence', 'hold on', 'wait'])) {
      if (surroundingsService.isActive) {
        surroundingsService.pause();
      } else {
        ttsService.stop();
      }
      return true;
    }

    if (_matchesAny(q, ['resume', 'continue', 'unmute', 'go on', 'keep going', 'carry on', 'start again'])) {
      if (surroundingsService.isActive) {
        surroundingsService.resume();
      } else {
        ttsService.speak('No paused scan to resume.');
      }
      return true;
    }

    if (q == 'stop' || q == 'shut up' || q == 'be quiet' ||
        raw == 'stop' || raw == 'shut up' || raw == 'be quiet' ||
        q == 'enough' || q == 'thats enough') {
      ttsService.stop();
      if (surroundingsService.isActive) surroundingsService.pause();
      return true;
    }

    return false;
  }

  void _setupCallbacks() {
    // When cloud speech recording finishes
    speechService.onAudioCaptured = (audioBase64) {
      if (audioBase64.isNotEmpty) {
        _handleVoiceInput(audioBase64: audioBase64);
      }
    };

    // When on-device speech recognition finishes
    speechService.onTextResult = (text) {
      if (text.isNotEmpty && text != 'Listening...') {
        // Haptic to confirm speech was recognized
        HapticFeedback.selectionClick();
        _handleVoiceInput(query: text);
      } else {
        _setState(AssistantState.idle);
        if (_continuousMode) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (_state == AssistantState.idle) startListening();
          });
        }
      }
    };

    // Partial speech results for caption display
    speechService.onPartialResult = (text) {
      _currentCaption = text;
      notifyListeners();
    };

    // When TTS finishes speaking
    ttsService.onSpeakingComplete = () {
      _speakingWatchdog?.cancel();
      if (_continuousMode) {
        // Auto-restart listening in continuous mode
        _streamingResponse = '';
        _currentCaption = '';
        _setState(AssistantState.idle);
        Future.delayed(const Duration(milliseconds: 300), () {
          if (_state == AssistantState.idle) {
            startListening();
          }
        });
      } else {
        // Clear streaming response text after speech is done
        // so UI doesn't show stale text
        _streamingResponse = '';
        _currentCaption = '';
        _setState(AssistantState.idle);
      }
    };

    // Listen to WebSocket responses
    _responseSubscription = webSocketService.responseStream.listen((chunk) {
      _handleResponseChunk(chunk);
    });
  }

  /// Initialize all services.
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Initialize sequentially to avoid Android Permission Dialog lockups
      await cameraService.initialize();
      await ttsService.initialize();
      await speechService.initialize();
      await locationService.initialize();
      await detectionService.initialize();
      
      ocrService.initialize();

      // Connect WebSocket (non-blocking — will auto-retry in background)
      webSocketService.connect();

      _isInitialized = true;
      notifyListeners();

      // Start the heartbeat timer — subtle haptic every 30s when idle
      // so the user knows the app is alive
      _startHeartbeat();

      // Give user audio feedback about connection status after a short delay
      Future.delayed(const Duration(seconds: 3), () {
        if (webSocketService.isConnected) {
          ttsService.speak(
            'EchoSight ready. '
            'Tap anywhere to speak. '
            'Swipe left or right to change modes.',
          );
          // Auto mode is the default — activate its proactive scan now that
          // all services are initialized and WebSocket is connected.
          if (_currentMode == AssistantMode.auto) {
            Future.delayed(const Duration(seconds: 5), () {
              if (_currentMode == AssistantMode.auto && !surroundingsService.isActive) {
                surroundingsService.activate(backendMode: 'auto');
              }
            });
          }
        } else {
          ttsService.speak(
            'EchoSight is running in offline mode. '
            'Tap anywhere to speak. '
            'Check your server connection in settings.',
          );
        }
      });
    } catch (e) {
      debugPrint('❌ Fusion engine init error: $e');
      ttsService.speak('Some services failed to start. Please restart the app.');
    }
  }

  /// Start a heartbeat — subtle haptic feedback when idle so
  /// the blind user knows the app is alive and responsive.
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_state == AssistantState.idle && !ttsService.isSpeaking) {
        HapticFeedback.selectionClick();
      }
    });
  }

  /// Start listening for user speech.
  Future<void> startListening() async {
    // Allow the user to interrupt ANY state by tapping the mic.
    // This prevents the app from ever being permanently unresponsive.
    if (_state == AssistantState.speaking || _state == AssistantState.thinking || _state == AssistantState.processing) {
      await ttsService.stop();
    }

    // Check mic availability
    if (!speechService.isAvailable) {
      ttsService.speak('Microphone is not available. Please grant permission and restart.');
      return;
    }

    _setState(AssistantState.listening);
    _currentCaption = '';
    _streamingResponse = '';
    await speechService.startListening();
  }

  /// Stop listening.
  Future<void> stopListening() async {
    await speechService.stopListening();
  }

  /// Toggle continuous listening mode.
  void toggleContinuousMode() {
    _continuousMode = !_continuousMode;
    HapticFeedback.mediumImpact();
    notifyListeners();
  }

  /// Handle recorded audio voice input or text query
  Future<void> _handleVoiceInput({String? audioBase64, String? query}) async {
    // Debounce to prevent dual-execution from local STT & cloud STT overlapping.
    // This stops concurrent camera capture requests which deadlock the camera feed.
    final now = DateTime.now();
    if (now.difference(_lastVoiceInputTime).inMilliseconds < 1000) {
      debugPrint('⚠️ Ignoring concurrent voice input trigger');
      return;
    }
    _lastVoiceInputTime = now;

    if (query != null && query.isNotEmpty) {
      final normalized = _normalizeQuery(query);
      
      // Intelligence/Noise Filter:
      // Drop single letters, sighs, or pure filler words that result in empty/tiny queries
      // to avoid rate limits and battery drain during Continuous Listening.
      if (normalized.length < 2) {
        debugPrint('🧠 Filtering out background noise/useless data: "$query"');
        _setState(AssistantState.idle);
        if (_continuousMode) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (_state == AssistantState.idle) startListening();
          });
        }
        return;
      }

      if (_tryGlobalVoiceCommand(query)) {
        _setState(AssistantState.idle);
        return;
      }
    }

    _setState(AssistantState.processing);

    // Add query to local chat if we have text right away (on-device STT)
    if (query != null && query.isNotEmpty) {
      // Clear the caption to show it was captured
      _currentCaption = query;
      notifyListeners();

      _addMessage(ChatMessage(
        content: query,
        role: MessageRole.user,
        hasVisionContext: _currentMode != AssistantMode.chat,
      ));
    }

    // ── CHAT MODE: skip camera entirely for faster general conversations ──
    if (_currentMode == AssistantMode.chat) {
      if (!webSocketService.isConnected) {
        _handleOfflineResponse(query ?? '', null);
        return;
      }

      _streamingResponse = '';
      webSocketService.sendMessage(
        sessionId: _sessionId,
        query: query,
        audioBase64: audioBase64,
        mode: 'chat',
        voice: ttsService.cloudVoiceName,
        ttsRate: ttsService.cloudTtsRate,
      );
      _setState(AssistantState.thinking);
      return;
    }

    // 1. Capture current camera frame for context
    String? imageBase64;
    VisionContext? visionContext;

    try {
      // Invalidate cache to get a fresh single capture (avoids double autofocus)
      cameraService.invalidateCache();
      imageBase64 = await cameraService.captureFrame();

      // Build vision context (YOLO + OCR)
      if (cameraService.isInitialized) {
        final rawFrame = await cameraService.captureRawFrame();
        if (rawFrame != null) {
          visionContext = await _contextBuilder.buildContext(rawFrame);
        }
      }

      // Fallback to mock context if detection service not ready
      if (visionContext == null || visionContext.isEmpty) {
        visionContext = _contextBuilder.buildMockContext();
      }

      _lastVisionContext = visionContext;
    } catch (e) {
      debugPrint('⚠️ Frame capture failed: $e');
    }

    // 3. Fetch GPS
    Map<String, dynamic>? gpsData;
    try {
      gpsData = await locationService.getCurrentLocation();
    } catch (e) {
      debugPrint('⚠️ GPS fetch failed: $e');
    }

    // 4. Send payload to backend or handle offline
    if (!webSocketService.isConnected) {
      _handleOfflineResponse(query ?? '', visionContext);
      return;
    }

    _streamingResponse = '';
    webSocketService.sendMessage(
      sessionId: _sessionId,
      query: query,
      audioBase64: audioBase64,
      imageBase64: imageBase64,
      visionContext: visionContext?.toJson(),
      locationData: gpsData,
      mode: _currentMode.name.toLowerCase(),
      sceneMemory: (_isProactiveMode(_currentMode) && surroundingsService.isActive)
          ? surroundingsService.lastSceneDescription
          : null,
      voice: ttsService.cloudVoiceName,
      ttsRate: ttsService.cloudTtsRate,
    );
    _setState(AssistantState.thinking);
  }


  /// Handle streaming response chunks from the backend.
  void _handleResponseChunk(String chunk) {
    if (chunk == '[DONE]') {
      if (_sceneUnchangedSkipDone) {
        _sceneUnchangedSkipDone = false;
        return;
      }
      // Response complete
      if (_streamingResponse.isNotEmpty) {
        _addMessage(ChatMessage(
          content: _streamingResponse,
          role: MessageRole.assistant,
        ));
      }
      // Clear the user caption since we're done processing
      _currentCaption = '';

      // If TTS is still playing audio chunks, transition to speaking and
      // start a watchdog timer. The onSpeakingComplete callback will move
      // us to idle when playback finishes. The watchdog catches the race
      // condition where TTS finishes between the isSpeaking check and
      // the callback registration.
      if (ttsService.isSpeaking) {
        _setState(AssistantState.speaking);
        // Watchdog: if onSpeakingComplete never fires (race condition),
        // recover to idle after 2 seconds of no audio activity.
        _speakingWatchdog?.cancel();
        _speakingWatchdog = Timer(const Duration(seconds: 2), () {
          if (_state == AssistantState.speaking && !ttsService.isSpeaking) {
            debugPrint('🔧 Speaking watchdog: TTS finished but callback missed, recovering');
            _streamingResponse = '';
            _currentCaption = '';
            _setState(AssistantState.idle);
          }
        });
      } else {
        _streamingResponse = '';
        _setState(AssistantState.idle);
      }
      return;
    }

    if (chunk.startsWith('[ERROR]')) {
      final errorMsg = chunk.substring(7).trim();
      _streamingResponse = errorMsg;
      _addMessage(ChatMessage(
        content: 'Error: $errorMsg',
        role: MessageRole.assistant,
      ));
      // Speak the error via local TTS so user always hears feedback
      _currentCaption = '';
      ttsService.speak(errorMsg);
      _setState(AssistantState.speaking);
      return;
    }

    if (chunk.startsWith('[COMMAND_SWITCH_MODE:')) {
      final tagEnd = chunk.indexOf(']');
      if (tagEnd != -1) {
        final modeStr = chunk.substring(21, tagEnd).trim().toLowerCase();
        AssistantMode? newMode;
        switch (modeStr) {
          case 'navigate': newMode = AssistantMode.navigate; break;
          case 'emergency': newMode = AssistantMode.emergency; break;
          case 'reader': newMode = AssistantMode.reader; break;
          case 'surroundings': newMode = AssistantMode.surroundings; break;
          case 'sight': newMode = AssistantMode.sight; break;
          case 'identify': newMode = AssistantMode.identify; break;
          case 'chat': newMode = AssistantMode.chat; break;
          case 'assistant': newMode = AssistantMode.assistant; break;
          case 'auto': newMode = AssistantMode.auto; break;
        }
        if (newMode != null && newMode != _currentMode) {
          debugPrint('🧠 AI Intent Router: Auto-switching to $newMode');
          setMode(newMode, announce: false);
        }
      }
      return;
    }

    if (chunk == '[RATE_LIMIT]') {
      _streamingResponse = 'API quota reached. Please wait a moment.';
      _addMessage(ChatMessage(
        content: 'Rate limit reached. Try speaking to pause or wait.',
        role: MessageRole.assistant,
      ));
      _currentCaption = '';
      ttsService.speak('API rate limit reached. Pausing automatic scans.');
      if (surroundingsService.isActive && !surroundingsService.isPaused) {
        surroundingsService.pause();
      }
      _setState(AssistantState.speaking);
      return;
    }

    if (chunk.startsWith('[TRANSCRIPT]')) {
      final transcript = chunk.substring(12).trim();
      _currentCaption = transcript;
      _addMessage(ChatMessage(
        content: transcript,
        role: MessageRole.user,
        hasVisionContext: _currentMode != AssistantMode.chat,
      ));
      notifyListeners();
      return;
    }

    if (chunk.startsWith('[AUDIO]')) {
      final audioBase64 = chunk.substring(7).trim();
      // Clear user caption once we start getting audio responses
      // to prevent overlap between what user said and AI response
      _currentCaption = '';
      // Don't flicker state — only transition to speaking on [DONE]
      // The TTS service handles speaking state independently
      ttsService.playAudioBase64(audioBase64);
      return;
    }

    if (chunk == '[NAV_ARRIVED]') {
      // Navigation arrival — handled by NavigationService via Provider
      debugPrint('📍 Navigation: Arrived at destination');
      return;
    }

    if (chunk.startsWith('[SCENE_MEMORY]')) {
      // Surroundings / Sight mode: update scene memory via callback
      final memory = chunk.substring(14).trim();
      _onSceneMemoryUpdate?.call(memory);
      return;
    }

    if (chunk == '[SCENE_UNCHANGED]') {
      _streamingResponse = '';
      _sceneUnchangedSkipDone = true;
      _setState(AssistantState.idle);
      _unchangedCounter++;
      // Every 3rd unchanged scan, give a gentle ambient reassurance
      // so the user never feels abandoned in silence
      if (_unchangedCounter % 3 == 0) {
        ttsService.speak("Everything looks the same around you, you're good.");
      }
      debugPrint('👁️ Surroundings: No changes detected ($_unchangedCounter)');
      return;
    }

    // Default: append text chunk (for chat log)
    // Clear user caption once response starts streaming
    if (_streamingResponse.isEmpty && _currentCaption.isNotEmpty) {
      _currentCaption = '';
    }
    _streamingResponse += chunk;
    notifyListeners();
  }

  // Callback for surroundings scene memory updates
  void Function(String)? _onSceneMemoryUpdate;
  void setSceneMemoryCallback(void Function(String) callback) {
    _onSceneMemoryUpdate = callback;
  }

  /// Handle "read this" and similar OCR commands.
  Future<void> _handleReadCommand() async {
    _setState(AssistantState.processing);

    try {
      cameraService.invalidateCache();
      final imageBase64 = await cameraService.captureFrame();

      if (webSocketService.isConnected && imageBase64 != null) {
        _streamingResponse = '';
        webSocketService.sendMessage(
          sessionId: _sessionId,
          query: 'Please read all the text visible in this image aloud. Organize it clearly.',
          imageBase64: imageBase64,
          mode: 'reader',
          voice: ttsService.cloudVoiceName,
          ttsRate: ttsService.cloudTtsRate,
        );
        _setState(AssistantState.thinking);
      } else {
        ttsService.speak('I need a server connection to read text for you right now.');
        _setState(AssistantState.speaking);
      }
    } catch (e) {
      ttsService.speak('Sorry, I could not capture the image to read.');
      _setState(AssistantState.speaking);
    }
  }

  /// Offline fallback responses.
  void _handleOfflineResponse(String query, VisionContext? context) {
    String response;

    if (context != null && context.hasObjects) {
      final objectNames = context.objects.map((o) => o.label).toSet().toList();
      response = 'I can see ${objectNames.join(", ")} in front of you. '
          'I need a server connection for detailed analysis.';
    } else {
      response = 'I\'m currently offline. I can help with basic object detection. '
          'Connect to the server for full assistance.';
    }

    _addMessage(ChatMessage(
      content: response,
      role: MessageRole.assistant,
    ));
    _streamingResponse = response;
    _currentCaption = '';
    ttsService.speak(response);
    _setState(AssistantState.speaking);
  }


  /// Add a message to the conversation.
  void _addMessage(ChatMessage message) {
    _messages.add(message);
    notifyListeners();
  }

  /// Clear conversation history.
  void clearConversation() {
    _messages.clear();
    _sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
    _streamingResponse = '';
    _currentCaption = '';
    notifyListeners();
    ttsService.speak('Conversation cleared.');
  }

  void _setState(AssistantState newState) {
    if (_state == newState) return;

    _state = newState;

    // Safety timeout: if the app stays in a non-idle state for too long,
    // auto-recover to idle to prevent the app from going permanently silent.
    // 60s is generous enough for long vision+TTS responses but still catches
    // genuine stuck states.
    _stateTimeoutTimer?.cancel();
    if (newState != AssistantState.idle) {
      _stateTimeoutTimer = Timer(const Duration(seconds: 60), () {
        if (_state != AssistantState.idle && !ttsService.isSpeaking) {
          debugPrint('⚠️ State timeout: stuck in $_state, recovering to idle');
          _streamingResponse = '';
          _currentCaption = '';
          _state = AssistantState.idle;
          notifyListeners();
        }
      });
    }

    // Haptic feedback on every state transition so blind user
    // knows something changed
    switch (newState) {
      case AssistantState.listening:
        HapticFeedback.mediumImpact();
        break;
      case AssistantState.processing:
      case AssistantState.thinking:
        HapticFeedback.lightImpact();
        break;
      case AssistantState.speaking:
        HapticFeedback.selectionClick();
        break;
      case AssistantState.idle:
        // No haptic for idle — it's the resting state
        break;
    }

    notifyListeners();
  }

  @override
  void dispose() {
    _responseSubscription?.cancel();
    _heartbeatTimer?.cancel();
    _stateTimeoutTimer?.cancel();
    _speakingWatchdog?.cancel();
    super.dispose();
  }
}

/// States for the voice assistant state machine.
enum AssistantState {
  idle,
  listening,
  processing,
  thinking,
  speaking,
}

extension AssistantStateX on AssistantState {
  String get label {
    switch (this) {
      case AssistantState.idle:
        return 'Tap to speak';
      case AssistantState.listening:
        return 'Listening...';
      case AssistantState.processing:
        return 'Processing...';
      case AssistantState.thinking:
        return 'Thinking...';
      case AssistantState.speaking:
        return 'Speaking...';
    }
  }

  String get emoji {
    switch (this) {
      case AssistantState.idle:
        return '🎤';
      case AssistantState.listening:
        return '👂';
      case AssistantState.processing:
        return '⚙️';
      case AssistantState.thinking:
        return '🧠';
      case AssistantState.speaking:
        return '🔊';
    }
  }

  /// Accessibility label for screen readers
  String get accessibilityLabel {
    switch (this) {
      case AssistantState.idle:
        return 'Ready. Tap anywhere to speak.';
      case AssistantState.listening:
        return 'Listening to you now.';
      case AssistantState.processing:
        return 'Processing your request.';
      case AssistantState.thinking:
        return 'EchoSight is thinking.';
      case AssistantState.speaking:
        return 'EchoSight is speaking. Tap to interrupt.';
    }
  }
}
