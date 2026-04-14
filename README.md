# EchoSight — AI-Powered Assistive Vision System

An AI-powered cross-platform mobile application that provides real-time vision understanding, assistive navigation, OCR reading, and a fully conversational voice assistant.

## ✨ Features

- **🗣️ Voice-First Interface** — Natural conversational assistant (tap-to-talk or continuous mode)
- **👁️ Real-Time Vision** — YOLOv8 object detection + scene understanding  
- **📖 OCR Reading Mode** — Point camera at text, say "read this"
- **🧭 Navigation Guidance** — Obstacle warnings with spatial directions
- **🧠 Context-Aware AI** — Combines vision + conversation history for intelligent responses
- **🔄 Hybrid Mode** — Works offline (basic) and online (full power)
- **♿ Accessibility-First** — High contrast mode, haptic feedback, large targets

## 🏗️ Architecture

```
Flutter App (Frontend)
├── Voice Pipeline (speech_to_text + flutter_tts)
├── Camera Service (real-time frame capture)
├── On-Device AI (YOLOv8 TFLite + Google ML Kit OCR)
├── Fusion Engine (vision + voice + context orchestrator)
└── WebSocket Client → FastAPI Backend
                        ├── Conversation Memory Manager
                        ├── Gemini 3.1 Pro (vision + chat streaming)
                        └── Session Management
```

## 🚀 Quick Start

### Prerequisites
- Flutter SDK ≥ 3.2.0
- Python ≥ 3.10
- Android device/emulator with camera
- Free Google AI Studio API key ([get one here](https://aistudio.google.com))

### 1. Backend Setup

```bash
cd backend

# Create virtual environment
python -m venv venv
source venv/bin/activate  # Linux/Mac
# or: venv\Scripts\activate  # Windows

# Install dependencies
pip install -r requirements.txt

# Configure API key
cp .env.example .env
# Edit .env and add your GEMINI_API_KEY

# Start server
python main.py
```

The server will start at `http://localhost:8000`.

### 2. Flutter App Setup

```bash
# Get dependencies
flutter pub get

# Run on connected device
flutter run
```

### 3. Configure Connection

In the app **Settings** screen, set the server URL:
- Android emulator: `ws://10.0.2.2:8000/ws/chat`
- Physical device (same WiFi): `ws://<your-pc-ip>:8000/ws/chat`

## 📱 Usage

1. **Tap the mic button** to start speaking
2. **Ask questions** like:
   - "What is in front of me?"
   - "Can I walk forward?"
   - "Read this" (point camera at text)
   - "Is this safe?"
3. **Long-press the mic** to toggle continuous listening mode
4. View conversation history in the **Chat** screen

## 🧠 AI Models

| Component | Model | Location |
|-----------|-------|----------|
| Vision + Chat | Gemini 3.1 Pro | Cloud (free API) |
| Object Detection | YOLOv8n | On-device (TFLite) |
| Text Recognition | Google ML Kit | On-device |
| Speech-to-Text | Platform STT | On-device |
| Text-to-Speech | Platform TTS | On-device |

## 📂 Project Structure

```
EchoSight/
├── backend/                    # FastAPI server
│   ├── main.py                # WebSocket + REST endpoints
│   ├── conversation.py        # Multi-turn memory manager
│   ├── vision_engine.py       # Gemini 3.1 Pro integration
│   └── requirements.txt
├── lib/                       # Flutter app
│   ├── main.dart              # App entry + dependency injection
│   ├── core/theme.dart        # Premium dark theme
│   ├── models/                # Data models
│   ├── services/              # Business logic
│   │   ├── fusion_engine.dart # Vision+Voice orchestrator
│   │   ├── camera_service.dart
│   │   ├── speech_service.dart
│   │   ├── tts_service.dart
│   │   ├── websocket_service.dart
│   │   ├── detection_service.dart
│   │   ├── ocr_service.dart
│   │   └── vision_context_builder.dart
│   ├── screens/               # UI screens
│   │   ├── home_screen.dart   # Main voice-first UI
│   │   ├── chat_screen.dart   # Conversation transcript
│   │   └── settings_screen.dart
│   └── widgets/               # Reusable UI components
│       ├── mic_button.dart    # Animated mic button
│       ├── status_indicator.dart
│       ├── caption_overlay.dart
│       └── bounding_box_painter.dart
├── assets/
│   ├── models/                # TFLite model files
│   └── labels/                # COCO class labels
└── pubspec.yaml
```

## 🔧 YOLOv8 Model Setup

The app requires a YOLOv8n TFLite model for on-device object detection:

```bash
pip install ultralytics
python -c "
from ultralytics import YOLO
model = YOLO('yolov8n.pt')
model.export(format='tflite', half=True)
"
```

Copy the exported `yolov8n_float16.tflite` to `assets/models/yolov8n.tflite`.

> **Note:** The app works without the model — it falls back to cloud-only vision analysis via Gemini.

## 📡 API Endpoints

| Endpoint | Type | Description |
|----------|------|-------------|
| `GET /health` | REST | Health check |
| `POST /api/vision` | REST | One-shot image analysis |
| `POST /api/clear-session` | REST | Clear conversation history |
| `WS /ws/chat` | WebSocket | Streaming chat with vision |

## 📄 License

MIT License
