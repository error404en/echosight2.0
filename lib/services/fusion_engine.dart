import 'dart:async';
import 'package:flutter/foundation.dart';
import 'surroundings_service.dart';
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
  AssistantMode _currentMode = AssistantMode.assistant;
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
  bool _sceneUnchangedSkipDone = false;
  bool _proactiveScanInFlight = false;

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

    ttsService.speak('${newMode.name} mode enabled');
  }

  /// Timer-driven scan for Surroundings / Sight (delta + scene_memory).
  Future<void> runProactiveSurroundingsScan() async {
    if (!surroundingsService.isActive ||
        surroundingsService.isPaused ||
        !webSocketService.isConnected) {
      return;
    }
    if (_surroundingsScanInFlight) return;
    if (ttsService.isSpeaking) return;
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
        locationData: payload['location'] as Map<String, double>?,
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

  bool _trySurroundingsVoiceCommand(String query) {
    final q = query.toLowerCase().trim();
    if (q.contains('pause') || q.contains('quiet') || q.contains('mute')) {
      surroundingsService.pause();
      return true;
    }
    if (q.contains('resume') || q == 'continue' || q.contains('unmute')) {
      surroundingsService.resume();
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
      await Future.wait([
        cameraService.initialize(),
        speechService.initialize(),
        ttsService.initialize(),
        locationService.initialize(),
        detectionService.initialize(),
      ]);
      ocrService.initialize();

      // Connect WebSocket (non-blocking — will auto-retry in background)
      webSocketService.connect();

      _isInitialized = true;
      notifyListeners();

      // Give user audio feedback about connection status after a short delay
      Future.delayed(const Duration(seconds: 3), () {
        if (webSocketService.isConnected) {
          ttsService.speak('EchoSight ready. Tap the microphone to speak.');
        } else {
          ttsService.speak(
            'EchoSight is running in offline mode. '
            'Please check your server connection in settings.',
          );
        }
      });
    } catch (e) {
      debugPrint('❌ Fusion engine init error: $e');
      ttsService.speak('Some services failed to start. Please restart the app.');
    }
  }

  /// Start listening for user speech.
  Future<void> startListening() async {
    if (_state == AssistantState.speaking) {
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
    notifyListeners();
  }

  /// Handle recorded audio voice input or text query
  Future<void> _handleVoiceInput({String? audioBase64, String? query}) async {
    if (query != null &&
        query.isNotEmpty &&
        surroundingsService.isActive &&
        _trySurroundingsVoiceCommand(query)) {
      _setState(AssistantState.idle);
      return;
    }

    _setState(AssistantState.processing);

    // 1. Check WebSocket connectivity FIRST
    if (!webSocketService.isConnected) {
      _handleOfflineVoice();
      return;
    }

    // Add query to local chat if we have text right away (on-device STT)
    if (query != null && query.isNotEmpty) {
      _addMessage(ChatMessage(
        content: query,
        role: MessageRole.user,
        hasVisionContext: true,
      ));
    }

    // 2. Capture current camera frame for context
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
    Map<String, double>? gpsData;
    try {
      gpsData = await locationService.getCurrentLocation();
    } catch (e) {
      debugPrint('⚠️ GPS fetch failed: $e');
    }

    // 4. Send payload to backend
    _streamingResponse = '';
    webSocketService.sendMessage(
      sessionId: _sessionId,
      query: query,
      audioBase64: audioBase64,
      imageBase64: imageBase64,
      visionContext: visionContext?.toJson(),
      locationData: gpsData,
      mode: _currentMode.name.toLowerCase(),
    );
    _setState(AssistantState.thinking);
  }

  /// Handle when user tries to speak but we're offline.
  void _handleOfflineVoice() {
    final msg = 'I cannot process voice commands right now because '
        'the server is not connected. Please check your connection in settings.';
    _addMessage(ChatMessage(
      content: msg,
      role: MessageRole.assistant,
    ));
    _streamingResponse = msg;
    ttsService.speak(msg);
    _setState(AssistantState.speaking);
  }

  /// (Legacy text input handler for typing if needed)
  Future<void> _handleUserSpeech(String userText) async {
    _setState(AssistantState.processing);
    _currentCaption = userText;

    // Add user message to chat
    _addMessage(ChatMessage(
      content: userText,
      role: MessageRole.user,
      hasVisionContext: true,
    ));

    // Check for special commands
    if (_isReadCommand(userText)) {
      await _handleReadCommand();
      return;
    }

    // 1. Capture current camera frame
    String? imageBase64;
    VisionContext? visionContext;

    try {
      imageBase64 = await cameraService.captureFrame();

      // 2. Build vision context (YOLO + OCR)
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

    // 3. Send to backend via WebSocket
    if (webSocketService.isConnected) {
      _streamingResponse = '';
      webSocketService.sendMessage(
        sessionId: _sessionId,
        query: userText,
        imageBase64: imageBase64,
        visionContext: visionContext?.toJson(),
      );
      _setState(AssistantState.thinking);
    } else {
      // Offline fallback
      _handleOfflineResponse(userText, visionContext);
    }
  }

  /// Handle streaming response chunks from the backend.
  void _handleResponseChunk(String chunk) {
    if (chunk == '[DONE]') {
      // Response complete
      if (_streamingResponse.isNotEmpty) {
        _addMessage(ChatMessage(
          content: _streamingResponse,
          role: MessageRole.assistant,
        ));
      }
      _setState(AssistantState.speaking);
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
      ttsService.speak(errorMsg);
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
      if (_state == AssistantState.thinking) {
        _setState(AssistantState.speaking);
      }
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
      // Surroundings / Sight mode: nothing changed, stay silent
      debugPrint('👁️ Surroundings: No changes detected');
      return;
    }

    // Default: append text chunk (for chat log)
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
    ttsService.speak(response);
    _setState(AssistantState.speaking);
  }

  /// Check if the user wants to read text.
  bool _isReadCommand(String text) {
    final lower = text.toLowerCase().trim();
    return lower.contains('read this') ||
        lower.contains('read that') ||
        lower.contains('what does this say') ||
        lower.contains('what does it say') ||
        lower.contains('read the text') ||
        lower.contains('read it');
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
  }

  void _setState(AssistantState newState) {
    _state = newState;
    notifyListeners();
  }

  @override
  void dispose() {
    _responseSubscription?.cancel();
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
}
