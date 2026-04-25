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
import '../services/surroundings_service.dart';
import '../models/assistant_mode.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';
import 'navigation_screen.dart';
import 'emergency_screen.dart';

/// Main home screen — voice-first UI with camera preview.
/// Designed with blind-first accessibility:
///   • Full-screen tap to speak
///   • Swipe left/right to cycle modes
///   • All elements have Semantics labels
///   • Haptic feedback on every interaction
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
    // Initialize the fusion engine and wire up navigation callback
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final fusion = context.read<FusionEngine>();
      fusion.initialize();

      // Wire up the voice-triggered screen navigation
      fusion.onNavigateToScreen = (screenName) {
        _navigateToScreen(screenName);
      };
    });
  }

  /// Navigate to a screen by name — called by FusionEngine when
  /// the user triggers navigation via voice commands.
  void _navigateToScreen(String screenName) {
    if (!mounted) return;
    switch (screenName) {
      case 'navigate':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const NavigationScreen()),
        );
        break;
      case 'emergency':
        final emergency = context.read<EmergencyService>();
        emergency.activate();
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const EmergencyScreen()),
        );
        break;
    }
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
          return GestureDetector(
            // SWIPE LEFT/RIGHT to cycle modes — fully accessible
            onHorizontalDragEnd: (details) {
              if (details.primaryVelocity == null) return;
              if (details.primaryVelocity! < -200) {
                // Swipe left → next mode
                fusion.cycleMode(forward: true);
              } else if (details.primaryVelocity! > 200) {
                // Swipe right → previous mode
                fusion.cycleMode(forward: false);
              }
            },
            child: Semantics(
              label: 'EchoSight main screen. ${fusion.state.accessibilityLabel} '
                  'Current mode: ${fusion.currentMode.name}. '
                  'Swipe left or right to change modes.',
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Camera preview background
                  _buildCameraPreview(camera),

                  // Dark gradient overlay
                  _buildGradientOverlay(),

                  // Global Mic area for visually impaired — full screen tap
                  GestureDetector(
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
                            style: const TextStyle(fontSize: 18),
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
                    behavior: HitTestBehavior.translucent,
                    child: const SizedBox.expand(),
                  ),

                  // Top status area
                  Positioned(
                    top: MediaQuery.of(context).padding.top + 60,
                    left: 0,
                    right: 0,
                    child: Column(
                      children: [
                        Consumer<WebSocketService>(
                          builder: (context, ws, _) => Semantics(
                            label: fusion.state.accessibilityLabel +
                                (ws.isConnected ? '' : ' Server offline.'),
                            child: StatusIndicator(
                              state: fusion.state,
                              isConnected: ws.isConnected,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Explicit Mode Distinction Banner
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 24),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: fusion.currentMode.color.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: fusion.currentMode.color.withOpacity(0.3)),
                          ),
                          child: Column(
                            children: [
                              Text(
                                fusion.currentMode.name.toUpperCase(),
                                style: TextStyle(
                                  color: fusion.currentMode.color,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.5,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                fusion.currentMode.description, // Explicitly shows the feature
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  height: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Caption overlay — shows what user said and AI response
                  CaptionOverlay(
                    caption: fusion.currentCaption,
                    streamingResponse: fusion.streamingResponse,
                  ),

                  // Bottom control area
                  _buildBottomControls(context, fusion),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      title: Semantics(
        label: 'EchoSight',
        header: true,
        child: Row(
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
      ),
      actions: [
        // Chat transcript
        Semantics(
          label: 'Open conversation history',
          button: true,
          child: IconButton(
            icon: const Icon(Icons.chat_bubble_outline, color: Colors.white70),
            tooltip: 'Conversation',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ChatScreen()),
            ),
          ),
        ),
        // Settings
        Semantics(
          label: 'Open settings',
          button: true,
          child: IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
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
    final bottomSheetWidth = MediaQuery.sizeOf(context).width;
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
            // Mode Selector Strip — with Semantics for accessibility
            Semantics(
              label: 'Mode selector. Current: ${fusion.currentMode.name}. '
                  'Swipe left or right to change modes, or tap to select.',
              child: SizedBox(
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
                      child: Semantics(
                        label: '${mode.name} mode. ${mode.description}. ${isSelected ? "Currently selected." : ""}',
                        button: true,
                        selected: isSelected,
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
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Mic button logic
            MicButton(
              state: fusion.state,
              size: 96,  // Increased from 80 for better accessibility
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
                      style: const TextStyle(fontSize: 18),
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

            // Mode indicator text — larger for low vision
            Semantics(
              label: '${fusion.currentMode.name} mode. ${fusion.continuousMode ? 'Continuous listening.' : 'Tap to speak.'}',
              child: Text(
                '${fusion.currentMode.name} Mode • ${fusion.continuousMode ? 'Continuous' : 'Tap to Speak'}',
                style: TextStyle(
                  color: fusion.currentMode.color,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

            Consumer<SurroundingsService>(
              builder: (context, surroundings, _) {
                if (!surroundings.isActive) return const SizedBox.shrink();
                final paused = surroundings.isPaused;
                final label = paused
                    ? 'Scan paused — say resume'
                    : '${surroundings.verbosity.label} • scanning every ${surroundings.verbosity.scanIntervalSeconds}s';
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Semantics(
                    label: paused
                        ? 'Surroundings scan paused. Say resume to continue.'
                        : 'Surroundings scan active. ${surroundings.verbosity.label} mode.',
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: (paused ? Colors.amberAccent : Colors.cyanAccent).withOpacity(0.9),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 8),

            // Quick action buttons — scroll horizontally on narrow widths (avoids Row overflow).
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: bottomSheetWidth),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _QuickActionButton(
                      icon: Icons.cameraswitch_outlined,
                      label: 'Flip',
                      semanticsLabel: 'Flip camera between front and back',
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
                      semanticsLabel: 'Toggle between local and cloud speech recognition',
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
                      semanticsLabel: 'Open navigation assistant',
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
                      semanticsLabel: 'Activate emergency mode',
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
                      semanticsLabel: 'Clear conversation history',
                      onTap: () {
                        HapticFeedback.lightImpact();
                        fusion.clearConversation();
                      },
                    ),
                  ],
                ),
              ),
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
  final String? semanticsLabel;

  const _QuickActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.semanticsLabel,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.white70;
    return Semantics(
      label: semanticsLabel ?? label,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          children: [
            Container(
              width: 48,  // Increased from 44 for better touch target
              height: 48,
              decoration: BoxDecoration(
                color: c.withOpacity(0.1),
                shape: BoxShape.circle,
                border: Border.all(
                  color: c.withOpacity(0.3),
                ),
              ),
              child: Icon(icon, color: c, size: 22),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: c.withOpacity(0.8),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
