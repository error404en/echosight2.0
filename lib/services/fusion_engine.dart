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
  DateTime _lastVoiceInputTime = DateTime.fromMillisecondsSinceEpoch(0);


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
      m == AssistantMode.surroundings || m == AssistantMode.sight;

  void setMode(AssistantMode newMode) {
    if (_currentMode == newMode) return;

    final wasProactive = _isProactiveMode(_currentMode);
    final willProactive = _isProactiveMode(newMode);
    _currentMode = newMode;

    // Haptic feedback on mode switch
    HapticFeedback.mediumImpact();
    notifyListeners();

    if (willProactive) {
      final bm = newMode == AssistantMode.sight ? 'sight' : 'surroundings';
      if (!surroundingsService.isActive) {
        surroundingsService.activate(backendMode: bm);
      } else {
        surroundingsService.setBackendMode(bm);
      }
      return;
    }

    if (wasProactive) {
      surroundingsService.deactivate();
    }

    // For navigate and emergency, trigger screen navigation
    if (newMode == AssistantMode.navigate) {
      ttsService.speak('${newMode.name} mode. ${newMode.description}. Say your destination.');
      onNavigateToScreen?.call('navigate');
      return;
    }
    if (newMode == AssistantMode.emergency) {
      ttsService.speak('${newMode.name} mode. ${newMode.description}.');
      onNavigateToScreen?.call('emergency');
      return;
    }

    ttsService.speak('${newMode.name} mode. ${newMode.description}.');

    // Auto-trigger immediate actions for interactive modes
    if (newMode == AssistantMode.reader) {
      Future.delayed(const Duration(milliseconds: 3000), _handleReadCommand);
    } else if (newMode == AssistantMode.identify) {
      Future.delayed(const Duration(milliseconds: 3000), () {
        _handleVoiceInput(query: "Please identify and describe the objects in front of me in detail.");
      });
    } else if (newMode == AssistantMode.surroundings || newMode == AssistantMode.sight) {
      surroundingsService.activate();
      Future.delayed(const Duration(milliseconds: 4000), () {
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

  /// Process voice commands that work globally across all modes.
  /// Returns true if the command was handled.
  bool _tryGlobalVoiceCommand(String query) {
    final q = query.toLowerCase().trim();
    
    // Navigation commands — directly navigate instead of just speaking
    if (q.contains('navigate to') || q.contains('take me to') || q.contains('start navigation')) {
       setMode(AssistantMode.navigate);
       return true;
    }

    // Emergency commands
    if (q.contains('emergency') || q.contains('help me') || q.contains('sos')) {
       setMode(AssistantMode.emergency);
       return true;
    }

    // Reading commands
    if (q.contains('read this') || q.contains('what does it say') || q.contains('read that')) {
       setMode(AssistantMode.reader);
       return true;
    }

    // Surroundings mode commands
    if (q.contains('surroundings') || q.contains('scan around') || q.contains('what is around me')) {
       setMode(AssistantMode.surroundings);
       return true;
    }

    // Sight mode commands
    if (q.contains('sight mode') || q.contains('be my eyes') || q.contains('sight stream')) {
       setMode(AssistantMode.sight);
       return true;
    }

    // Identify mode commands
    if (q.contains('identify') || q.contains('what is this') || q.contains('describe this')) {
       setMode(AssistantMode.identify);
       return true;
    }

    // Assistant mode commands
    if (q.contains('assistant mode') || q.contains('general mode') || q.contains('normal mode')) {
       setMode(AssistantMode.assistant);
       return true;
    }

    // Pause/resume surroundings
    if (q.contains('pause') || q.contains('quiet') || q.contains('mute')) {
      if (surroundingsService.isActive) {
        surroundingsService.pause();
      } else {
        ttsService.speak('No active scan to pause.');
      }
      return true;
    }
    if (q.contains('resume') || q == 'continue' || q.contains('unmute')) {
      if (surroundingsService.isActive) {
        surroundingsService.resume();
      } else {
        ttsService.speak('No paused scan to resume.');
      }
      return true;
    }

    // Stop everything
    if (q == 'stop' || q == 'shut up' || q == 'be quiet') {
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
      }
    };

    // Partial speech results for caption display
    speechService.onPartialResult = (text) {
      _currentCaption = text;
      notifyListeners();
    };

    // When TTS finishes speaking
    ttsService.onSpeakingComplete = () {
      if (_continuousMode) {
        // Auto-restart listening in continuous mode
        Future.delayed(const Duration(milliseconds: 500), () {
          if (_state == AssistantState.speaking) {
            _setState(AssistantState.idle);
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
        hasVisionContext: true,
      ));
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

      // CRITICAL FIX: If TTS has already finished playing all audio chunks
      // before [DONE] arrived, go straight to idle. Otherwise the app gets
      // permanently stuck in 'speaking' state with no callback to rescue it.
      if (ttsService.isSpeaking) {
        _setState(AssistantState.speaking);
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
        hasVisionContext: true,
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
      debugPrint('👁️ Surroundings: No changes detected');
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
      final rawFrame = await cameraService.captureRawFrame();
      if (rawFrame != null) {
        // Save frame to temp file for OCR
        final imageBase64 = await cameraService.captureFrame();

        if (webSocketService.isConnected && imageBase64 != null) {
          webSocketService.sendMessage(
            sessionId: _sessionId,
            query: 'Please read all the text visible in this image aloud. Organize it clearly.',
            imageBase64: imageBase64,
            mode: 'reader',
          );
          _setState(AssistantState.thinking);
        } else {
          ttsService.speak('I need a server connection to read text for you right now.');
          _setState(AssistantState.speaking);
        }
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
    _stateTimeoutTimer?.cancel();
    if (newState != AssistantState.idle) {
      _stateTimeoutTimer = Timer(const Duration(seconds: 30), () {
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
