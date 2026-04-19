import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// WebSocket service for streaming communication with FastAPI backend.
/// Auto-detects emulator vs physical device and sets the correct URL.
class WebSocketService extends ChangeNotifier {
  WebSocketChannel? _channel;
  bool _isConnected = false;
  String _serverUrl = '';
  String _lastError = '';
  final _responseController = StreamController<String>.broadcast();
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;

  bool get isConnected => _isConnected;
  String get lastError => _lastError;
  Stream<String> get responseStream => _responseController.stream;

  WebSocketService() {
    _loadSavedUrl();
  }

  Future<void> _loadSavedUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString('serverUrl');
      if (savedUrl != null && savedUrl.isNotEmpty) {
        _serverUrl = savedUrl;
        debugPrint('Loaded saved server URL: $_serverUrl');
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> saveServerUrl(String url) async {
    _serverUrl = url;
    _lastError = '';
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('serverUrl', url);
      debugPrint('Saved server URL: $url');
    } catch (_) {}
    
    // Reconnect to the new URL if we were trying to connect
    if (_isConnected) {
      disconnect();
    }
    connect();
  }

  void setServerUrl(String url) {
    _serverUrl = url;
    _lastError = '';
    notifyListeners();
  }

  String get serverUrl => _serverUrl;

  /// Auto-detect the best server URL based on platform.
  /// Tries localhost, emulator IP, and discovers LAN IPs for WiFi connections.
  Future<String> _detectServerUrl() async {
    if (_serverUrl.isNotEmpty) return _serverUrl;

    // Try common addresses in order of likelihood
    final candidates = <String>[];

    if (Platform.isAndroid) {
      // 1. ADB reverse (USB debugging)
      candidates.add('ws://127.0.0.1:8000/ws/chat');
      // 2. Android emulator special IP
      candidates.add('ws://10.0.2.2:8000/ws/chat');
    } else {
      candidates.add('ws://127.0.0.1:8000/ws/chat');
    }

    // 3. WiFi — try the PC's local IP
    //    Updated to correct WiFi IP for current session.
    candidates.add('ws://192.168.0.103:8000/ws/chat');

    // Try each candidate with a quick health check
    for (final url in candidates) {
      final httpUrl = url
          .replaceFirst('ws://', 'http://')
          .replaceFirst('wss://', 'https://')
          .replaceFirst('/ws/chat', '/health');

      try {
        final response = await http
            .get(Uri.parse(httpUrl))
            .timeout(const Duration(seconds: 3));
        if (response.statusCode == 200) {
          debugPrint('✅ Backend found at $httpUrl');
          _serverUrl = url;
          notifyListeners();
          return url;
        }
      } catch (_) {
        debugPrint('⏭️ Backend not reachable at $httpUrl');
      }
    }

    // Fallback — set to first candidate
    _serverUrl = candidates.first;
    return _serverUrl;
  }

  /// Get the HTTP base URL derived from the WebSocket URL.
  String get httpBaseUrl {
    final url = _serverUrl.isNotEmpty ? _serverUrl : 'ws://127.0.0.1:8000/ws/chat';
    return url
        .replaceFirst('ws://', 'http://')
        .replaceFirst('wss://', 'https://')
        .split('/ws/')[0];
  }

  /// Connect to the backend WebSocket.
  Future<void> connect() async {
    if (_isConnected) return;

    try {
      // Auto-detect URL if not set
      if (_serverUrl.isEmpty) {
        await _detectServerUrl();
      }

      // Health check first — give a clear error if backend is not running
      String healthUrl = _serverUrl
          .replaceFirst('ws://', 'http://')
          .replaceFirst('wss://', 'https://')
          .replaceFirst('/ws/chat', '/health');

      try {
        final healthResp = await http
            .get(Uri.parse(healthUrl))
            .timeout(const Duration(seconds: 5));
        if (healthResp.statusCode != 200) {
          throw Exception('Health check returned ${healthResp.statusCode}');
        }
        debugPrint('✅ Backend health check passed');
      } catch (e) {
        debugPrint('❌ Configured URL $_serverUrl unreachable, attempting auto-detect...');
        final oldUrl = _serverUrl;
        _serverUrl = '';
        await _detectServerUrl();

        if (_serverUrl == oldUrl) {
          _lastError = 'Backend not reachable at $_serverUrl — is `python main.py` running?';
          debugPrint('❌ $_lastError');
          _isConnected = false;
          notifyListeners();
          _scheduleReconnect();
          return;
        }

        healthUrl = _serverUrl
            .replaceFirst('ws://', 'http://')
            .replaceFirst('wss://', 'https://')
            .replaceFirst('/ws/chat', '/health');
        
        final healthResp = await http
            .get(Uri.parse(healthUrl))
            .timeout(const Duration(seconds: 5));
        if (healthResp.statusCode != 200) {
          throw Exception('Health check returned ${healthResp.statusCode}');
        }
        debugPrint('✅ Backend health check passed on new auto-detected URL');
      }

      // Now open WebSocket
      _channel = WebSocketChannel.connect(Uri.parse(_serverUrl));
      await _channel!.ready;
      _isConnected = true;
      _reconnectAttempts = 0;
      _lastError = '';
      notifyListeners();

      debugPrint('✅ WebSocket connected to $_serverUrl');

      _channel!.stream.listen(
        (data) {
          final text = data.toString();
          _responseController.add(text);
        },
        onError: (error) {
          debugPrint('❌ WebSocket error: $error');
          _lastError = 'Connection lost: $error';
          _handleDisconnect();
        },
        onDone: () {
          debugPrint('🔌 WebSocket closed');
          _lastError = 'Server closed the connection';
          _handleDisconnect();
        },
      );
    } catch (e) {
      debugPrint('❌ WebSocket connection failed: $e');
      _lastError = 'Connection failed: $e';
      _isConnected = false;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  /// Send a chat payload with optional audio, image, text, Mode, GPS, and scene memory.
  void sendMessage({
    required String sessionId,
    String? query,
    String? audioBase64,
    String? imageBase64,
    Map<String, dynamic>? visionContext,
    Map<String, double>? locationData,
    String mode = 'assistant',
    String? sceneMemory,
  }) {
    if (!_isConnected || _channel == null) {
      debugPrint('⚠️ Cannot send — not connected');
      _lastError = 'Not connected to server';
      notifyListeners();
      return;
    }

    final payload = {
      'session_id': sessionId,
      if (query != null) 'query': query,
      if (audioBase64 != null) 'audio': audioBase64,
      if (imageBase64 != null) 'image': imageBase64,
      if (visionContext != null) 'vision_context': visionContext,
      if (locationData != null) 'location': locationData,
      'mode': mode,
      if (sceneMemory != null) 'scene_memory': sceneMemory,
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
      _lastError = 'Max reconnect attempts reached. Tap refresh in Settings.';
      debugPrint('⚠️ $_lastError');
      notifyListeners();
      return;
    }

    _reconnectTimer?.cancel();
    final delay = Duration(seconds: (2 * (_reconnectAttempts + 1)).clamp(2, 15));
    _reconnectAttempts++;

    debugPrint('🔄 Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts/$_maxReconnectAttempts)');

    _reconnectTimer = Timer(delay, () {
      connect();
    });
  }

  /// Reset reconnection counter and try connecting again.
  void retryConnection() {
    _reconnectAttempts = 0;
    _lastError = '';
    disconnect();
    connect();
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
