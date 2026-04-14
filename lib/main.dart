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
          ),
          update: (_, camera, detection, ocr, ws, speech, tts, previous) =>
              previous!,
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
