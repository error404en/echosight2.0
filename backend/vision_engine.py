"""
EchoSight Backend — Vision Engine
Handles Gemini 3.1 Pro vision analysis with streaming support.
"""

import base64
import asyncio
from typing import Optional, AsyncGenerator
from google import genai
from google.genai import types


# Will be initialized in main.py lifespan
client: Optional[genai.Client] = None
MODEL_ID = "gemini-3.1-pro-preview"


def init_client(api_key: str):
    """Initialize the Gemini client."""
    global client
    client = genai.Client(api_key=api_key)


async def analyze_with_gemini(
    query: str,
    system_prompt: str,
    conversation_history: list[dict],
    image_base64: Optional[str] = None,
    vision_context: Optional[dict] = None,
    location_data: Optional[dict] = None,
) -> AsyncGenerator[str, None]:
    """
    Stream a response from Gemini 3.1 Pro.
    Supports text-only, vision+text, and GPS queries.
    """
    if client is None:
        yield "Error: Gemini client not initialized. Please set GEMINI_API_KEY."
        return

    # Trigger Emergency Override if 'help' or 'emergency' is spoken.
    lowercase_query = query.lower()
    if "help" in lowercase_query or "emergency" in lowercase_query:
        system_prompt = (
            "YOU ARE IN STRICT EMERGENCY MODE. IGNORE CONVERSATIONAL PLEASANTRIES. "
            "EVALUATE THE IMMEDIATELY VISUALIZED SURROUNDINGS FOR CRITICAL DANGERS, "
            "DROP-OFFS, INCOMING VEHICLES, OR THREATS. REPORT THEM IMMEDIATELY IN 2 SENTENCES OR LESS."
        )

    # Build the content parts for the current message
    parts = []

    # Add vision context as text if available
    context_parts = []
    if vision_context:
        if vision_context.get("objects"):
            objs = ", ".join(
                f"{o['label']} ({o.get('distance', 'mid')} distance, {o.get('position', 'unknown')})"
                for o in vision_context["objects"]
            )
            context_parts.append(f"Detected objects: {objs}")
        if vision_context.get("text"):
            context_parts.append(f"OCR text: {vision_context['text']}")
        if vision_context.get("environment"):
            context_parts.append(f"Environment: {vision_context['environment']}")
            
    if location_data:
        lat = location_data.get('latitude', 0.0)
        lon = location_data.get('longitude', 0.0)
        heading = location_data.get('heading', 0.0)
        speed = location_data.get('speed', 0.0)
        context_parts.append(f"GPS Data: Lat {lat:.5f}, Lon {lon:.5f}, Heading {heading:.1f}deg, Speed {speed:.1f}m/s")
        
    if context_parts:
        parts.append(types.Part.from_text(
            text="[Sensor Context Data]\n" + "\n".join(context_parts)
        ))

    # Add image if provided
    if image_base64:
        try:
            image_bytes = base64.b64decode(image_base64)
            parts.append(types.Part.from_bytes(
                data=image_bytes,
                mime_type="image/jpeg",
            ))
        except Exception as e:
            print(f"Warning: Could not decode image: {e}")

    # Add the user's query
    parts.append(types.Part.from_text(text=query))

    # Build contents with conversation history + current message
    contents = []

    # Add conversation history (limited to avoid token overflow)
    for msg in conversation_history[-10:]:
        role = msg["role"]
        if role == "assistant":
            role = "model"
        msg_parts = [types.Part.from_text(text=p["text"]) for p in msg.get("parts", [])]
        contents.append(types.Content(role=role, parts=msg_parts))

    # Add current user message
    contents.append(types.Content(role="user", parts=parts))

    # Generate streaming response
    try:
        response = client.models.generate_content_stream(
            model=MODEL_ID,
            contents=contents,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
                temperature=1.0,
                max_output_tokens=1024,
            ),
        )

        for chunk in response:
            if chunk.text:
                yield chunk.text
            # Small delay to prevent blocking
            await asyncio.sleep(0)

    except Exception as e:
        error_msg = str(e)
        if "quota" in error_msg.lower() or "rate" in error_msg.lower():
            yield "I'm currently rate-limited. Please try again in a moment."
        elif "api_key" in error_msg.lower() or "auth" in error_msg.lower():
            yield "API key issue. Please check your Gemini API key configuration."
        else:
            yield f"I encountered an error: {error_msg}"


async def quick_analyze(
    image_base64: str,
    prompt: str = "Describe this scene briefly for a visually impaired person. Focus on obstacles, text, and navigation cues.",
) -> str:
    """One-shot vision analysis without conversation history."""
    if client is None:
        return "Gemini client not initialized."

    try:
        image_bytes = base64.b64decode(image_base64)
        response = client.models.generate_content(
            model=MODEL_ID,
            contents=[
                types.Content(
                    role="user",
                    parts=[
                        types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"),
                        types.Part.from_text(text=prompt),
                    ],
                )
            ],
            config=types.GenerateContentConfig(
                temperature=0.7,
                max_output_tokens=512,
            ),
        )
        return response.text or "Could not analyze the image."
    except Exception as e:
        return f"Vision analysis error: {str(e)}"
