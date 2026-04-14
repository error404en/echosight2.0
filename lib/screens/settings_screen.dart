import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/theme.dart';
import '../services/fusion_engine.dart';
import '../services/camera_service.dart';
import '../services/tts_service.dart';
import '../services/websocket_service.dart';

/// Settings screen for configuring the app.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _serverUrlController = TextEditingController();
  bool _showDetectionOverlay = true;
  bool _highContrastMode = false;

  @override
  void initState() {
    super.initState();
    final ws = context.read<WebSocketService>();
    _serverUrlController.text = ws.serverUrl;
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Connection Section ──
          _SectionHeader(title: 'Connection', icon: Icons.wifi),
          _buildCard([
            _buildServerUrlField(),
            const Divider(height: 1, color: Colors.white10),
            Consumer<WebSocketService>(
              builder: (context, ws, _) => _SettingsTile(
                title: 'Server Status',
                subtitle: ws.isConnected ? 'Connected' : 'Disconnected',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: ws.isConnected
                            ? EchoSightTheme.success
                            : EchoSightTheme.danger,
                        boxShadow: [
                          BoxShadow(
                            color: (ws.isConnected
                                    ? EchoSightTheme.success
                                    : EchoSightTheme.danger)
                                .withOpacity(0.5),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      icon: const Icon(Icons.refresh, size: 20),
                      onPressed: () {
                        ws.disconnect();
                        ws.setServerUrl(_serverUrlController.text.trim());
                        ws.connect();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ]),

          const SizedBox(height: 24),

          // ── Voice Section ──
          _SectionHeader(title: 'Voice', icon: Icons.record_voice_over),
          _buildCard([
            Consumer<FusionEngine>(
              builder: (context, fusion, _) => _SwitchTile(
                title: 'Continuous Listening',
                subtitle: 'Auto-restart listening after response',
                value: fusion.continuousMode,
                onChanged: (_) => fusion.toggleContinuousMode(),
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            Consumer<TtsService>(
              builder: (context, tts, _) => _SliderTile(
                title: 'Speech Rate',
                value: tts.speechRate,
                min: 0.1,
                max: 1.0,
                onChanged: (v) => tts.setSpeechRate(v),
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            Consumer<TtsService>(
              builder: (context, tts, _) => _SliderTile(
                title: 'Pitch',
                value: tts.pitch,
                min: 0.5,
                max: 2.0,
                onChanged: (v) => tts.setPitch(v),
              ),
            ),
          ]),

          const SizedBox(height: 24),

          // ── Display Section ──
          _SectionHeader(title: 'Display', icon: Icons.visibility),
          _buildCard([
            _SwitchTile(
              title: 'Detection Overlay',
              subtitle: 'Show bounding boxes on camera',
              value: _showDetectionOverlay,
              onChanged: (v) => setState(() => _showDetectionOverlay = v),
            ),
            const Divider(height: 1, color: Colors.white10),
            _SwitchTile(
              title: 'High Contrast Mode',
              subtitle: 'Enhanced visibility for severe impairment',
              value: _highContrastMode,
              onChanged: (v) => setState(() => _highContrastMode = v),
            ),
          ]),

          const SizedBox(height: 24),

          // ── Face Recognition Section ──
          _SectionHeader(title: 'Face Recognition', icon: Icons.face),
          _buildCard([
            _SettingsTile(
              title: 'Known Identities',
              subtitle: 'Add people to social memory',
              trailing: ElevatedButton.icon(
                icon: const Icon(Icons.add_a_photo, size: 16),
                label: const Text('Add Face'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: EchoSightTheme.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () => _showAddFaceDialog(context),
              ),
            ),
          ]),

          const SizedBox(height: 24),

          // ── About Section ──
          _SectionHeader(title: 'About', icon: Icons.info_outline),
          _buildCard([
            _SettingsTile(
              title: 'EchoSight',
              subtitle: 'AI-Powered Assistive Vision v1.0.0',
              trailing: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: EchoSightTheme.primaryGradient,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.visibility, color: Colors.white, size: 20),
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            _SettingsTile(
              title: 'AI Model',
              subtitle: 'Gemini 3.1 Pro (Google)',
            ),
            const Divider(height: 1, color: Colors.white10),
            _SettingsTile(
              title: 'On-Device AI',
              subtitle: 'YOLOv8n + Google ML Kit OCR',
            ),
          ]),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildServerUrlField() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _serverUrlController,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: InputDecoration(
          labelText: 'Server URL',
          labelStyle: TextStyle(color: EchoSightTheme.textSecondary),
          hintText: 'ws://10.0.2.2:8000/ws/chat',
          hintStyle: TextStyle(color: Colors.white24),
          filled: true,
          fillColor: Colors.white.withOpacity(0.05),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white12),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white12),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: EchoSightTheme.primary),
          ),
          prefixIcon: Icon(Icons.link, color: EchoSightTheme.textSecondary, size: 20),
        ),
        onSubmitted: (url) {
          final ws = context.read<WebSocketService>();
          ws.disconnect();
          ws.setServerUrl(url.trim());
          ws.connect();
        },
      ),
    );
  }

  Widget _buildCard(List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: EchoSightTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(children: children),
    );
  }

  Future<void> _showAddFaceDialog(BuildContext context) async {
    final nameController = TextEditingController();
    final ws = context.read<WebSocketService>();
    final camera = context.read<CameraService>();
    
    // Parse WS URL to HTTP. e.g. ws://10.0.2.2:8000/ws/chat -> http://10.0.2.2:8000/api/add-face
    String baseUrl = ws.serverUrl.replaceFirst('ws://', 'http://').replaceFirst('wss://', 'https://');
    baseUrl = baseUrl.split('/ws/')[0];
    print(baseUrl);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool isSaving = false;
        
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: EchoSightTheme.surfaceDark,
              title: const Text('Add Known Face', style: TextStyle(color: Colors.white)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Point the camera at the person. Tap "Capture & Save" to memorize their face.',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Person Name',
                      hintText: 'e.g. My Brother',
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                    ),
                  ),
                  if (isSaving)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: CircularProgressIndicator(),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: isSaving ? null : () async {
                    if (nameController.text.trim().isEmpty) return;
                    
                    setDialogState(() => isSaving = true);
                    
                    try {
                      final imageBase64 = await camera.captureFrame();
                      if (imageBase64 == null) throw Exception("Failed to capture image");
                      
                      final response = await http.post(
                        Uri.parse('$baseUrl/api/add-face'),
                        headers: {'Content-Type': 'application/json'},
                        body: jsonEncode({
                          'name': nameController.text.trim(),
                          'image': imageBase64,
                        }),
                      );
                      
                      if (response.statusCode == 200) {
                        Navigator.pop(dialogContext); // Close dialog
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          SnackBar(content: Text('Saved face: ${nameController.text}')),
                        );
                      } else {
                        throw Exception(response.body);
                      }
                    } catch (e) {
                      setDialogState(() => isSaving = false);
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(content: Text('Failed: $e'), backgroundColor: EchoSightTheme.danger),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: EchoSightTheme.primary),
                  child: const Text('Capture & Save', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          }
        );
      }
    );
  }
}

// ── Reusable setting widgets ──

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;

  const _SectionHeader({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: EchoSightTheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              color: EchoSightTheme.primary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;

  const _SettingsTile({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 13, color: EchoSightTheme.textSecondary)),
      trailing: trailing,
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle,
          style: TextStyle(fontSize: 13, color: EchoSightTheme.textSecondary)),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _SliderTile extends StatelessWidget {
  final String title;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _SliderTile({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              Text(value.toStringAsFixed(1),
                  style: TextStyle(
                      fontSize: 14, color: EchoSightTheme.primary, fontWeight: FontWeight.w600)),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
