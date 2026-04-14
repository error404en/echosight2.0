import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/chat_message.dart';
import '../models/vision_context.dart';
import 'camera_service.dart';
import 'detection_service.dart';
import 'ocr_service.dart';
import 'vision_context_builder.dart';
import 'websocket_service.dart';
import 'speech_service.dart';
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
  final LocationService locationService = LocationService();
  late final VisionContextBuilder _contextBuilder;

  // State
  AssistantState _state = AssistantState.idle;
  String _sessionId = 'session_${DateTime.now().millisecondsSinceEpoch}';
  final List<ChatMessage> _messages = [];
  String _currentCaption = '';
  String _streamingResponse = '';
  VisionContext? _lastVisionContext;
  bool _continuousMode = false;
  StreamSubscription? _responseSubscription;

  // Getters
  AssistantState get state => _state;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  String get currentCaption => _currentCaption;
  String get streamingResponse => _streamingResponse;
  VisionContext? get lastVisionContext => _lastVisionContext;
  bool get continuousMode => _continuousMode;
  String get sessionId => _sessionId;

  FusionEngine({
    required this.cameraService,
    required this.detectionService,
    required this.ocrService,
    required this.webSocketService,
    required this.speechService,
    required this.ttsService,
  }) {
    _contextBuilder = VisionContextBuilder(
      detectionService: detectionService,
      ocrService: ocrService,
    );
    _setupCallbacks();
  }

  void _setupCallbacks() {
    // When speech recording finishes
    speechService.onAudioCaptured = (audioBase64) {
      if (audioBase64.isNotEmpty) {
        _handleVoiceInput(audioBase64);
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
    await Future.wait([
      cameraService.initialize(),
      speechService.initialize(),
      ttsService.initialize(),
      locationService.initialize(),
      detectionService.initialize(),
    ]);
    ocrService.initialize();
    await webSocketService.connect();
  }

  /// Start listening for user speech.
  Future<void> startListening() async {
    if (_state == AssistantState.speaking) {
      await ttsService.stop();
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

  /// Handle recorded audio voice input
  Future<void> _handleVoiceInput(String audioBase64) async {
    _setState(AssistantState.processing);

    // 1. Capture current camera frame for context
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

    // 2.5 Fetch GPS
    Map<String, double>? gpsData;
    try {
      gpsData = await locationService.getCurrentLocation();
    } catch (e) {
      debugPrint('⚠️ GPS fetch failed: $e');
    }

    // 3. Send audio + vision context to backend
    if (webSocketService.isConnected) {
      _streamingResponse = '';
      webSocketService.sendMessage(
        sessionId: _sessionId,
        audioBase64: audioBase64,
        imageBase64: imageBase64,
        visionContext: visionContext?.toJson(),
        locationData: gpsData,
      );
      _setState(AssistantState.thinking);
    } else {
      _handleOfflineResponse("I need an internet connection to process voice right now.", visionContext);
    }
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
      _streamingResponse = chunk.substring(7).trim();
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

    // Default: append text chunk (for chat log)
    _streamingResponse += chunk;
    notifyListeners();
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
          ttsService.speak('I need an internet connection to read text for you right now.');
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
          'I need an internet connection for detailed analysis.';
    } else {
      response = 'I\'m currently offline. I can help with basic object detection. '
          'Connect to the internet for full assistance.';
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
