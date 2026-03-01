#!/usr/bin/env python3
"""
RL Map Designer — First-time setup script.

Detects RL / UDK / BakkesMod / SteamCMD paths, copies UnrealScript
commandlet to UDK src, compiles it (one-time ~3 min), backs up the
Labs_Underpass_P.upk, and writes scripts/settings.json.

Run once: python3 scripts/setup.py
"""

import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys

SCRIPTS_DIR  = pathlib.Path(__file__).parent.resolve()
PROJECT_ROOT = SCRIPTS_DIR.parent.resolve()
SETTINGS_FILE = SCRIPTS_DIR / "settings.json"
COMMANDLET_UC = SCRIPTS_DIR / "commandlet" / "RLMapDesigner.uc"

# ─────────────────────────────────────────────────────────────────────────────
#  Path detection
# ─────────────────────────────────────────────────────────────────────────────

RL_STEAM_PATHS = [
    r"C:\Program Files (x86)\Steam\steamapps\common\rocketleague",
    r"C:\Program Files\Steam\steamapps\common\rocketleague",
    r"D:\Steam\steamapps\common\rocketleague",
    r"D:\SteamLibrary\steamapps\common\rocketleague",
    r"E:\Steam\steamapps\common\rocketleague",
    r"E:\SteamLibrary\steamapps\common\rocketleague",
]
RL_EPIC_PATHS = [
    r"C:\Program Files\Epic Games\rocketleague",
    r"C:\Program Files (x86)\Epic Games\rocketleague",
]
UDK_PATHS = [
    r"C:\UDK\UDK-2013-07\Binaries\Win64\UDK.exe",
    r"C:\UDK\UDK-2013-07\Binaries\Win32\UDK.exe",
    r"C:\Program Files\UDK\UDK-2013-07\Binaries\Win64\UDK.exe",
]
BAKKESMOD_PATHS = [
    os.path.expandvars(r"%APPDATA%\bakkesmod\bakkesmod\bakkesmod.exe"),
    r"C:\Program Files\BakkesMod\bakkesmod.exe",
]
STEAMCMD_PATHS = [
    r"C:\steamcmd\steamcmd.exe",
    r"C:\Program Files (x86)\Steam\steamcmd.exe",
]


def first_existing(paths):
    for p in paths:
        if p and pathlib.Path(p).exists():
            return str(p)
    return None


def detect_rl():
    for p in RL_STEAM_PATHS + RL_EPIC_PATHS:
        pp = pathlib.Path(p)
        if pp.exists() and (pp / "Binaries").exists():
            return str(pp)
    return None


def detect_udk():
    # Search C:\ and D:\ drives for UDK.exe
    for p in UDK_PATHS:
        if pathlib.Path(p).exists():
            return p
    for drive in ["C:", "D:", "E:"]:
        for candidate in pathlib.Path(drive + "/").rglob("UDK.exe") if pathlib.Path(drive + "/").exists() else []:
            if "Binaries" in str(candidate):
                return str(candidate)
    return None


def prompt(msg, default=""):
    resp = input(msg + (" [" + default + "]" if default else "") + ": ").strip()
    return resp if resp else default


# ─────────────────────────────────────────────────────────────────────────────
#  UDK commandlet setup
# ─────────────────────────────────────────────────────────────────────────────

def install_commandlet(udk_exe):
    udk_root = pathlib.Path(udk_exe).parent.parent
    src_dest = udk_root / "Development" / "Src" / "RLMapDesigner" / "Classes"
    src_dest.mkdir(parents=True, exist_ok=True)

    dest_uc = src_dest / "RLMapDesigner.uc"
    shutil.copy2(COMMANDLET_UC, dest_uc)
    print(f"  Copied commandlet to: {dest_uc}")

    # Compile
    print("  Compiling UnrealScript (this takes ~3 minutes)...")
    try:
        result = subprocess.run(
            [udk_exe, "make", "-full"],
            capture_output=True, text=True, timeout=600
        )
        if result.returncode != 0:
            print("  WARNING: UDK make returned non-zero. Output:")
            print(result.stderr[:500])
        else:
            print("  Compilation successful.")
    except subprocess.TimeoutExpired:
        print("  WARNING: UDK make timed out (>10 min). Commandlet may not work.")
    except Exception as e:
        print("  ERROR running UDK make:", e)


