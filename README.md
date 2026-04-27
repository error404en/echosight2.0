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

## 🔄 System Pipeline

The following diagram illustrates how sensory data moves through the EchoSight architecture:

```text
[ USER ENVIRONMENT ]
       │
       ├─► (Camera) ───────► Local YOLOv8 (Offline Hazards) ────────┐
       ├─► (Microphone) ───► Intelligent Noise Filter ──────────────┤
       ├─► (GPS Sensor) ───► Background Location Tracking ──────────┤
       │                                                            │
[ FLUTTER FUSION ENGINE ] ◄─────────────────────────────────────────┘
       │
       ├─► Packages VisionContext (Objects, OCR, Motion)
       ├─► Enforces Mode State (Auto, Surroundings, Identify, Chat)
       │
       ▼ (WebSocket Stream)
[ PYTHON BACKEND ORCHESTRATOR ]
       │
       ├─► STT (Whisper) converts audio to text
       ├─► Backend Reverse Geocoding (OpenStreetMap) injects human-readable location
       ├─► Face Recognition checks `Face Identity Engine` against embedding cache
       │
       ▼ (Prompt Injection)
[ GROQ LLM & VISION (Llama 4 Scout) ]
       │
       ├─► Evaluates strict World Knowledge constraints & Contextual Logic
       ├─► Zero-Latency Mode Router (Emits [MODE_SWITCH:] tags)
       ├─► Delta-Awareness (Emits [SCENE_UNCHANGED] if static)
       │
       ▼ (Streaming Text Response)
[ FLUTTER FUSION ENGINE ]
       │
       ├─► Catches tags (Switches UI mode instantly)
       ├─► Triggers Native TTS (Speaks aloud)
       ├─► Ambient Reassurance (Handles dead-air silence)
       │
       ▼
[ USER FEEDBACK (Audio/Haptic) ]
```

## 📅 Recent Updates & Changelog

### 🧠 Intelligence & Context
- **World Knowledge Integration**: The AI no longer just reads raw text or lists objects. It applies contextual intelligence (e.g., explaining the dosage instructions on a pill bottle label or warning if a cup is on a table edge).
- **Zero-Latency Intent Routing**: The AI can now seamlessly switch modes mid-conversation using `[MODE_SWITCH:]` tags based on user intent (e.g., automatically switching to 'Navigate' if the user asks for directions).
- **Backend Reverse Geocoding**: Removed buggy on-device geocoding plugins. Location is now handled entirely via the backend (OpenStreetMap), converting raw coordinates into human-readable contexts. Raw GPS numbers are strictly filtered out of the AI's TTS responses.

### 🔇 Eliminating Silence & Noise
- **Continuous Background Listening**: The microphone loop now restarts automatically, creating a hands-free, always-on experience.
- **Intelligent Noise Filter**: Implemented local volume-threshold filtering to drop background noise and static before it reaches the cloud, preventing API rate-limit exhaustion.
- **Ambient Reassurance**: In continuous scanning modes (like `Surroundings`), if the AI detects no changes, it will gently reassure the user periodically (e.g., "Everything looks the same") rather than abandoning them in terrifying silence.

### 🛡️ Safety & Stability
- **Native Android SOS**: Background SMS routing is now handled by a custom `MethodChannel` directly to Android Native APIs, bypassing deprecated Flutter plugins to ensure reliable delivery even when the screen is locked.
- **Sub-Second Mode Switching**: Hardcoded 3-4 second delays between mode switches were removed. Transitions are now near-instantaneous (<200ms).

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
flutter pub get
flutter run
```

## 📱 Operating Modes

EchoSight utilizes multiple distinct sensory states via the Fusion Engine:
1. **Assistant Mode** — General vision and Q&A. Standard tap-to-talk context-aware assistance.
2. **Surroundings Mode** — Passive awareness. Brief updates on what specifically changed in your immediate environment over time.
3. **Sight Mode (Continuous)** — Rich, continuous sight-like view of your surroundings that proactively constructs the world around you.
4. **Navigate Mode** — Spatial navigation that utilizes GPS, route step instructions, and visual obstacle tracking to ensure safety while walking outdoors.
5. **Reader Mode** — Focused specifically on detecting and reading document and signage text aloud seamlessly.
6. **Identify Mode** — Fast, detailed object descriptions utilizing both local fast detection and cloud vision querying.
7. **Emergency Mode** — Instant hardware override. Emits an SOS routine while forcing the Groq vision engine to drop conversational pleasantries and solely report immediate critical dangers.

## 📄 License
MIT License
