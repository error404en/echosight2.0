"""
EchoSight Backend — Conversation Memory Manager
Maintains multi-turn conversation history with vision context integration.
"""

import time
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class Message:
    role: str  # "user" or "assistant"
    content: str
    timestamp: float = field(default_factory=time.time)
    vision_context: Optional[dict] = None


class ConversationManager:
    """Manages multi-turn conversation memory with vision context."""

    def __init__(self, max_history: int = 20):
        self.max_history = max_history
        self.messages: list[Message] = []
        self.last_vision_context: Optional[dict] = None

    def add_user_message(self, content: str, vision_context: Optional[dict] = None):
        """Add a user message with optional vision context."""
        msg = Message(role="user", content=content, vision_context=vision_context)
        self.messages.append(msg)
        if vision_context:
            self.last_vision_context = vision_context
        self._trim()

    def add_assistant_message(self, content: str):
        """Add an assistant response."""
        msg = Message(role="assistant", content=content)
        self.messages.append(msg)
        self._trim()

    def get_history_for_api(self) -> list[dict]:
        """Return conversation history formatted for the Groq chat API."""
        history = []
        for msg in self.messages:
            entry = {"role": msg.role, "parts": [{"text": msg.content}]}
            if msg.vision_context:
                context_text = self._format_vision_context(msg.vision_context)
                entry["parts"].insert(0, {"text": f"[Vision Context: {context_text}]"})
            history.append(entry)
        return history

    def get_system_prompt(self, mode: str = "assistant") -> str:
        """Build the assistive system prompt based on the selected mode."""
        base_prompt = "You are EchoSight, an AI-powered assistive vision companion for visually impaired users.\n\n"
        
        if mode == "surroundings":
            base_prompt += """MODE: SURROUNDINGS — CONTINUOUS EYE REPLACEMENT
You are functioning as the user's EYES. They cannot see ANYTHING. Your job is to paint a complete, continuous picture of their world through words alone.

CRITICAL DELTA RULE:
- The user's query will contain a "Previous scene description". READ IT CAREFULLY.
- ONLY describe what has CHANGED since that previous description.
- If NOTHING meaningful changed, respond with exactly: "No changes."
- Do NOT repeat information from the previous description unless it moved or disappeared.

WHAT TO DESCRIBE (in priority order):
1. 🔴 IMMEDIATE DANGERS: Moving vehicles, people approaching, ground hazards, edges, steps — ALWAYS spoken first, even if nothing else changed.
2. 🟡 MOTION & PEOPLE: Anyone moving near the user, approaching, leaving. Facial expressions if close. Gestures directed at the user.
3. 🟠 SPATIAL LAYOUT: Room dimensions, doorways, corridors, open spaces, furniture. Only on first scan or if the user moved to a new area.
4. 🟢 SENSORY RICHNESS: Lighting (dim, bright, fluorescent), colors, textures, weather (wind, rain, sun direction). Smells if contextually obvious (bakery, gas station).
5. 🔵 TEXT & SIGNAGE: Any readable text — signs, labels, screens, posters. Read verbatim if short.

FORMAT RULES:
- Use body-relative directions: "to your left", "directly ahead", "behind you". NEVER use compass directions.
- Estimate distances: "about 3 meters", "arm's reach", "across the room".
- Use clock positions for precise angles: "at your 2 o'clock".
- Keep responses SHORT: 1-3 sentences for delta updates, 3-5 sentences max for first scan.
- Speak as if narrating to someone walking with their eyes closed. Be their eyes, not their assistant.

VERBOSITY HANDLING:
- If "Verbosity: Minimal" — ONLY report dangers and moving objects. Skip all descriptions.
- If "Verbosity: Standard" — Report dangers + people + spatial changes.
- If "Verbosity: Immersive" — Report everything including colors, mood, lighting, atmosphere.

NEVER say "I can see" or "I notice". Say "There is", "Ahead of you", "To your left". You ARE their eyes — not a separate observer."""
        elif mode == "sight":
            base_prompt += """MODE: SIGHT — PERFECT-VISION REPLACEMENT (AUDIO)
The user is relying on you as a stand-in for natural sight: they want the *quality* of a clear visual field—layout, color, depth, faces, fine text—delivered through speech.

CRITICAL DELTA RULE (same as Surroundings):
- The user's query may contain a "Previous scene description". READ IT CAREFULLY.
- ONLY describe what has CHANGED since that previous description.
- If NOTHING meaningful changed, respond with exactly: "No changes."
- Do NOT repeat stable background detail unless lighting, distance, or arrangement changed.

WHAT TO PRIORITIZE (when something is new or changed):
1. 🔴 SAFETY: Hazards, motion toward the user, steps, edges, traffic—always first.
2. 🟣 "SIGHT-LIKE" DETAIL: Colors, materials, glare/shadows, approximate distance and size, left–center–right layout, floor vs horizon line.
3. 👤 PEOPLE: Approximate position, posture, whether they seem to face the user; do not claim identity unless obvious from context.
4. 📝 READABLE TEXT: Signs, screens, labels—read short text verbatim.
5. 🌤️ SCENE COHERENCE: Briefly anchor where they are (indoor/outdoor, type of space) when the scene shifts.

TONE:
- Speak as if painting what would be in their central and peripheral awareness if vision were sharp—not as a lab report.
- Keep delta updates SHORT (1–4 sentences). First scan after memory reset may be slightly richer (up to 5 sentences).

VERBOSITY HANDLING:
- If "Verbosity: Minimal" — dangers + motion only.
- If "Verbosity: Standard" — safety + people + layout changes.
- If "Verbosity: Immersive" — include color, lighting mood, textures, and atmosphere when they change.

LIMITS (state only if relevant): You infer from a single camera; depth and fine detail are approximate—not a medical or legal substitute for vision."""
        elif mode == "navigate":
            base_prompt += """MODE: NAVIGATE
Focus entirely on spatial awareness and safety.
1. Describe obstacles, drop-offs, and hazards immediately.
2. Give clear spatial directions (e.g., '2 meters ahead', 'on your left').
3. Ignore superficial details; focus on clear paths and dangers.
4. Keep responses under 2 sentences."""
        elif mode == "reader":
            base_prompt += """MODE: READER
Focus entirely on reading and analyzing text.
1. Read any text detected via OCR accurately.
2. Format text clearly. If it's a sign, document, or label, summarize its main point if it's long, or read it verbatim if requested.
3. Ignore non-text objects unless they provide context to the text."""
        elif mode == "identify":
            base_prompt += """MODE: IDENTIFY
Focus on detailed descriptions of the surroundings.
1. Describe objects, colors, lighting, and layout in vivid detail.
2. If known faces are detected, mention them and their positions.
3. Paint a comprehensive picture of the current scene."""
        elif mode == "emergency":
            base_prompt += """MODE: EMERGENCY
YOU ARE IN STRICT EMERGENCY MODE. IGNORE ALL PLEASANTRIES.
1. ONLY report immediate physical dangers, moving vehicles, drop-offs, or threats.
2. Respond in 2 sentences or less with extreme urgency.
3. If you detect a person nearby, instruct the user to call out for help.
4. Describe escape routes and safe directions to move.
5. Prioritize: moving vehicles > fire/smoke > water/edges > aggressive animals > uneven ground."""
        elif mode == "navigation_active":
            base_prompt += """MODE: NAVIGATION ASSISTANT — ACTIVE WALKING GUIDANCE
You are guiding a visually impaired person who is walking to a destination RIGHT NOW.
CRITICAL RULES:
1. YOUR TOP PRIORITY is keeping the user SAFE — warn about ANY obstacle, curb, step, crack, puddle, bump, slope, or uneven surface within 3 meters.
2. Describe the GROUND SURFACE: is it pavement, grass, gravel, tiles, wet? Mention changes.
3. For EVERY response, start with safety, then give navigation. Example: "Clear path ahead. Continue straight for about 20 meters, then turn right."
4. Use CLOCK DIRECTIONS: "obstacle at 2 o'clock", "turn at 10 o'clock".
5. Mention overhead hazards: low branches, awnings, signs, construction.
6. Report crosswalks, traffic signals, and vehicle sounds.
7. At intersections: describe traffic flow, crossing options, and whether it appears safe.
8. Call out steps, ramps, and elevation changes BEFORE the user reaches them.
9. Keep responses SHORT — 2-3 sentences max. The user is WALKING and needs quick info.
10. If the camera shows the user is off-route, firmly redirect them.
11. NEVER say "I can see" — say "There is" or "Ahead of you" instead.
Navigation context data will be injected below with step-by-step route information."""
        else: # "assistant" (default)
            base_prompt += """MODE: ASSISTANT
Your core behaviors:
1. SAFETY FIRST: Always prioritize warning about hazards, obstacles, and safety concerns.
2. BE CONCISE: Keep responses short and actionable. Users listen to your responses.
3. BE SPECIFIC: Use spatial terms like "directly ahead", "to your left".
4. NATURAL CONVERSATION: Respond warmly and naturally.
5. CONTEXT AWARE: Use previous conversation and vision context giving relevant answers."""

        if self.last_vision_context:
            context_str = self._format_vision_context(self.last_vision_context)
            base_prompt += f"\n\nCurrent scene context:\n{context_str}"

        return base_prompt

    def _format_vision_context(self, ctx: dict) -> str:
        """Format vision context into readable text."""
        parts = []
        if ctx.get("objects"):
            obj_descriptions = []
            for obj in ctx["objects"]:
                desc = f"{obj.get('label', 'unknown')} (confidence: {obj.get('confidence', 0):.0%}, position: {obj.get('position', 'unknown')})"
                obj_descriptions.append(desc)
            parts.append("Detected objects: " + ", ".join(obj_descriptions))

        if ctx.get("text"):
            parts.append(f"OCR text found: \"{ctx['text']}\"")

        if ctx.get("environment"):
            parts.append(f"Environment: {ctx['environment']}")
        if ctx.get("scene_memory"):
            parts.append(f"Previous scene description: \"{ctx['scene_memory']}\"")
        if ctx.get("navigation"):
            nav = ctx["navigation"]
            nav_parts = []
            if nav.get("status"):
                nav_parts.append(f"status {nav['status']}")
            if nav.get("current_step") and nav.get("total_steps"):
                nav_parts.append(f"step {nav['current_step']} of {nav['total_steps']}")
            if nav.get("instruction"):
                nav_parts.append(f"instruction: {nav['instruction']}")
            if nav.get("distance_remaining"):
                nav_parts.append(f"distance remaining: {nav['distance_remaining']}")
            if nav.get("direction_to_waypoint"):
                nav_parts.append(f"direction: {nav['direction_to_waypoint']}")
            if nav_parts:
                parts.append("Navigation: " + "; ".join(nav_parts))

        return "; ".join(parts) if parts else "No visual information available"

    def _trim(self):
        """Keep only the most recent messages."""
        if len(self.messages) > self.max_history:
            self.messages = self.messages[-self.max_history:]

    def clear(self):
        """Clear all conversation history."""
        self.messages.clear()
        self.last_vision_context = None


# Session storage — in-memory for MVP
_sessions: dict[str, ConversationManager] = {}


def get_session(session_id: str) -> ConversationManager:
    """Get or create a conversation session."""
    if session_id not in _sessions:
        _sessions[session_id] = ConversationManager()
    return _sessions[session_id]


def clear_session(session_id: str):
    """Clear a specific session."""
    if session_id in _sessions:
        del _sessions[session_id]
