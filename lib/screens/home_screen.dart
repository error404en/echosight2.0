import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import '../core/theme.dart';
import '../services/fusion_engine.dart';
import '../services/websocket_service.dart';
import '../widgets/mic_button.dart';
import '../widgets/status_indicator.dart';
import '../widgets/caption_overlay.dart';
import '../services/camera_service.dart';
import '../services/speech_service.dart';
import '../services/emergency_service.dart';
import '../services/navigation_service.dart';
import '../models/assistant_mode.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';
import 'navigation_screen.dart';
import 'emergency_screen.dart';

/// Main home screen — voice-first UI with camera preview.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize the fusion engine
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<FusionEngine>().initialize();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cameraService = context.read<CameraService>();
    if (state == AppLifecycleState.inactive) {
      cameraService.controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      cameraService.initialize();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(context),
      body: Consumer2<FusionEngine, CameraService>(
        builder: (context, fusion, camera, child) {
          return Stack(
            fit: StackFit.expand,
            children: [
              // Camera preview background
              _buildCameraPreview(camera),

              // Dark gradient overlay
              _buildGradientOverlay(),

              // Top status area
              Positioned(
                top: MediaQuery.of(context).padding.top + 60,
                left: 0,
                right: 0,
                child: Center(
                  child: Consumer<WebSocketService>(
                    builder: (context, ws, _) => StatusIndicator(
                      state: fusion.state,
                      isConnected: ws.isConnected,
                    ),
                  ),
                ),
              ),

              // Caption overlay
              CaptionOverlay(
                caption: fusion.currentCaption,
                streamingResponse: fusion.streamingResponse,
              ),

              // Bottom control area
              _buildBottomControls(context, fusion),
            ],
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: EchoSightTheme.primaryGradient,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.visibility, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          const Text('EchoSight'),
        ],
      ),
      actions: [
        // Chat transcript
        IconButton(
          icon: const Icon(Icons.chat_bubble_outline, color: Colors.white70),
          tooltip: 'Conversation',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ChatScreen()),
          ),
        ),
        // Settings
        IconButton(
          icon: const Icon(Icons.settings_outlined, color: Colors.white70),
          tooltip: 'Settings',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
      ],
    );
  }

  Widget _buildCameraPreview(CameraService camera) {
    if (!camera.isInitialized || camera.controller == null || !camera.controller!.value.isInitialized) {
      return Container(
        decoration: const BoxDecoration(
          gradient: EchoSightTheme.darkGradient,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.camera_alt_outlined,
                  size: 64, color: EchoSightTheme.textSecondary.withOpacity(0.4)),
              const SizedBox(height: 16),
              Text(
                'Initializing camera...',
                style: TextStyle(
                  color: EchoSightTheme.textSecondary.withOpacity(0.6),
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: camera.controller!.value.previewSize!.height,
            height: camera.controller!.value.previewSize!.width,
            child: CameraPreview(camera.controller!),
          ),
        ),
      ),
    );
  }

  Widget _buildGradientOverlay() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withOpacity(0.5),
            Colors.transparent,
            Colors.transparent,
            Colors.black.withOpacity(0.7),
            Colors.black.withOpacity(0.9),
          ],
          stops: const [0.0, 0.2, 0.5, 0.75, 1.0],
        ),
      ),
    );
  }

  Widget _buildBottomControls(BuildContext context, FusionEngine fusion) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + 20,
          top: 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Mode Selector Strip
            SizedBox(
              height: 40,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: AssistantMode.values.length,
                itemBuilder: (context, index) {
                  final mode = AssistantMode.values[index];
                  final isSelected = fusion.currentMode == mode;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Row(
                        children: [
                          Icon(mode.icon, size: 16, color: isSelected ? Colors.white : Colors.white70),
                          const SizedBox(width: 4),
                          Text(mode.name),
                        ],
                      ),
                      selected: isSelected,
                      onSelected: (selected) {
                        if (selected) {
                          HapticFeedback.selectionClick();
                          fusion.setMode(mode);
                        }
                      },
                      backgroundColor: Colors.black45,
                      selectedColor: mode.color.withOpacity(0.3),
                      labelStyle: TextStyle(
                        color: isSelected ? Colors.white : Colors.white70,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        fontSize: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: BorderSide(
                          color: isSelected ? mode.color.withOpacity(0.5) : Colors.transparent,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),

            // Mic button logic
            MicButton(
              state: fusion.state,
              size: 80,
              onTap: () => _handleMicTap(fusion),
              onLongPress: () {
                HapticFeedback.heavyImpact();
                fusion.toggleContinuousMode();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      fusion.continuousMode
                          ? '🎤 Continuous mode ON'
                          : '🎤 Tap-to-talk mode',
                      style: const TextStyle(fontSize: 16),
                    ),
                    backgroundColor: EchoSightTheme.primary,
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 12),

            // Mode indicator text
            Text(
              '${fusion.currentMode.name} Mode • ${fusion.continuousMode ? 'Continuous' : 'Tap to Speak'}',
              style: TextStyle(
                color: fusion.currentMode.color,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),

            const SizedBox(height: 8),

            // Quick action buttons — Row 1
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _QuickActionButton(
                  icon: Icons.cameraswitch_outlined,
                  label: 'Flip',
                  onTap: () {
                    HapticFeedback.lightImpact();
                    context.read<CameraService>().switchCamera();
                  },
                ),
                const SizedBox(width: 16),
                _QuickActionButton(
                  icon: fusion.speechService.inputMode == SpeechInputMode.onDevice
                      ? Icons.smartphone
                      : Icons.cloud,
                  label: fusion.speechService.inputMode == SpeechInputMode.onDevice
                      ? 'Local STT'
                      : 'Cloud STT',
                  onTap: () {
                    HapticFeedback.lightImpact();
                    fusion.speechService.toggleInputMode();
                  },
                ),
                const SizedBox(width: 16),
                _QuickActionButton(
                  icon: Icons.navigation,
                  label: 'Navigate',
                  color: Colors.greenAccent,
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const NavigationScreen()),
                    );
                  },
                ),
                const SizedBox(width: 16),
                _QuickActionButton(
                  icon: Icons.emergency,
                  label: 'SOS',
                  color: Colors.redAccent,
                  onTap: () {
                    HapticFeedback.heavyImpact();
                    final emergency = context.read<EmergencyService>();
                    emergency.activate();
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const EmergencyScreen()),
                    );
                  },
                ),
                const SizedBox(width: 16),
                _QuickActionButton(
                  icon: Icons.refresh,
                  label: 'Clear',
                  onTap: () {
                    HapticFeedback.lightImpact();
                    fusion.clearConversation();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _handleMicTap(FusionEngine fusion) {
    HapticFeedback.mediumImpact();

    switch (fusion.state) {
      case AssistantState.idle:
        fusion.startListening();
        break;
      case AssistantState.listening:
        fusion.stopListening();
        break;
      case AssistantState.speaking:
        // Stop speaking and listen again
        fusion.startListening();
        break;
      case AssistantState.processing:
      case AssistantState.thinking:
        // Do nothing while processing
        break;
    }
  }
}

class _QuickActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.white70;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: c.withOpacity(0.1),
              shape: BoxShape.circle,
              border: Border.all(
                color: c.withOpacity(0.3),
              ),
            ),
            child: Icon(icon, color: c, size: 20),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: c.withOpacity(0.8),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

