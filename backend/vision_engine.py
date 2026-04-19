"""
EchoSight Backend - Vision Engine
Handles Groq-hosted open-weight vision analysis with streaming support.
"""

import asyncio
import os
from typing import AsyncGenerator, Optional

from groq import AsyncGroq

DEFAULT_VISION_MODEL_ID = "meta-llama/llama-4-scout-17b-16e-instruct"

# Will be initialized in main.py lifespan
client: Optional[AsyncGroq] = None


def get_model_id() -> str:
    """Return the configured Groq vision model id."""
    configured = os.getenv("GROQ_VISION_MODEL", "").strip()
    return configured or DEFAULT_VISION_MODEL_ID


def init_client(api_key: str):
    """Initialize the Groq client."""
    global client
    client = AsyncGroq(api_key=api_key)


def _build_context_parts(
    vision_context: Optional[dict],
    location_data: Optional[dict],
) -> list[str]:
    """Flatten sensor context into text the vision model can reliably use."""
    context_parts: list[str] = []

    if vision_context:
        if vision_context.get("objects"):
            objects = ", ".join(
                f"{obj.get('label', 'unknown')} ({obj.get('distance', 'mid')} distance, {obj.get('position', 'unknown')})"
                for obj in vision_context["objects"]
            )
            context_parts.append(f"Detected objects: {objects}")
        if vision_context.get("text"):
            context_parts.append(f"OCR text: {vision_context['text']}")
        if vision_context.get("environment"):
            context_parts.append(f"Environment: {vision_context['environment']}")
        if vision_context.get("scene_memory"):
            context_parts.append(
                "Previous scene description from the last scan: "
                f"{vision_context['scene_memory']}"
            )
        if vision_context.get("navigation"):
            navigation = vision_context["navigation"]
            nav_parts: list[str] = []
            if navigation.get("status"):
                nav_parts.append(f"status {navigation['status']}")
            if navigation.get("current_step") and navigation.get("total_steps"):
                nav_parts.append(
                    f"step {navigation['current_step']} of {navigation['total_steps']}"
                )
            if navigation.get("instruction"):
                nav_parts.append(f"current instruction: {navigation['instruction']}")
            if navigation.get("distance_remaining"):
                nav_parts.append(
                    f"distance remaining: {navigation['distance_remaining']}"
                )
            if navigation.get("direction_to_waypoint"):
                nav_parts.append(f"direction: {navigation['direction_to_waypoint']}")
            if navigation.get("next_instruction"):
                nav_parts.append(f"next: {navigation['next_instruction']}")
            if nav_parts:
                context_parts.append("Navigation: " + "; ".join(nav_parts))

    if location_data:
        lat = location_data.get("latitude", 0.0)
        lon = location_data.get("longitude", 0.0)
        heading = location_data.get("heading", 0.0)
        speed = location_data.get("speed", 0.0)
        context_parts.append(
            "GPS Data: "
            f"Lat {lat:.5f}, Lon {lon:.5f}, Heading {heading:.1f}deg, Speed {speed:.1f}m/s"
        )

    return context_parts


async def analyze_with_groq(
    query: str,
    system_prompt: str,
    conversation_history: list[dict],
    image_base64: Optional[str] = None,
    vision_context: Optional[dict] = None,
    location_data: Optional[dict] = None,
) -> AsyncGenerator[str, None]:
    """Stream a response from the configured Groq vision model."""
    if client is None:
        yield "[ERROR] Groq client not initialized. Please set GROQ_API_KEY."
        return

    lowercase_query = query.lower()
    if "help" in lowercase_query or "emergency" in lowercase_query:
        system_prompt = (
            "YOU ARE IN STRICT EMERGENCY MODE. IGNORE CONVERSATIONAL PLEASANTRIES. "
            "EVALUATE THE IMMEDIATELY VISUALIZED SURROUNDINGS FOR CRITICAL DANGERS, "
            "DROP-OFFS, INCOMING VEHICLES, OR THREATS. REPORT THEM IMMEDIATELY IN 2 SENTENCES OR LESS."
        )

    messages = [{"role": "system", "content": system_prompt}]

    for message in conversation_history[-10:]:
        role = message["role"]
        if role in ("model", "assistant"):
            role = "assistant"
        else:
            role = "user"

        text_content = " ".join(
            part.get("text", "")
            for part in message.get("parts", [])
            if "text" in part
        ).strip()
        if text_content:
            messages.append({"role": role, "content": text_content})

    current_content: list[dict] = []
    context_parts = _build_context_parts(vision_context, location_data)
    if context_parts:
        current_content.append(
            {
                "type": "text",
                "text": "[Sensor Context Data]\n" + "\n".join(context_parts),
            }
        )

    current_content.append({"type": "text", "text": query})

    if image_base64:
        current_content.append(
            {
                "type": "image_url",
                "image_url": {"url": f"data:image/jpeg;base64,{image_base64}"},
            }
        )

    messages.append({"role": "user", "content": current_content})

    try:
        chat_completion = await client.chat.completions.create(
            messages=messages,
            model=get_model_id(),
            temperature=0.4,
            max_completion_tokens=1024,
            stream=True,
        )

        async for chunk in chat_completion:
            content = chunk.choices[0].delta.content
            if content:
                yield content
            await asyncio.sleep(0)

    except Exception as exc:
        error_msg = str(exc)
        lowered = error_msg.lower()
        if "quota" in lowered or "rate" in lowered or "429" in error_msg:
            yield "[RATE_LIMIT]"
        elif "api_key" in lowered or "auth" in lowered:
            yield "[ERROR] API key issue. Please check your Groq API key configuration."
        else:
            yield f"[ERROR] {error_msg}"


async def quick_analyze(
    image_base64: str,
    prompt: str = "Describe this scene briefly for a visually impaired person. Focus on obstacles, text, and navigation cues.",
) -> str:
    """One-shot vision analysis without conversation history."""
    if client is None:
        return "Groq client not initialized."

    try:
        response = await client.chat.completions.create(
            messages=[
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": prompt},
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:image/jpeg;base64,{image_base64}"
                            },
                        },
                    ],
                }
            ],
            model=get_model_id(),
            temperature=0.3,
            max_completion_tokens=512,
        )
        return response.choices[0].message.content or "Could not analyze the image."
    except Exception as exc:
        return f"Vision analysis error: {str(exc)}"
