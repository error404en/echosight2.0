"""
EchoSight Backend — Navigation Engine
Fetches walking routes and provides turn-by-turn guidance
optimized for visually impaired users.
Uses Google Directions API for route data and Gemini for
contextual guidance that accounts for real-time camera + sensor input.
"""

import os
import math
import json
import aiohttp
from typing import Optional
from dataclasses import dataclass, field, asdict


@dataclass
class NavigationStep:
    """A single step in the walking route."""
    instruction: str          # e.g. "Turn left onto Main Street"
    distance_meters: float
    distance_text: str        # e.g. "120 m"
    duration_text: str        # e.g. "2 min"
    start_lat: float
    start_lng: float
    end_lat: float
    end_lng: float
    maneuver: str = ""        # e.g. "turn-left", "turn-right", "straight"


@dataclass
class NavigationRoute:
    """Full walking route from origin to destination."""
    origin: str
    destination: str
    total_distance: str
    total_duration: str
    steps: list[NavigationStep] = field(default_factory=list)
    current_step_index: int = 0

    @property
    def current_step(self) -> Optional[NavigationStep]:
        if 0 <= self.current_step_index < len(self.steps):
            return self.steps[self.current_step_index]
        return None

    @property
    def is_complete(self) -> bool:
        return self.current_step_index >= len(self.steps)

    def advance_step(self):
        if not self.is_complete:
            self.current_step_index += 1

    def to_dict(self) -> dict:
        return {
            "origin": self.origin,
            "destination": self.destination,
            "total_distance": self.total_distance,
            "total_duration": self.total_duration,
            "current_step_index": self.current_step_index,
            "total_steps": len(self.steps),
            "current_step": asdict(self.current_step) if self.current_step else None,
            "is_complete": self.is_complete,
        }


# ─── Route storage per session ────────────────────────────────
_active_routes: dict[str, NavigationRoute] = {}


def get_active_route(session_id: str) -> Optional[NavigationRoute]:
    return _active_routes.get(session_id)


def clear_route(session_id: str):
    _active_routes.pop(session_id, None)


# ─── Haversine distance ─────────────────────────────────────────

def _haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Calculate distance in meters between two GPS coordinates."""
    R = 6371000  # Earth radius in meters
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _bearing(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Calculate compass bearing from point 1 to point 2 (degrees)."""
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    x = math.sin(dl) * math.cos(phi2)
    y = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(dl)
    return (math.degrees(math.atan2(x, y)) + 360) % 360


def _bearing_to_direction(bearing: float) -> str:
    """Convert a compass bearing to a human-friendly direction."""
    dirs = ["ahead", "slightly right", "right", "sharp right",
            "behind you", "sharp left", "left", "slightly left"]
    idx = round(bearing / 45) % 8
    return dirs[idx]


# ─── Fetch route from Google Directions ───────────────────────

async def fetch_walking_route(
    origin_lat: float,
    origin_lng: float,
    destination: str,
    session_id: str,
) -> Optional[NavigationRoute]:
    """
    Fetch a walking route from Google Directions API.
    Falls back to Gemini-based estimation if no API key is available.
    """
    api_key = os.getenv("GOOGLE_MAPS_API_KEY", "")

    if api_key:
        route = await _fetch_google_route(origin_lat, origin_lng, destination, api_key)
    else:
        # Without Maps API, create a simplified direct route
        route = _create_fallback_route(origin_lat, origin_lng, destination)

    if route:
        _active_routes[session_id] = route
    return route


