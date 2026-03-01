#!/usr/bin/env python3
"""
RL Map Designer — BakkesMod RCON + SteamCMD Workshop helpers.
"""

import json
import pathlib
import re
import subprocess
import sys

SCRIPTS_DIR = pathlib.Path(__file__).parent.resolve()
SETTINGS_FILE = SCRIPTS_DIR / "settings.json"
WORKSHOP_CONTENT_DIR = SCRIPTS_DIR / "workshop_content"
WORKSHOP_VDF = SCRIPTS_DIR / "workshop_upload.vdf"


def load_settings():
    if SETTINGS_FILE.exists():
        try:
            return json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {}


def save_settings(s):
    SETTINGS_FILE.write_text(json.dumps(s, indent=2), encoding="utf-8")


# ─────────────────────────────────────────────────────────────────────────────
#  BakkesMod RCON
# ─────────────────────────────────────────────────────────────────────────────

def bakkesmod_send(command, timeout=4):
    """
    Send a console command to BakkesMod via WebSocket RCON.
    Returns (ok: bool, error: str|None).
    """
    try:
        import websocket
    except ImportError:
        return False, "websocket-client not installed. Run: pip install websocket-client"

    try:
        ws = websocket.create_connection("ws://127.0.0.1:9002", timeout=timeout)
        ws.send(command)
        ws.close()
        return True, None
    except ConnectionRefusedError:
        return False, "BakkesMod RCON refused — is Rocket League running with BakkesMod?"
    except Exception as e:
        return False, str(e)


def load_map_via_rcon(map_name="Labs_Underpass_P"):
    """Trigger a map load in RL through BakkesMod."""
    return bakkesmod_send("load_map " + map_name)


# ─────────────────────────────────────────────────────────────────────────────
#  SteamCMD Workshop upload
# ─────────────────────────────────────────────────────────────────────────────

def publish_workshop(arena_json, settings):
    """
    Upload or update a Steam Workshop item for Rocket League.
    Returns { ok, publishedfileid, error }.
    """
    steamcmd_path = settings.get("steamcmd_path")
    steam_user    = settings.get("steam_user", "").strip()
    last_udk_path = settings.get("last_built_udk_path")

    if not steamcmd_path or not pathlib.Path(steamcmd_path).exists():
        return {"ok": False, "error": "SteamCMD not found. Configure path in scripts/setup.py"}
    if not steam_user:
        return {"ok": False, "error": "Steam username is empty. Run scripts/setup.py to configure it."}
    if not last_udk_path or not pathlib.Path(last_udk_path).exists():
        return {"ok": False, "error": "No exported .udk found. Run 'Export to RL' first."}

    meta = arena_json.get("meta", {})
    title       = meta.get("title", "Custom RL Map")
    description = meta.get("description", "Made with RL Map Designer")
    preview     = meta.get("previewPath", "")

    # Prepare workshop content directory
    WORKSHOP_CONTENT_DIR.mkdir(parents=True, exist_ok=True)
    import shutil
    shutil.copy2(last_udk_path, WORKSHOP_CONTENT_DIR / pathlib.Path(last_udk_path).name)

    published_id = settings.get("publishedfileid", "0")

    def vdf_str(s):
        """Escape for VDF: replace quotes only."""
        return str(s).replace('"', '\\"')

    # Build VDF via concatenation (not .format) to avoid brace interpretation
    content_path = str(WORKSHOP_CONTENT_DIR).replace("\\", "/")
    preview_path = preview.replace("\\", "/") if preview else ""

    vdf_lines = [
        '"workshopitem"',
        '{',
        '    "appid"           "252950"',
        '    "publishedfileid" "' + vdf_str(published_id) + '"',
        '    "contentfolder"   "' + vdf_str(content_path) + '"',
        '    "previewfile"     "' + vdf_str(preview_path) + '"',
        '    "visibility"      "0"',
        '    "title"           "' + vdf_str(title) + '"',
        '    "description"     "' + vdf_str(description) + '"',
        '    "changenote"      "Exported from RL Map Designer"',
        '}',
    ]
    WORKSHOP_VDF.write_text("\n".join(vdf_lines), encoding="utf-8")

    cmd = [
        steamcmd_path,
        "+login", steam_user,
        "+workshop_build_item", str(WORKSHOP_VDF),
        "+quit"
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "SteamCMD timed out (>3 min)"}
    except Exception as e:
        return {"ok": False, "error": "SteamCMD failed: " + str(e)}

    stdout = result.stdout + result.stderr

    m = re.search(r"publishedfileid\s*=\s*(\d+)", stdout, re.IGNORECASE)
    if not m:
        m = re.search(r"Published file id (\d+)", stdout, re.IGNORECASE)

    if "Success" in stdout or (m and m.group(1) != "0"):
        new_id = m.group(1) if m else published_id
        return {"ok": True, "publishedfileid": new_id}
    else:
        excerpt = stdout[-600:] if len(stdout) > 600 else stdout
        return {"ok": False, "error": "SteamCMD did not report success:\n" + excerpt}


# ─────────────────────────────────────────────────────────────────────────────
#  Standalone test
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: patcher.py rcon <command>")
        print("       patcher.py status")
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "rcon" and len(sys.argv) >= 3:
        ok, err = bakkesmod_send(sys.argv[2])
        print("OK" if ok else "FAIL: " + err)
    elif cmd == "status":
        s = load_settings()
        print("Settings:", json.dumps(s, indent=2))
    else:
        print("Unknown command:", cmd)
