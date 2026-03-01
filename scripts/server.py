#!/usr/bin/env python3
"""
RL Map Designer — Export Pipeline Server
Listens on localhost:8081, handles:
  POST /export   → UDK build → copy to RL → BakkesMod RCON
  GET  /status   → detect UDK / RL / BakkesMod
  POST /publish  → SteamCMD Workshop upload
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

# Optional websocket for BakkesMod RCON
try:
    import websocket
    HAS_WEBSOCKET = True
except ImportError:
    HAS_WEBSOCKET = False

ROOT = pathlib.Path(__file__).parent.parent.resolve()
SCRIPTS_DIR = ROOT / "scripts"
SETTINGS_FILE = SCRIPTS_DIR / "settings.json"
ARENA_BUILD_JSON = SCRIPTS_DIR / "arena_build.json"


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
#  Pipeline steps
# ─────────────────────────────────────────────────────────────────────────────

def run_udk_commandlet(settings):
    udk_exe = settings.get("udk_exe")
    if not udk_exe or not pathlib.Path(udk_exe).exists():
        return False, "UDK not found. Run scripts/setup.py first."

    # Write arena_build.json path into commandlet INI
    ini_dir = pathlib.Path(udk_exe).parent.parent / "UDKGame" / "Config"
    ini_file = ini_dir / "UDKRLMapDesigner.ini"
    ini_dir.mkdir(parents=True, exist_ok=True)
    ini_file.write_text(
        "[RLMapDesigner]\nJsonPath=" + str(ARENA_BUILD_JSON).replace("\\", "/") + "\n",
        encoding="utf-8"
    )

    cmd = [udk_exe, "RLMapDesigner", "-run=RLMapDesignerCommandlet", "-noprompt", "-unattended"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            return False, "UDK commandlet failed:\n" + result.stderr[:500]
    except subprocess.TimeoutExpired:
        return False, "UDK commandlet timed out (>120s)"
    except Exception as e:
        return False, "Failed to run UDK: " + str(e)

    return True, None


def find_udk_output(settings):
    udk_exe = settings.get("udk_exe", "")
    udk_root = pathlib.Path(udk_exe).parent.parent if udk_exe else None
    if udk_root:
        candidate = udk_root / "UDKGame" / "Content" / "Maps" / "RLMapDesigner_Output.udk"
        if candidate.exists():
            return candidate
    # Fallback: scan common UDK paths
    for base in [r"C:\UDK", r"C:\Program Files\UDK"]:
        for p in pathlib.Path(base).rglob("RLMapDesigner_Output.udk"):
            return p
    return None


def copy_to_rl(settings):
    rl_path = settings.get("rl_path")
    if not rl_path:
        return False, "RL path not configured. Run scripts/setup.py first."

    udk_out = find_udk_output(settings)
    if udk_out is None:
        return False, "UDK output .udk not found. Did the commandlet succeed?"

    target_dir = pathlib.Path(rl_path) / "TAGame" / "CookedPCConsole"
    target_file = target_dir / "Labs_Underpass_P.upk"

    if not target_dir.exists():
        return False, "RL CookedPCConsole directory not found: " + str(target_dir)

    # Backup on first overwrite
    backup = target_dir / "Labs_Underpass_P.upk.bak"
    if target_file.exists() and not backup.exists():
        shutil.copy2(target_file, backup)

    shutil.copy2(udk_out, target_file)
    settings["last_built_udk_path"] = str(udk_out)
    save_settings(settings)
    return True, None


def bakkesmod_rcon(cmd_str):
    """Send a command to BakkesMod RCON via WebSocket."""
    if not HAS_WEBSOCKET:
        return False, "websocket-client not installed (pip install websocket-client)"
    try:
        ws = websocket.create_connection("ws://127.0.0.1:9002", timeout=4)
        ws.send(cmd_str)
        ws.close()
        return True, None
    except Exception as e:
        return False, "BakkesMod RCON error: " + str(e)


def full_export_pipeline(arena_json):
    settings = load_settings()

    # Write arena JSON for commandlet
    ARENA_BUILD_JSON.write_text(json.dumps(arena_json, indent=2), encoding="utf-8")

    # Step 1: UDK commandlet
    ok, err = run_udk_commandlet(settings)
    if not ok:
        return {"ok": False, "error": err, "step": "udk"}

    # Step 2: Copy to RL
    ok, err = copy_to_rl(settings)
    if not ok:
        return {"ok": False, "error": err, "step": "copy"}

    # Step 3: BakkesMod RCON — reload map
    rcon_ok, rcon_err = bakkesmod_rcon("load_freeplay")
    if not rcon_ok:
        # Non-fatal — map was copied, just needs manual reload
        return {
            "ok": True,
            "warning": "Map copied but BakkesMod RCON failed: " + rcon_err +
                       " — restart Rocket League or use Freeplay to load."
        }

    return {"ok": True}


# ─────────────────────────────────────────────────────────────────────────────
#  Status endpoint
# ─────────────────────────────────────────────────────────────────────────────

def get_status():
    settings = load_settings()
    udk_exe = settings.get("udk_exe", "")
    rl_path = settings.get("rl_path", "")
    bakkesmod_path = settings.get("bakkesmod_path", "")
    steamcmd_path = settings.get("steamcmd_path", "")
    return {
        "udk":        bool(udk_exe and pathlib.Path(udk_exe).exists()),
        "udk_path":   udk_exe,
        "rl_path":    rl_path,
        "rl_found":   bool(rl_path and pathlib.Path(rl_path).exists()),
        "bakkesmod":  bool(bakkesmod_path and pathlib.Path(bakkesmod_path).exists()),
        "steamcmd":   bool(steamcmd_path and pathlib.Path(steamcmd_path).exists()),
        "has_websocket": HAS_WEBSOCKET,
    }


# ─────────────────────────────────────────────────────────────────────────────
#  Workshop publish
# ─────────────────────────────────────────────────────────────────────────────

def publish_to_workshop(arena_json):
    from patcher import publish_workshop  # local import to keep server.py self-contained
    settings = load_settings()
    try:
        result = publish_workshop(arena_json, settings)
        if result.get("publishedfileid"):
            settings["publishedfileid"] = result["publishedfileid"]
            save_settings(settings)
        return result
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ─────────────────────────────────────────────────────────────────────────────
#  HTTP handler
# ─────────────────────────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[server]", fmt % args)

    def send_json(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def read_body_json(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        return json.loads(raw.decode("utf-8"))

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/status":
            self.send_json(get_status())
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        path = urlparse(self.path).path
        try:
            body = self.read_body_json()
        except Exception as e:
            self.send_json({"ok": False, "error": "Invalid JSON: " + str(e)}, 400)
            return

        if path == "/export":
            result = full_export_pipeline(body)
            self.send_json(result)
        elif path == "/publish":
            result = publish_to_workshop(body)
            self.send_json(result)
        else:
            self.send_json({"ok": False, "error": "Unknown endpoint"}, 404)


# ─────────────────────────────────────────────────────────────────────────────
#  Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    port = 8081
    server = HTTPServer(("127.0.0.1", port), Handler)
    print(f"RL Map Designer export server running on http://localhost:{port}")
    print("Endpoints: GET /status  POST /export  POST /publish")
    print("Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
