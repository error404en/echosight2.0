# EchoSight 2.0 — AI-Powered Assistive Vision System

An advanced, multimodal AI-powered cross-platform mobile application that provides real-time vision understanding, assistive spatial navigation, face identification, OCR reading, and a fully conversational voice assistant specifically designed for the visually impaired.

## ✨ Core Features & Sub-Engines

- **🗣️ Voice-First Interface** — Natural conversational assistant using high-speed Groq Whisper (STT) and Cloud Edge-TTS (Text-To-Speech) for ultra-low latency conversations.
- **👁️ Real-Time Vision & Sight Mode** — Employs a proactive "Digital Retina". Auto-captures scenes continuously (Sight mode) while applying delta-awareness. If the scene hasn't changed, audio processing is skipped (`[SCENE_UNCHANGED]`) to prevent auditory fatigue.
- **🧠 Generative Reasoning (Groq + Llama 4 Scout Vision)** — Orchestrates hardware outputs (camera frames, spatial coords, GPS, OCR text) dynamically to answer advanced spatial queries ("Is there an empty chair I can sit on near the window?").
- **👥 Face Identity Engine** — Fast, local, hot-reloading `face_recognition` engine running on the backend that captures, caches, and instantly alerts the user when known friends or family are in view.
- **🧭 Spatial Navigation** — Injects live GPS telemetry (Lat/Lon/Heading/Speed) and active turn-by-turn route data directly into the AI context for guided outdoor mobility.
- **🛡️ Instant Hazard Detection (YOLOv8n)** — A robust on-device float16 YOLOv8 AI model evaluating 80 categories at high frame rates, generating instant spatial layouts ('Left', 'Near', 'Right') even entirely offline.
- **📖 Local Text Recognition (OCR)** — Tap-to-read functionality using Google ML Kit vector extraction.

## 🏗️ Technical Architecture Snapshot

```text
Flutter App (Edge Hardware)
├── Dynamic Fusion Engine (Coordinates states & modes)
├── Native Audio (flutter_tts / speech_to_text local fallbacks)
├── YOLOv8n TFLite (Float16 CPU object detection + Custom NMS)
├── Google ML Kit (Signage / Document OCR)
└── WebSocket Client (Auto-discovering fallback router)
        ↓
FastAPI Python Backend (Cloud Orchestrator)
├── Whisper Audio Engine (Groq LPU API)
├── Conversation Memory Manager (Delta checks & history)
├── Groq Vision Client (Multimodal spatial orchestrator)
└── Face Engine (dlib HOG face localization & embedding cache)
```

## 🚀 Quick Start

### Prerequisites
- Flutter SDK ≥ 3.2.0
- Python ≥ 3.10
- Android device/emulator with camera
- Keys: Groq API key (required), Google Maps Directions API key (optional)

### 1. Backend Setup

```bash
cd backend

# Create virtual environment
python -m venv venv
source venv/bin/activate  # Linux/Mac
# or: venv\Scripts\activate  # Windows

# Install dependencies
pip install -r requirements.txt

# Optional: For the Face Identity Engine, install face_recognition and numpy
# (Note: requires CMake and C++ build tools installed on your system)
# pip install CMake face_recognition numpy

# Configure API keys
# Create or edit backend/.env and supply your GROQ_API_KEY
# Optional: add GOOGLE_MAPS_API_KEY for turn-by-turn walking routes

# Start server
python main.py
```

> **Note on Connectivity:** The Python server automatically searches for `adb` in your system paths on startup and successfully executes `adb reverse tcp:8000 tcp:8000`. This provides zero-config immediate connectivity for physical Android devices plugged in via USB.

### 2. YOLOv8 Model Setup (On-Device Fallback)

The app utilizes a nano TFLite model for offline local processing.

```bash
pip install ultralytics
python -c "
from ultralytics import YOLO
model = YOLO('yolov8n.pt')
model.export(format='tflite', half=True)
"
```
Copy the exported `yolov8n_float16.tflite` directly to `assets/models/yolov8n_float16.tflite` inside the flutter project.

### 3. Flutter App Setup

```bash
# Get dependencies
flutter pub get

# Run on connected device
flutter run
```

### 4. Setting the Target Connection
The updated Socket Service includes **auto-discovery**. If the app fails to reach a stale loopback like `10.0.2.2`, it will auto-detect and default to `127.0.0.1:8000` over your ADB reverse tunnel, or optionally the PC's local WiFi IP if untethered.

## 📱 Operating Modes

EchoSight utilizes multiple distinct sensory states via the Fusion Engine:
1. **Assistant Mode** — General vision and Q&A. Standard tap-to-talk context-aware assistance.
2. **Surroundings Mode** — Passive awareness. Brief updates on what specifically changed in your immediate environment over time.
3. **Sight Mode (Continuous)** — Rich, continuous sight-like view of your surroundings that proactively constructs the world around you.
4. **Navigate Mode** — Spatial navigation that utilizes GPS, route step instructions, and visual obstacle tracking to ensure safety while walking outdoors.
5. **Reader Mode** — Focused specifically on detecting and reading document and signage text aloud seamlessly.
6. **Identify Mode** — Fast, detailed object descriptions utilizing both local fast detection and cloud vision querying.
7. **Emergency Mode** — Instant hardware override. Emits an SOS routine while forcing the Groq vision engine to drop conversational pleasantries and solely report immediate critical dangers / structural drop-offs in two sentences or less.

## 📄 License

MIT License
