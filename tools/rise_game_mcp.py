"""Local stdio MCP for the Rise test installation. Run with the MCP 1.x SDK."""
import os
import sys
import time
from pathlib import Path
from typing import Any, Literal

from mcp.server.fastmcp import FastMCP

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rise_game_qa import GAME
from watch_arm279 import command

game = Path(os.environ.get("MHRS_GAME_DIR", GAME))
channel = game / "reframework/data/MHRS-Game-Test"
server = FastMCP("mhrs-game-test")


def request(action: str, **args):
    if not channel.is_dir():
        raise RuntimeError(f"Install and start the REFramework test bridge in {game}")
    return command(channel, action, expires=int(time.time()) + 8, **args)


@server.tool()
def scene_state() -> dict[str, Any]:
    """Read live game/quest/village state, CG flags, local hunter and five rendered armor slots."""
    state = request("state")
    state["parts"] = state.get("parts") or []
    return state


@server.tool()
def worn_equipment(templates: list[str] | None = None) -> dict[str, Any]:
    """Inspect the current local hunter's renderers, MDFs and running CHAINs. Optionally match logical MMTR paths."""
    paths = [path.lower().replace("\\", "/") for path in templates or ()]
    if len(paths) > 64 or any(not path.endswith(".mmtr") or len(path) > 512 for path in paths):
        raise ValueError("Use at most 64 logical .mmtr paths")
    hotreload = channel.with_name("MHRS-Files-HotReload")
    # The roster and the optional material scan run on separate game frames.
    # Pin the returned rows to the same current owner and five registered slots.
    before = scene_state()
    if not before.get("hunter_present"):
        return {"scene": before, "hunter": None, "links": []}
    roster = command(hotreload, "asset_hunter_roster")
    owner = next((h for h in roster.get("hunters") or [] if h["role"] == "master"
                  and h["root"] == before["hunter"]), None)
    if not owner:
        raise RuntimeError("Hunter changed during the equipment sample")
    parts = owner.get("parts") or []
    materials = {part["material"].lower() for part in parts}
    links = command(hotreload, "asset_material_links", paths=paths).get("links") if paths else []
    after = scene_state()
    registered = {p["slot"]: p["object"] for p in after.get("parts") or []}
    if (after.get("hunter"), after.get("scope")) != (before["hunter"], before.get("scope")) or any(
            registered.get(p["slot"]) != p["go"] for p in parts):
        raise RuntimeError("Scene or worn equipment changed during the sample")
    return {"scene": after, "hunter": owner,
            "links": [link for link in links or [] if link["owner"].lower() in materials]}


@server.tool()
def transition_trace(action: Literal["start", "read", "stop"]) -> dict[str, Any]:
    """Record state changes across a scene transition. Read/stop returns up to 256 changes."""
    return request("trace", mode=action)


@server.tool()
def village_travel(destination: int, hunter: str, scope: str) -> dict[str, Any]:
    """Start normal solo village fast travel using the hunter and scope from scene_state. Village street is 0, training area is 5."""
    if not 0 <= destination <= 5:
        raise ValueError("Village area must be in the range 0–5")
    return request("travel", destination=destination, hunter=hunter, scope=scope)


@server.tool()
def quest_action(action: Literal["depart", "return"], quest: int, hunter: str, scope: str) -> dict[str, Any]:
    """Depart on an accepted solo quest or return from the current solo hunt. Use fresh scene_state IDs."""
    return request(action, quest=quest, hunter=hunter, scope=scope)


if __name__ == "__main__":
    server.run(transport="stdio")
