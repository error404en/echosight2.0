import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/emergency_service.dart';
import '../services/fusion_engine.dart';

/// Full-screen emergency mode with large panic button,
/// continuous scanning status, and SOS trigger.
/// Designed for absolute simplicity — a blind user can activate
/// and use this under extreme stress.
class EmergencyScreen extends StatelessWidget {
  const EmergencyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<EmergencyService>(
      builder: (context, emergency, _) {
        return Scaffold(
          backgroundColor: const Color(0xFF0D0000),
          appBar: AppBar(
            title: const Text('EMERGENCY MODE'),
            backgroundColor: Colors.red.withOpacity(0.15),
            foregroundColor: Colors.redAccent,
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                emergency.deactivate();
                Navigator.pop(context);
              },
            ),
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 16),

                  // Status display
                  _buildStatusBanner(emergency),
                  const SizedBox(height: 16),

                  // Scan counter
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              emergency.state == EmergencyState.scanning
                                  ? Icons.radar
                                  : Icons.shield,
                              color: Colors.redAccent,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              emergency.state == EmergencyState.scanning
                                  ? 'Scanning...'
                                  : 'Monitoring',
                              style: const TextStyle(color: Colors.white70, fontSize: 14),
                            ),
                          ],
                        ),
                        Text(
                          '${emergency.scanCount} scans',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.4),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Location
                  if (emergency.emergencyLocation.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orange.withOpacity(0.2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.my_location, color: Colors.orangeAccent, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              emergency.emergencyLocation,
                              style: const TextStyle(
                                color: Colors.orangeAccent,
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),

                  // Last alert
                  if (emergency.lastAlert.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.redAccent.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.warning_amber, color: Colors.redAccent, size: 18),
                              SizedBox(width: 8),
                              Text(
                                'Last Alert',
                                style: TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            emergency.lastAlert,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),

                  const Spacer(),

                  // SOS Button — HUGE target for blind users
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.heavyImpact();
                      emergency.triggerSOS();
                    },
                    child: Container(
                      width: 180,
                      height: 180,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            Colors.red.withOpacity(emergency.sosTriggered ? 0.6 : 0.3),
                            Colors.red.withOpacity(0.05),
                          ],
                        ),
                        border: Border.all(
                          color: Colors.redAccent,
                          width: 3,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.red.withOpacity(0.3),
                            blurRadius: 40,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            emergency.sosTriggered
                                ? Icons.sos
                                : Icons.emergency,
                            color: Colors.white,
                            size: 48,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            emergency.sosTriggered ? 'SOS SENT' : 'SOS',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Tap for SOS alert with your location',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.4),
                      fontSize: 13,
                    ),
                  ),

                  const Spacer(),

                  // Manual scan button
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        final fusion = context.read<FusionEngine>();
                        emergency.performScan(fusion.sessionId);
                      },
                      icon: const Icon(Icons.radar),
                      label: const Text(
                        'Scan Now',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent.withOpacity(0.15),
                        foregroundColor: Colors.redAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: Colors.redAccent),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Deactivate
                  TextButton(
                    onPressed: () {
                      emergency.deactivate();
                      Navigator.pop(context);
                    },
                    child: const Text(
                      'Exit Emergency Mode',
                      style: TextStyle(color: Colors.white38, fontSize: 14),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusBanner(EmergencyService emergency) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 500),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: emergency.isActive
              ? [Colors.red.withOpacity(0.2), Colors.red.withOpacity(0.05)]
              : [Colors.grey.withOpacity(0.1), Colors.grey.withOpacity(0.05)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: emergency.isActive
              ? Colors.redAccent.withOpacity(0.4)
              : Colors.grey.withOpacity(0.2),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: emergency.isActive ? Colors.redAccent : Colors.grey,
              boxShadow: emergency.isActive
                  ? [BoxShadow(color: Colors.red.withOpacity(0.5), blurRadius: 8)]
                  : [],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              emergency.isActive
                  ? 'CONTINUOUS HAZARD SCANNING ACTIVE'
                  : 'Emergency Mode Inactive',
              style: TextStyle(
                color: emergency.isActive ? Colors.redAccent : Colors.grey,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
