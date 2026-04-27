"""
EchoSight Backend — FastAPI Server
WebSocket streaming chat + vision analysis endpoints powered by Groq.
"""

import json
import os
from contextlib import asynccontextmanager
from typing import Optional

from dotenv import load_dotenv
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from conversation import get_session, clear_session
from vision_engine import init_client, analyze_with_groq, get_model_id, quick_analyze
from audio_engine import init_audio_engine, transcribe_audio, stream_tts
from face_engine import init_face_engine, detect_known_faces
from navigation_engine import (
    fetch_walking_route, get_active_route, clear_route,
    build_navigation_context,
)

# Load environment
load_dotenv()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize services on startup."""
    groq_api_key = os.getenv("GROQ_API_KEY", "")

    if groq_api_key and groq_api_key != "your_groq_api_key_here":
        init_client(groq_api_key)
        print(f"[OK] Groq vision client initialized ({get_model_id()})")
    else:
        print("[WARN] No GROQ_API_KEY set - running in mock mode")

    init_audio_engine(groq_api_key)
    init_face_engine()

    # Permanently resolve Flutter USB/ADB connectivity by mapping the port on startup
    try:
        import subprocess
        import shutil

        adb_path = shutil.which("adb")
        if not adb_path:
            win_path = os.path.expanduser(r"~\AppData\Local\Android\Sdk\platform-tools\adb.exe")
            if os.path.exists(win_path):
                adb_path = win_path

        if adb_path:
            subprocess.run([adb_path, "reverse", "tcp:8000", "tcp:8000"], check=False)
            print("[OK] Set up ADB reverse port forwarding for port 8000")
        else:
            print("[WARN] Could not find ADB executable to set up port forwarding.")
    except Exception as e:
        print(f"[WARN] Could not set up ADB reverse: {e}")

    yield


app = FastAPI(
    title="EchoSight API",
    description="AI-powered assistive vision backend",
    version="1.0.0",
    lifespan=lifespan,
)

# CORS for Flutter app
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ─── REST Endpoints ─────────────────────────────────────────────

@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {
        "status": "ok",
        "service": "EchoSight API",
        "provider": "groq",
        "model": get_model_id(),
    }


class VisionRequest(BaseModel):
    image: str  # base64 encoded JPEG
    prompt: Optional[str] = None
    session_id: Optional[str] = None


class VisionResponse(BaseModel):
    description: str
    session_id: Optional[str] = None


@app.post("/api/vision", response_model=VisionResponse)
async def analyze_vision(request: VisionRequest):
    """One-shot vision analysis endpoint."""
    prompt = request.prompt or "Describe this scene for a visually impaired person. Focus on obstacles, text, and navigation cues."
    try:
        result = await quick_analyze(request.image, prompt)
        return VisionResponse(description=result, session_id=request.session_id)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


class ClearSessionRequest(BaseModel):
    session_id: str


@app.post("/api/clear-session")
async def clear_chat_session(request: ClearSessionRequest):
    """Clear conversation history for a session."""
    clear_session(request.session_id)
    return {"status": "cleared", "session_id": request.session_id}


class AddFaceRequest(BaseModel):
    name: str
    image: str  # Base64 JPEG

@app.post("/api/add-face")
async def add_known_face(request: AddFaceRequest):
    """Save a face to the local database and hot-reload."""
    if not request.name.strip() or not request.image:
        raise HTTPException(status_code=400, detail="Name and image required.")

    try:
        from face_engine import KNOWN_FACES_DIR, init_face_engine
        import base64
        import os

        # Ensure directory exists
        if not os.path.exists(KNOWN_FACES_DIR):
            os.makedirs(KNOWN_FACES_DIR)

        # Clean filename
        clean_name = "".join(x for x in request.name if x.isalnum() or x in " _-")
        filepath = os.path.join(KNOWN_FACES_DIR, f"{clean_name}.jpg")

        # Save image
        image_bytes = base64.b64decode(request.image)
        with open(filepath, "wb") as f:
            f.write(image_bytes)

        # Hot reload engine
        init_face_engine()
        return {"status": "success", "name": request.name}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# --- PLACES MEMORY ENGINE ---
import json
import math

PLACES_FILE = "saved_places.json"

class MemorizePlaceRequest(BaseModel):
    name: str
    lat: float
    lng: float

@app.post("/api/memorize-place")
async def memorize_place(request: MemorizePlaceRequest):
    """Save a GPS location with a semantic name."""
    if not request.name.strip():
        raise HTTPException(status_code=400, detail="Name required.")
        
    try:
        places = {}
        if os.path.exists(PLACES_FILE):
            with open(PLACES_FILE, "r") as f:
                places = json.load(f)
                
        # Clean the name to be dictionary-safe
        clean_name = request.name.strip().title()
        places[clean_name] = {"lat": request.lat, "lng": request.lng}
        
        with open(PLACES_FILE, "w") as f:
            json.dump(places, f, indent=4)
            
        return {"status": "success", "name": clean_name}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

def _get_nearest_saved_place(lat: float, lng: float, threshold_meters: float = 30.0) -> str:
    """Returns the name of the nearest saved place if within threshold."""
    if not os.path.exists(PLACES_FILE):
        return ""
        
    try:
        with open(PLACES_FILE, "r") as f:
            places = json.load(f)
            
        closest_name = ""
        min_dist = float('inf')
        
        for name, coords in places.items():
            # Haversine distance
            R = 6371e3
            phi1 = math.radians(lat)
            phi2 = math.radians(coords["lat"])
            dphi = math.radians(coords["lat"] - lat)
            dlambda = math.radians(coords["lng"] - lng)
            
            a = math.sin(dphi/2) * math.sin(dphi/2) + \
                math.cos(phi1) * math.cos(phi2) * \
                math.sin(dlambda/2) * math.sin(dlambda/2)
            c = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))
            dist = R * c
            
            if dist < min_dist and dist <= threshold_meters:
                min_dist = dist
                closest_name = name
                
        return closest_name
    except Exception as e:
        print(f"[ERR] Failed to read saved places: {e}")
        return ""

# --- CHAT SESSION STATE ---
@app.get("/api/voices")
async def get_voices():
    """Return available TTS voices for the settings menu."""
    return {
        "voices": [
            {"id": "en-US-JennyNeural", "name": "Jenny (Warm Female)", "gender": "Female"},
            {"id": "en-US-GuyNeural", "name": "Guy (Calm Male)", "gender": "Male"},
            {"id": "en-US-AriaNeural", "name": "Aria (Expressive Female)", "gender": "Female"},
            {"id": "en-US-DavisNeural", "name": "Davis (Deep Male)", "gender": "Male"},
            {"id": "en-US-SteffanNeural", "name": "Steffan (Clear Male)", "gender": "Male"},
            {"id": "en-US-JaneNeural", "name": "Jane (Friendly Female)", "gender": "Female"},
        ]
    }


# ─── Navigation Endpoints ───────────────────────────────────────

class StartNavigationRequest(BaseModel):
    session_id: str
    destination: str
    latitude: float
    longitude: float


@app.post("/api/navigate/start")
async def start_navigation(request: StartNavigationRequest):
    """Fetch a walking route and begin guided navigation."""
    try:
        route = await fetch_walking_route(
            origin_lat=request.latitude,
            origin_lng=request.longitude,
            destination=request.destination,
            session_id=request.session_id,
        )
        if route is None:
            raise HTTPException(status_code=404, detail="Could not find a route to that destination.")
        return {"status": "ok", "route": route.to_dict()}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


class StopNavigationRequest(BaseModel):
    session_id: str


@app.post("/api/navigate/stop")
async def stop_navigation(request: StopNavigationRequest):
    """Stop active navigation for a session."""
    clear_route(request.session_id)
    return {"status": "stopped", "session_id": request.session_id}


# ─── WebSocket Chat Endpoint ────────────────────────────────────

@app.websocket("/ws/chat")
async def websocket_chat(websocket: WebSocket):
    """
    Streaming conversational chat over WebSocket.

    Client sends JSON:
    {
        "session_id": "unique-id",
        "query": "user's spoken text",
        "image": "base64 JPEG (optional)",
        "vision_context": { "objects": [...], "text": "...", "environment": "..." } (optional)
    }

    Server streams back text chunks, ending with [DONE].
    """
    await websocket.accept()
    print("[WS] WebSocket client connected")

    try:
        while True:
            # Receive message from client
            raw = await websocket.receive_text()

            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                await websocket.send_text("[ERROR] Invalid JSON")
                continue

            session_id = data.get("session_id", "default")
            query = data.get("query", "").strip()
            audio_b64 = data.get("audio")
            image_b64 = data.get("image")
            vision_context = data.get("vision_context")
            mode = data.get("mode", "assistant")
            voice_id = data.get("voice", "en-US-JennyNeural")
            tts_rate = data.get("ttsRate", "+0%")

            # 1. Transcribe Audio if present
            if audio_b64:
                query = await transcribe_audio(audio_b64)
                if not query:
                    await websocket.send_text("[ERROR] Could not transcribe audio.")
                    continue
                # Let flutter know what was heard
                await websocket.send_text(f"[TRANSCRIPT] {query}")

            if not query:
                await websocket.send_text("[ERROR] Empty query")
                continue

            # 2. Extract specific identities from the image (skip for chat mode — no image)
            if image_b64 and mode != "chat":
                detected_names = detect_known_faces(image_b64)
                if detected_names:
                    if not vision_context:
                        vision_context = {}
                    vision_context["environment"] = vision_context.get("environment", "") + f" [Special Social Context: The following people are clearly identified directly in front of the user: {', '.join(detected_names)}]"

            # Get conversation session
            session = get_session(session_id)
            session.add_user_message(query, vision_context)

            # ─── Navigation context injection ───────────────────
            location_data = data.get("location")
            location_context = ""
            if location_data:
                lat = float(location_data.get("latitude", 0))
                lng = float(location_data.get("longitude", 0))
                addr = location_data.get("address", "")
                
                # Perform backend reverse geocoding if address is missing
                if not addr and lat != 0 and lng != 0:
                    import httpx
                    try:
                        url = f"https://nominatim.openstreetmap.org/reverse?format=json&lat={lat}&lon={lng}&zoom=18&addressdetails=1"
                        headers = {"User-Agent": "EchoSight/1.0"}
                        async with httpx.AsyncClient() as client:
                            resp = await client.get(url, headers=headers, timeout=2.0)
                            if resp.status_code == 200:
                                d = resp.json()
                                a = d.get("address", {})
                                parts = [a.get("road"), a.get("suburb"), a.get("city") or a.get("town") or a.get("village")]
                                addr = ", ".join([p for p in parts if p]) or d.get("display_name", "")
                    except Exception as e:
                        print(f"[WARN] Backend reverse geocode failed: {e}")
                
                # Do NOT pass raw GPS strings that the AI might read out loud.
                # Only pass human-readable info.
                location_context = "Location Constraints: NEVER read raw GPS coordinates out loud. Use general, human-understandable terms. "
                if addr:
                    location_context += f"| Current Physical Address: {addr}"
                    
                nearest_place = _get_nearest_saved_place(lat, lng)
                if nearest_place:
                    location_context += f" | NOTE: User is currently at their saved place: '{nearest_place}'."

            active_route = get_active_route(session_id)
            if active_route and not active_route.is_complete and location_data:
                nav_ctx = build_navigation_context(
                    route=active_route,
                    current_lat=location_data.get("latitude", 0),
                    current_lng=location_data.get("longitude", 0),
                    heading=location_data.get("heading", 0),
                )
                # Override mode to navigation_active
                mode = "navigation_active"
                # Append turn-by-turn data to vision context
                if not vision_context:
                    vision_context = {}
                vision_context["navigation"] = nav_ctx

                # Notify Flutter if arrived
                if nav_ctx.get("status") == "arrived":
                    await websocket.send_text("[NAV_ARRIVED]")

            # ─── Surroundings scene memory injection ─────────────
            scene_memory = data.get("scene_memory", "")
            if mode in ("surroundings", "sight", "auto") and scene_memory:
                if not vision_context:
                    vision_context = {}
                vision_context["scene_memory"] = scene_memory

            # Build prompts
            system_prompt = session.get_system_prompt(mode)
            history = session.get_history_for_api()

            # Stream response from the Groq vision model
            full_response = []
            buffer = ""
            mode_switch_completed = False
            
            import re
            
            async for chunk in analyze_with_groq(
                query=query,
                system_prompt=system_prompt,
                conversation_history=history[:-1],  # Exclude current message (already in contents)
                image_base64=image_b64,
                vision_context=vision_context,
                location_data=location_data,
            ):
                full_response.append(chunk)
                
                # Check for zero-latency mode switch tag at the beginning of the stream
                if not mode_switch_completed:
                    buffer += chunk
                    if buffer.startswith("[MODE_SWITCH:"):
                        if "]" in buffer:
                            tag_end = buffer.find("]")
                            tag = buffer[:tag_end+1]
                            mode_to_switch = tag.split(":")[1].strip(" ]")
                            await websocket.send_text(f"[COMMAND_SWITCH_MODE: {mode_to_switch}]")
                            mode_switch_completed = True
                            
                            # Send whatever is left after the tag
                            remainder = buffer[tag_end+1:].lstrip()
                            if remainder:
                                await websocket.send_text(remainder)
                    elif len(buffer) > 15 and not buffer.startswith("["):
                        # Clearly not a tag, flush buffer
                        mode_switch_completed = True
                        await websocket.send_text(buffer)
                else:
                    await websocket.send_text(chunk)

            # Save full response to conversation memory (skip errors/rate limits)
            complete_response = "".join(full_response)
            
            # Strip the tag from the final response so TTS doesn't speak it
            clean_response = re.sub(r'\[MODE_SWITCH:.*?\]', '', complete_response).strip()
            
            if clean_response and not clean_response.startswith("[ERROR]") and clean_response != "[RATE_LIMIT]":
                session.add_assistant_message(clean_response)

            # For surroundings mode: send scene memory back to Flutter
            # and skip TTS if "no changes"
            is_no_change = (
                mode in ("surroundings", "sight", "auto") and
                clean_response.lower().replace(".", "") in
                ["no changes", "no change", "nothing changed"]
            )

            if is_no_change:
                await websocket.send_text("[SCENE_UNCHANGED]")
            else:
                # Send scene memory update back to Flutter
                if mode in ("surroundings", "sight", "auto"):
                    await websocket.send_text(f"[SCENE_MEMORY] {clean_response}")

                # Stream Edge-TTS audio back to Flutter
                async for audio_chunk in stream_tts(clean_response, voice=voice_id, rate=tts_rate):
                    await websocket.send_text(f"[AUDIO] {audio_chunk}")

            # Signal end of response
            await websocket.send_text("[DONE]")

    except WebSocketDisconnect:
        print("[WS] WebSocket client disconnected")
    except Exception as e:
        print(f"[ERR] WebSocket error: {e}")
        try:
            await websocket.send_text(f"[ERROR] {str(e)}")
        except:
            pass


# ─── Run ─────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
