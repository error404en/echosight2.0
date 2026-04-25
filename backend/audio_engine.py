import os
import io
import json
import base64
from groq import AsyncGroq
import edge_tts
import asyncio

# Retrieve API keys
client: AsyncGroq | None = None

def init_audio_engine(groq_api_key: str):
    global client
    if groq_api_key and groq_api_key != "your_groq_api_key_here":
        client = AsyncGroq(api_key=groq_api_key)
        print("[OK] Groq Whisper client initialized")
    else:
        print("[WARN] No GROQ_API_KEY set - whisper transcription disabled")

async def transcribe_audio(audio_base64: str) -> str:
    """Uses Groq's high-speed Whisper Large v3 to transcribe audio instantly."""
    if not client:
        return ""
    
    try:
        # Decode base64 to binary
        audio_bytes = base64.b64decode(audio_base64)
        
        # Groq SDK expects a tuple of (filename, file_bytes)
        file_obj = ("audio.wav", audio_bytes)
        
        # Hit Groq Whisper endpoint
        transcription = await client.audio.transcriptions.create(
            file=file_obj,
            model="whisper-large-v3",
            response_format="text",
            language="en"
        )
        return str(transcription).strip()
    except Exception as e:
        print(f"[ERR] Groq Transcription failed: {e}")
        return ""

async def stream_tts(text: str, voice: str = "en-US-JennyNeural", rate: str = "+0%"):
    """Generates ultra-realistic voice using Edge-TTS and yields base64 audio chunks.
    
    Uses larger buffer (128KB) to reduce gaps between chunks on the client side.
    The entire audio is collected and sent as a single chunk when possible to
    eliminate mid-sentence stuttering completely.
    """
    try:
        # Voice: Microsoft Jenny, Guy, Aria, Davis, etc.
        communicate = edge_tts.Communicate(text, voice, rate=rate)
        
        chunk_buffer = bytearray()
        chunk_threshold = 131072 # 128KB — larger chunks reduce client-side audio gaps
        
        # Collect and stream chunks without waiting for the whole file
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                chunk_buffer.extend(chunk["data"])
                if len(chunk_buffer) >= chunk_threshold:
                    yield base64.b64encode(chunk_buffer).decode('utf-8')
                    chunk_buffer.clear()
                    
        # Yield trailing audio
        if chunk_buffer:
            yield base64.b64encode(chunk_buffer).decode('utf-8')
        
    except Exception as e:
        print(f"[ERR] Edge-TTS streaming failed: {e}")
