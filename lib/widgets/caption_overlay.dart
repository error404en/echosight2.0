import 'package:flutter/material.dart';
import 'dart:ui';
import '../core/theme.dart';

/// Real-time caption overlay with glassmorphism effect.
/// Auto-hides user speech when AI response starts to prevent overlap.
/// Designed for accessibility: large fonts, Semantics labels, auto-scroll.
class CaptionOverlay extends StatelessWidget {
  final String caption;
  final String streamingResponse;
  final bool isVisible;

  const CaptionOverlay({
    super.key,
    required this.caption,
    this.streamingResponse = '',
    this.isVisible = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!isVisible || (caption.isEmpty && streamingResponse.isEmpty)) {
      return const SizedBox.shrink();
    }

    // When AI response is streaming, hide the user caption to prevent overlap
    final showUserCaption = caption.isNotEmpty && streamingResponse.isEmpty;
    final showAiResponse = streamingResponse.isNotEmpty;

    return Positioned(
      bottom: 220,
      left: 16,
      right: 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // User speech caption — only shown when AI hasn't started responding
          if (showUserCaption)
            Semantics(
              label: 'You said: $caption',
              liveRegion: true,
              child: AnimatedOpacity(
                opacity: showUserCaption ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: _GlassCard(
                  child: Row(
                    children: [
                      Icon(Icons.mic, color: EchoSightTheme.listening, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          caption,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // AI response — takes full focus when streaming
          if (showAiResponse)
            Semantics(
              label: 'EchoSight: $streamingResponse',
              liveRegion: true,
              child: AnimatedOpacity(
                opacity: showAiResponse ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: _GlassCard(
                  accentColor: EchoSightTheme.speaking,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: SingleChildScrollView(
                      reverse: true,  // Auto-scroll to bottom as text arrives
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Icon(Icons.smart_toy, color: EchoSightTheme.speaking, size: 20),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              streamingResponse,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w400,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  final Color accentColor;

  const _GlassCard({
    required this.child,
    this.accentColor = EchoSightTheme.listening,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: accentColor.withOpacity(0.25),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}