async def _fetch_google_route(
    origin_lat: float,
    origin_lng: float,
    destination: str,
    api_key: str,
) -> Optional[NavigationRoute]:
    """Fetch route from Google Directions API."""
    url = "https://maps.googleapis.com/maps/api/directions/json"
    params = {
        "origin": f"{origin_lat},{origin_lng}",
        "destination": destination,
        "mode": "walking",
        "key": api_key,
    }

    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(url, params=params) as resp:
                data = await resp.json()

        if data.get("status") != "OK" or not data.get("routes"):
            print(f"[NAV] Google Directions returned: {data.get('status')}")
            return None

        route_data = data["routes"][0]
        leg = route_data["legs"][0]

        steps = []
        for step in leg["steps"]:
            # Strip HTML tags from instructions
            import re
            instruction = re.sub(r'<[^>]+>', '', step.get("html_instructions", ""))

            steps.append(NavigationStep(
                instruction=instruction,
                distance_meters=step["distance"]["value"],
                distance_text=step["distance"]["text"],
                duration_text=step["duration"]["text"],
                start_lat=step["start_location"]["lat"],
                start_lng=step["start_location"]["lng"],
                end_lat=step["end_location"]["lat"],
                end_lng=step["end_location"]["lng"],
                maneuver=step.get("maneuver", "straight"),
            ))

        return NavigationRoute(
            origin=leg.get("start_address", f"{origin_lat},{origin_lng}"),
            destination=leg.get("end_address", destination),
            total_distance=leg["distance"]["text"],
            total_duration=leg["duration"]["text"],
            steps=steps,
        )

    except Exception as e:
        print(f"[ERR] Google Directions API failed: {e}")
        return None


def _create_fallback_route(
    origin_lat: float,
    origin_lng: float,
    destination: str,
) -> NavigationRoute:
    """Create a minimal fallback route when no Maps API key is available."""
    return NavigationRoute(
        origin=f"{origin_lat:.5f}, {origin_lng:.5f}",
        destination=destination,
        total_distance="Unknown",
        total_duration="Unknown",
        steps=[
            NavigationStep(
                instruction=f"Navigate towards {destination}. "
                            "Ask me to look around for guidance.",
                distance_meters=0,
                distance_text="Unknown",
                duration_text="Unknown",
                start_lat=origin_lat,
                start_lng=origin_lng,
                end_lat=origin_lat,
                end_lng=origin_lng,
                maneuver="straight",
            )
        ],
    )


# ─── Real-time navigation context builder ─────────────────────

def build_navigation_context(
    route: NavigationRoute,
    current_lat: float,
    current_lng: float,
    heading: float = 0.0,
) -> dict:
    """
    Build a rich navigation context dictionary for the LLM.
    Includes distance to next waypoint, bearing, and step-by-step info.
    """
    step = route.current_step
    if step is None:
        return {
            "status": "arrived",
            "message": "You have arrived at your destination!",
        }

    # Distance from current position to the END of the current step
    dist_to_end = _haversine(current_lat, current_lng, step.end_lat, step.end_lng)

    # If within 15 meters, auto-advance to next step
    if dist_to_end < 15 and route.current_step_index < len(route.steps) - 1:
        route.advance_step()
        step = route.current_step
        if step is None:
            return {"status": "arrived", "message": "You have arrived!"}
        dist_to_end = _haversine(current_lat, current_lng, step.end_lat, step.end_lng)

    # Bearing from current position to next waypoint
    target_bearing = _bearing(current_lat, current_lng, step.end_lat, step.end_lng)
    relative_bearing = (target_bearing - heading + 360) % 360
    direction = _bearing_to_direction(relative_bearing)

    # Look-ahead: what's the next maneuver after this step?
    next_step = None
    if route.current_step_index + 1 < len(route.steps):
        next_step = route.steps[route.current_step_index + 1]

    return {
        "status": "navigating",
        "current_step": route.current_step_index + 1,
        "total_steps": len(route.steps),
        "instruction": step.instruction,
        "maneuver": step.maneuver,
        "distance_remaining": f"{dist_to_end:.0f}m",
        "direction_to_waypoint": direction,
        "relative_bearing": f"{relative_bearing:.0f}°",
        "next_instruction": next_step.instruction if next_step else "You will arrive at your destination.",
        "destination": route.destination,
        "total_distance": route.total_distance,
        "total_duration": route.total_duration,
    }
