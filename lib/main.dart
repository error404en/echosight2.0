import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'core/theme.dart';
import 'screens/home_screen.dart';
import 'services/camera_service.dart';
import 'services/detection_service.dart';
import 'services/fusion_engine.dart';
import 'services/ocr_service.dart';
import 'services/speech_service.dart';
import 'services/tts_service.dart';
import 'services/websocket_service.dart';
import 'services/location_service.dart';
import 'services/navigation_service.dart';
import 'services/emergency_service.dart';
import 'services/surroundings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait for consistent camera experience
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  // Status bar style
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: EchoSightTheme.surfaceDark,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  // Request permissions
  await _requestPermissions();

  runApp(const EchoSightApp());
}

Future<void> _requestPermissions() async {
  await [
    Permission.camera,
    Permission.microphone,
    Permission.speech,
    Permission.location,
  ].request();
}

class EchoSightApp extends StatelessWidget {
  const EchoSightApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Core services
        ChangeNotifierProvider(create: (_) => CameraService()),
        ChangeNotifierProvider(create: (_) => DetectionService()),
        Provider(create: (_) => OcrService()),
        ChangeNotifierProvider(create: (_) => SpeechService()),
        ChangeNotifierProvider(create: (_) => TtsService()),
        ChangeNotifierProvider(create: (_) => WebSocketService()),
        ChangeNotifierProvider(create: (_) => LocationService()),

        // Proactive surroundings / sight — delta scans + scene memory
        ChangeNotifierProxyProvider6<
            CameraService,
            DetectionService,
            OcrService,
            WebSocketService,
            TtsService,
            LocationService,
            SurroundingsService>(
          create: (context) => SurroundingsService(
            cameraService: context.read<CameraService>(),
            detectionService: context.read<DetectionService>(),
            ocrService: context.read<OcrService>(),
            webSocketService: context.read<WebSocketService>(),
            ttsService: context.read<TtsService>(),
            locationService: context.read<LocationService>(),
          ),
          update: (_, a, b, c, d, e, f, previous) => previous!,
        ),

        // Fusion engine — depends on all services
        ChangeNotifierProxyProvider6<
            CameraService,
            DetectionService,
            OcrService,
            WebSocketService,
            SpeechService,
            TtsService,
            FusionEngine>(
          create: (context) => FusionEngine(
            cameraService: context.read<CameraService>(),
            detectionService: context.read<DetectionService>(),
            ocrService: context.read<OcrService>(),
            webSocketService: context.read<WebSocketService>(),
            speechService: context.read<SpeechService>(),
            ttsService: context.read<TtsService>(),
            surroundingsService: context.read<SurroundingsService>(),
          ),
          update: (_, camera, detection, ocr, ws, speech, tts, previous) =>
              previous!,
        ),

        // Navigation service
        ChangeNotifierProxyProvider3<
            LocationService,
            WebSocketService,
            TtsService,
            NavigationService>(
          create: (context) => NavigationService(
            locationService: context.read<LocationService>(),
            webSocketService: context.read<WebSocketService>(),
            ttsService: context.read<TtsService>(),
          ),
          update: (_, loc, ws, tts, previous) => previous!,
        ),

        // Emergency service
        ChangeNotifierProxyProvider6<
            CameraService,
            TtsService,
            LocationService,
            WebSocketService,
            DetectionService,
            OcrService,
            EmergencyService>(
          create: (context) => EmergencyService(
            cameraService: context.read<CameraService>(),
            ttsService: context.read<TtsService>(),
            locationService: context.read<LocationService>(),
            webSocketService: context.read<WebSocketService>(),
            detectionService: context.read<DetectionService>(),
            ocrService: context.read<OcrService>(),
          ),
          update: (_, camera, tts, loc, ws, det, ocr, previous) => previous!,
        ),
      ],
      child: MaterialApp(
        title: 'EchoSight',
        debugShowCheckedModeBanner: false,
        theme: EchoSightTheme.darkTheme,
        home: const HomeScreen(),
      ),
    );
  }
}
