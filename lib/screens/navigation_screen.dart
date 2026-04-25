import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/theme.dart';
import '../services/navigation_service.dart';
import '../services/fusion_engine.dart';
import '../services/tts_service.dart';
import '../services/speech_service.dart';

/// Full-screen navigation assistant for walking guidance.
/// Designed for blind users: large touch targets, voice input, continuous TTS.
class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final TextEditingController _destController = TextEditingController();
  bool _isVoiceInputActive = false;

  @override
  void dispose() {
    _destController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<NavigationService>(
      builder: (context, nav, _) {
        return Scaffold(
          backgroundColor: const Color(0xFF0A0E21),
          appBar: AppBar(
            title: const Text('Navigation Assistant'),
            backgroundColor: Colors.transparent,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                if (nav.isNavigating) {
                  _showStopDialog(context, nav);
                } else {
                  Navigator.pop(context);
                }
              },
            ),
          ),
          body: SafeArea(
            child: nav.isNavigating || nav.state == NavigationState.arrived
                ? _buildActiveNavigation(context, nav)
                : _buildDestinationInput(context, nav),
          ),
        );
      },
    );
  }

  /// Destination entry screen — large text field + voice input.
  Widget _buildDestinationInput(BuildContext context, NavigationService nav) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 20),
          // Header
          const Icon(Icons.explore, size: 64, color: Colors.greenAccent),
          const SizedBox(height: 16),
          const Text(
            'Where would you like to go?',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Type a place or tap the mic to speak your destination',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 32),

          // Destination input
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _destController,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                    decoration: InputDecoration(
                      hintText: 'e.g. Central Park, nearest pharmacy...',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 18,
                      ),
                    ),
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _startNavigation(context, nav),
                  ),
                ),
                // Voice input button
                GestureDetector(
                  onTap: () => _handleVoiceDestination(context),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: _isVoiceInputActive
                          ? Colors.redAccent.withOpacity(0.3)
                          : Colors.greenAccent.withOpacity(0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _isVoiceInputActive ? Icons.stop : Icons.mic,
                      color: _isVoiceInputActive
                          ? Colors.redAccent
                          : Colors.greenAccent,
                      size: 24,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Start button
          SizedBox(
            height: 60,
            child: ElevatedButton(
              onPressed: nav.state == NavigationState.fetchingRoute
                  ? null
                  : () => _startNavigation(context, nav),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent.withOpacity(0.15),
                foregroundColor: Colors.greenAccent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: Colors.greenAccent, width: 1),
                ),
              ),
              child: nav.state == NavigationState.fetchingRoute
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.greenAccent,
                          ),
                        ),
                        SizedBox(width: 12),
                        Text('Finding route...', style: TextStyle(fontSize: 18)),
                      ],
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.navigation, size: 24),
                        SizedBox(width: 12),
                        Text('Start Walking', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),
            ),
          ),

          if (nav.state == NavigationState.error) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.redAccent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      nav.errorMessage,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Active navigation view — large step display + progress.
  Widget _buildActiveNavigation(BuildContext context, NavigationService nav) {
    final isArrived = nav.state == NavigationState.arrived;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Destination header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.greenAccent.withOpacity(0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.greenAccent.withOpacity(0.2)),
            ),
            child: Row(
              children: [
                Icon(
                  isArrived ? Icons.flag : Icons.place,
                  color: Colors.greenAccent,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isArrived ? 'You have arrived!' : 'Navigating to',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        nav.destination,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Static Map Preview
          if (!isArrived && nav.staticMapUrl.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.network(
                nav.staticMapUrl,
                height: 120,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const SizedBox(),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Progress bar
          if (!isArrived && nav.totalSteps > 0) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: nav.totalSteps > 0
                    ? nav.currentStep / nav.totalSteps
                    : 0,
                backgroundColor: Colors.white.withOpacity(0.1),
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.greenAccent),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Step ${nav.currentStep + 1} of ${nav.totalSteps} • ${nav.distanceRemaining}',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 24),
          ],

          // Current instruction — BIG for accessibility
          Expanded(
            child: Center(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isArrived
                        ? [
                            Colors.greenAccent.withOpacity(0.15),
                            Colors.green.withOpacity(0.08),
                          ]
                        : [
                            Colors.blueAccent.withOpacity(0.1),
                            Colors.blue.withOpacity(0.05),
                          ],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: (isArrived ? Colors.greenAccent : Colors.blueAccent)
                        .withOpacity(0.2),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isArrived ? Icons.check_circle : Icons.directions_walk,
                      size: 48,
                      color: isArrived ? Colors.greenAccent : Colors.blueAccent,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      isArrived
                          ? 'You have reached your destination!'
                          : nav.currentInstruction.isNotEmpty
                              ? nav.currentInstruction
                              : 'Calculating route...',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Action buttons: Repeat and Scan
          if (!isArrived)
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        nav.repeatCurrentInstruction();
                      },
                      icon: const Icon(Icons.replay),
                      label: const Text('Repeat', style: TextStyle(fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent.withOpacity(0.15),
                        foregroundColor: Colors.blueAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: Colors.blueAccent.withOpacity(0.5)),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: SizedBox(
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        final fusion = context.read<FusionEngine>();
                        fusion.runProactiveSurroundingsScan();
                        context.read<TtsService>().speak('Scanning surroundings.');
                      },
                      icon: const Icon(Icons.radar),
                      label: const Text('Scan', style: TextStyle(fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.cyanAccent.withOpacity(0.15),
                        foregroundColor: Colors.cyanAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(color: Colors.cyanAccent.withOpacity(0.5)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),

          const SizedBox(height: 16),

          // Stop / Done button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: () {
                if (isArrived) {
                  Navigator.pop(context);
                } else {
                  _showStopDialog(context, nav);
                }
              },
              icon: Icon(isArrived ? Icons.check : Icons.stop),
              label: Text(
                isArrived ? 'Done' : 'Stop Navigation',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isArrived
                    ? Colors.greenAccent.withOpacity(0.15)
                    : Colors.redAccent.withOpacity(0.15),
                foregroundColor: isArrived ? Colors.greenAccent : Colors.redAccent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: isArrived ? Colors.greenAccent : Colors.redAccent,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _startNavigation(BuildContext context, NavigationService nav) {
    final dest = _destController.text.trim();
    if (dest.isEmpty) {
      context.read<TtsService>().speak('Please enter a destination first.');
      return;
    }
    final fusion = context.read<FusionEngine>();
    nav.startNavigation(dest, fusion.sessionId);
  }

  void _handleVoiceDestination(BuildContext context) async {
    final speech = context.read<SpeechService>();
    final nav = context.read<NavigationService>();
    final fusion = context.read<FusionEngine>();
    
    if (_isVoiceInputActive) {
      await speech.stopListening();
      setState(() => _isVoiceInputActive = false);
    } else {
      HapticFeedback.mediumImpact();
      await context.read<TtsService>().stop();
      context.read<TtsService>().speak('Say your destination.');
      await Future.delayed(const Duration(milliseconds: 1500));

      // Temporarily override the text result callback
      final originalCallback = speech.onTextResult;
      speech.onTextResult = (text) {
        // Always restore original callback
        speech.onTextResult = originalCallback;
        setState(() => _isVoiceInputActive = false);
        
        if (text.isNotEmpty && text != 'Listening...') {
          setState(() {
            _destController.text = text;
          });
          // Auto-start navigation
          nav.startNavigation(text, fusion.sessionId);
        } else {
          context.read<TtsService>().speak('Did not hear a destination. Cancelled.');
        }
      };

      setState(() => _isVoiceInputActive = true);
      await speech.startListening();
    }
  }

  void _showStopDialog(BuildContext context, NavigationService nav) {
    HapticFeedback.heavyImpact();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1F38),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Stop Navigation?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to stop navigation?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Continue', style: TextStyle(color: Colors.greenAccent)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              final fusion = context.read<FusionEngine>();
              nav.stopNavigation(fusion.sessionId);
              Navigator.pop(context);
            },
            child: const Text('Stop', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }
}