def backup_underpass(rl_path):
    cooked = pathlib.Path(rl_path) / "TAGame" / "CookedPCConsole"
    upk = cooked / "Labs_Underpass_P.upk"
    bak = cooked / "Labs_Underpass_P.upk.bak"
    if upk.exists() and not bak.exists():
        shutil.copy2(upk, bak)
        print(f"  Backed up Labs_Underpass_P.upk → {bak}")
    elif bak.exists():
        print(f"  Backup already exists: {bak}")
    else:
        print(f"  WARNING: Labs_Underpass_P.upk not found at {upk}")


# ─────────────────────────────────────────────────────────────────────────────
#  Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    print("=" * 60)
    print("  RL Map Designer — First-time Setup")
    print("=" * 60)
    print()

    settings = {}
    if SETTINGS_FILE.exists():
        try:
            settings = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
            print("Found existing settings.json — values will be used as defaults.")
        except Exception:
            pass

    # ── Rocket League ──
    print("\n[1/4] Rocket League installation")
    auto_rl = detect_rl()
    if auto_rl:
        print(f"  Auto-detected: {auto_rl}")
    rl_path = prompt("  RL path (folder containing Binaries/)", settings.get("rl_path", auto_rl or ""))
    if rl_path and not pathlib.Path(rl_path).exists():
        print(f"  WARNING: Path does not exist: {rl_path}")
    settings["rl_path"] = rl_path

    # ── UDK ──
    print("\n[2/4] UDK (Unreal Development Kit 2013)")
    auto_udk = detect_udk()
    if auto_udk:
        print(f"  Auto-detected: {auto_udk}")
    else:
        print("  Not auto-detected. Download from: https://www.unrealengine.com/en-US/previous-versions")
        print("  Community setup script: search 'UDK_RL_Setup' on RL modding Discord")
    udk_exe = prompt("  UDK.exe path", settings.get("udk_exe", auto_udk or ""))
    settings["udk_exe"] = udk_exe

    compile_now = False
    if udk_exe and pathlib.Path(udk_exe).exists():
        print(f"  UDK found: {udk_exe}")
        ans = prompt("  Install and compile UnrealScript commandlet now? (one-time ~3min)", "yes")
        compile_now = ans.lower().startswith("y")
    else:
        print(f"  WARNING: UDK.exe not found at: {udk_exe}")

    # ── BakkesMod ──
    print("\n[3/4] BakkesMod (optional — for one-click RL map loading)")
    auto_bm = first_existing(BAKKESMOD_PATHS)
    if auto_bm:
        print(f"  Auto-detected: {auto_bm}")
    bm = prompt("  BakkesMod path (leave blank to skip)", settings.get("bakkesmod_path", auto_bm or ""))
    settings["bakkesmod_path"] = bm

    # ── SteamCMD ──
    print("\n[4/4] SteamCMD (optional — for Steam Workshop upload)")
    auto_sc = first_existing(STEAMCMD_PATHS)
    if auto_sc:
        print(f"  Auto-detected: {auto_sc}")
    else:
        print("  Download from: https://developer.valvesoftware.com/wiki/SteamCMD")
    sc = prompt("  SteamCMD path (leave blank to skip)", settings.get("steamcmd_path", auto_sc or ""))
    settings["steamcmd_path"] = sc

    steam_user = ""
    if sc:
        steam_user = prompt("  Steam username (for Workshop upload)", settings.get("steam_user", ""))
        settings["steam_user"] = steam_user

    # ── Save settings ──
    SETTINGS_FILE.write_text(json.dumps(settings, indent=2), encoding="utf-8")
    print(f"\nSaved settings to: {SETTINGS_FILE}")

    # ── RL backup ──
    if rl_path and pathlib.Path(rl_path).exists():
        print("\nBacking up Labs_Underpass_P.upk...")
        backup_underpass(rl_path)

    # ── Commandlet install ──
    if compile_now and udk_exe and pathlib.Path(udk_exe).exists():
        print("\nInstalling and compiling commandlet...")
        install_commandlet(udk_exe)

    # ── Check websocket ──
    try:
        import websocket  # noqa
    except ImportError:
        print("\nOptional: install websocket-client for BakkesMod RCON:")
        print("  pip install websocket-client")

    print("\n" + "=" * 60)
    print("Setup complete!")
    print()
    print("To start the export server:")
    print("  python3 scripts/server.py")
    print()
    print("To start the web app:")
    print("  python3 -m http.server 8080")
    print("  Open http://localhost:8080")
    print("=" * 60)


if __name__ == "__main__":
    main()
