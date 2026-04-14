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
        """Return conversation history formatted for Gemini API."""
        history = []
        for msg in self.messages:
            entry = {"role": msg.role, "parts": [{"text": msg.content}]}
            if msg.vision_context:
                context_text = self._format_vision_context(msg.vision_context)
                entry["parts"].insert(0, {"text": f"[Vision Context: {context_text}]"})
            history.append(entry)
        return history

    def get_system_prompt(self) -> str:
        """Build the assistive system prompt."""
        base_prompt = """You are EchoSight, an AI-powered assistive vision companion designed to help visually impaired users navigate and understand their surroundings. 

Your core behaviors:
1. SAFETY FIRST: Always prioritize warning about hazards, obstacles, and safety concerns.
2. BE CONCISE: Keep responses short and actionable. Users listen to your responses, so brevity matters.
3. BE SPECIFIC: Use spatial terms like "directly ahead", "to your left", "about 2 meters away".
4. BE PROACTIVE: If you detect danger in the vision context, warn immediately even if not asked.
5. NATURAL CONVERSATION: Respond warmly and naturally, like a helpful companion.
6. CONTEXT AWARE: Use previous conversation and vision context to give relevant answers.

When vision context is provided:
- Describe what's relevant to the user's question
- Mention obstacles and their positions
- Read any text detected via OCR when asked
- Estimate distances when possible
- Describe the environment (indoor/outdoor, lighting, etc.)

When no vision context is available:
- Answer general knowledge questions helpfully
- Let the user know if a question requires visual information

Always respond as if speaking to the user — use conversational, friendly language."""

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
