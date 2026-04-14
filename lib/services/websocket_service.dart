import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket service for streaming communication with FastAPI backend.
class WebSocketService extends ChangeNotifier {
  WebSocketChannel? _channel;
  bool _isConnected = false;
  String _serverUrl = 'ws://127.0.0.1:8000/ws/chat'; // ADB reverse via USB
  final _responseController = StreamController<String>.broadcast();
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;

  bool get isConnected => _isConnected;
  Stream<String> get responseStream => _responseController.stream;

  void setServerUrl(String url) {
    _serverUrl = url;
    notifyListeners();
  }

  String get serverUrl => _serverUrl;

  /// Connect to the backend WebSocket.
  Future<void> connect() async {
    if (_isConnected) return;

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_serverUrl));
      await _channel!.ready;
      _isConnected = true;
      _reconnectAttempts = 0;
      notifyListeners();

      debugPrint('✅ WebSocket connected to $_serverUrl');

      _channel!.stream.listen(
        (data) {
          final text = data.toString();
          _responseController.add(text);
        },
        onError: (error) {
          debugPrint('❌ WebSocket error: $error');
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('🔌 WebSocket closed');
          _handleDisconnect();
        },
      );
    } catch (e) {
      debugPrint('❌ WebSocket connection failed: $e');
      _isConnected = false;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  /// Send a chat payload with optional audio, image, text, and GPS.
  void sendMessage({
    required String sessionId,
    String? query,
    String? audioBase64,
    String? imageBase64,
    Map<String, dynamic>? visionContext,
    Map<String, double>? locationData,
  }) {
    if (!_isConnected || _channel == null) {
      debugPrint('⚠️ Cannot send — not connected');
      return;
    }

    final payload = {
      'session_id': sessionId,
      if (query != null) 'query': query,
      if (audioBase64 != null) 'audio': audioBase64,
      if (imageBase64 != null) 'image': imageBase64,
      if (visionContext != null) 'vision_context': visionContext,
      if (locationData != null) 'location': locationData,
    };

    _channel!.sink.add(jsonEncode(payload));
  }

  void _handleDisconnect() {
    _isConnected = false;
    notifyListeners();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('⚠️ Max reconnect attempts reached');
      return;
    }

    _reconnectTimer?.cancel();
    final delay = Duration(seconds: (2 * (_reconnectAttempts + 1)));
    _reconnectAttempts++;

    debugPrint('🔄 Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts)');

    _reconnectTimer = Timer(delay, () {
      connect();
    });
  }

  /// Disconnect from the backend.
  void disconnect() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _isConnected = false;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    _responseController.close();
    super.dispose();
  }
}
