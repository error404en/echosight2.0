"""
EchoSight Backend — FastAPI Server
WebSocket streaming chat + Vision analysis endpoints powered by Gemini 3.1 Pro.
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
from vision_engine import init_client, analyze_with_gemini, quick_analyze
from audio_engine import init_audio_engine, transcribe_audio, stream_tts
from face_engine import init_face_engine, detect_known_faces

# Load environment
load_dotenv()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize services on startup."""
    api_key = os.getenv("GEMINI_API_KEY", "")
    if api_key and api_key != "your_gemini_api_key_here":
        init_client(api_key)
        print("[OK] Gemini 3.1 Pro client initialized")
    else:
        print("[WARN] No GEMINI_API_KEY set - running in mock mode")
        
    groq_api_key = os.getenv("GROQ_API_KEY", "")
    init_audio_engine(groq_api_key)
    init_face_engine()
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
    return {"status": "ok", "service": "EchoSight API", "model": "gemini-3.1-pro-preview"}


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

            # 2. Extract specific identities from the image
            if image_b64:
                detected_names = detect_known_faces(image_b64)
                if detected_names:
                    if not vision_context:
                        vision_context = {}
                    vision_context["environment"] = vision_context.get("environment", "") + f" [Special Social Context: The following people are clearly identified directly in front of the user: {', '.join(detected_names)}]"

            # Get conversation session
            session = get_session(session_id)
            session.add_user_message(query, vision_context)

            # Build prompts
            system_prompt = session.get_system_prompt()
            history = session.get_history_for_api()

            # Stream response from Gemini
            full_response = []
            async for chunk in analyze_with_gemini(
                query=query,
                system_prompt=system_prompt,
                conversation_history=history[:-1],  # Exclude current message (already in contents)
                image_base64=image_b64,
                vision_context=vision_context,
            ):
                full_response.append(chunk)
                await websocket.send_text(chunk)

            # Save full response to conversation memory
            complete_response = "".join(full_response)
            session.add_assistant_message(complete_response)

            # Stream Edge-TTS audio back to Flutter
            async for audio_chunk in stream_tts(complete_response):
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
