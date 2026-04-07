#!/usr/bin/env python3
"""
VaultSync Bridge Daemon
Serves the Decky plugin HTTP API at localhost:5437 as a headless systemd user service.
Reads configuration from the Flutter app's SharedPreferences JSON — no GUI required.
"""

import asyncio
import base64
import hashlib
import json
import logging
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests
from aiohttp import web
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import hashes, padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BRIDGE_PORT = 5437
PREFS_PATH = Path.home() / ".local/share/com.vaultsync.app/shared_preferences.json"

MAGIC = b"NEOSYNC"
IV_SIZE = 16
SMALL_BLOCK_SIZE = 256 * 1024
LARGE_BLOCK_SIZE = 1024 * 1024
BLOCK_THRESHOLD = 10 * 1024 * 1024

DEVICE_NAME = "Steam Deck"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [VaultSync Bridge] %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("bridge")

# ---------------------------------------------------------------------------
# SharedPreferences reader
# ---------------------------------------------------------------------------

def read_prefs() -> Dict:
    try:
        with open(PREFS_PATH) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except Exception as e:
        log.warning(f"Could not read prefs: {e}")
        return {}


def get_pref(prefs: Dict, key: str, default=None):
    """Flutter shared_preferences on Linux prefixes keys with 'flutter.'"""
    return prefs.get(f"flutter.{key}", prefs.get(key, default))


def get_systems(prefs: Dict) -> Dict[str, str]:
    """Returns {system_id: local_path} from shared prefs."""
    result = {}
    for k, v in prefs.items():
        # keys are stored as 'flutter.system_path_<id>'
        bare = k[len("flutter."):] if k.startswith("flutter.") else k
        if bare.startswith("system_path_"):
            sid = bare[len("system_path_"):]
            path = v if isinstance(v, str) else None
            if path:
                result[sid] = path
    return result

# ---------------------------------------------------------------------------
# Crypto (must match Flutter app / vaultsync_client.py)
# ---------------------------------------------------------------------------

def _block_size(file_size: int) -> int:
    return LARGE_BLOCK_SIZE if file_size >= BLOCK_THRESHOLD else SMALL_BLOCK_SIZE


def _enc_block_size(file_size: int) -> int:
    return _block_size(file_size) + len(MAGIC) + IV_SIZE + 16  # 16 = PKCS7 overhead


def encrypt_block(data: bytes, key: bytes) -> bytes:
    iv = hashlib.md5(data).digest()
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
    enc = cipher.encryptor()
    padder = padding.PKCS7(128).padder()
    padded = padder.update(data) + padder.finalize()
    return MAGIC + iv + enc.update(padded) + enc.finalize()


def decrypt_block(data: bytes, key: bytes) -> bytes:
    if not data.startswith(MAGIC):
        return data
    iv = data[len(MAGIC): len(MAGIC) + IV_SIZE]
    ct = data[len(MAGIC) + IV_SIZE:]
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
    dec = cipher.decryptor()
    try:
        raw = dec.update(ct) + dec.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        return unpadder.update(raw) + unpadder.finalize()
    except Exception:
        return data

# ---------------------------------------------------------------------------
# Path resolver  (mirrors sync_path_resolver.dart)
# ---------------------------------------------------------------------------

def get_cloud_rel_path(system_id: str, local_rel: str) -> str:
    sid = system_id.lower()
    parts = local_rel.replace("\\", "/").split("/")

    if sid in ("switch", "eden"):
        title_idx = next(
            (i for i, p in enumerate(parts) if re.match(r"^0100[0-9A-Fa-f]{12}$", p)), -1
        )
        if title_idx == -1:
            return ""
        profile_re = re.compile(r"^[0-9A-Fa-f]{32}$")
        if not any(profile_re.match(parts[i]) for i in range(title_idx)):
            return ""
        return "/".join(parts[title_idx:])

    if sid in ("ps2", "aethersx2", "nethersx2", "pcsx2", "duckstation"):
        anchors = {"memcards", "memcard", "sstates", "gamesettings"}
        for i in range(len(parts) - 1, -1, -1):
            if parts[i].lower() in anchors:
                return "/".join(parts[i:])
        return local_rel  # no anchor — root-level file, sync as-is

    if sid == "wii":
        for i in range(len(parts) - 1, -1, -1):
            if parts[i].lower() == "title" and i < len(parts) - 1:
                return "/".join(parts[i + 1:])
        return ""

    if sid == "gc":
        for i, p in enumerate(parts):
            if p.lower() == "gc":
                return "/".join(parts[i:])
        return "GC/" + local_rel  # EmuDeck: root already at GC/ level

    if sid == "dolphin":
        if "/wii/title/" in local_rel.lower():
            for i, p in enumerate(parts):
                if p.lower() == "title" and i < len(parts) - 1:
                    return "/".join(parts[i + 1:])
        for i, p in enumerate(parts):
            if p.lower() == "gc":
                return "/".join(parts[i:])
        return local_rel

    if sid in ("3ds", "citra", "azahar"):
        try:
            ti = parts.index("00040000")
            if ti < len(parts) - 1:
                return "saves/" + "/".join(parts[ti + 1:])
        except ValueError:
            pass
        return "saves/" + local_rel

    if sid in ("psp", "ppsspp"):
        anchors = {"savedata", "ppsspp_state"}
        for i, p in enumerate(parts):
            if p.lower() in anchors:
                return "/".join(parts[i:])

    return local_rel


def cloud_prefix_for(system_id: str, local_path: str) -> str:
    if system_id.lower() == "eden":
        return "switch"
    if "retroarch" in local_path.lower():
        return "RetroArch"
    return system_id

# ---------------------------------------------------------------------------
# Sync client  (synchronous — runs in executor)
# ---------------------------------------------------------------------------

class SyncClient:
    def __init__(self):
        self.session = requests.Session()
        self._base_url: Optional[str] = None
        self._token: Optional[str] = None
        self._refresh_token: Optional[str] = None
        self._master_key: Optional[bytes] = None

    def reload(self):
        prefs = read_prefs()
        self._base_url = (get_pref(prefs, "api_base_url") or "").rstrip("/") or None
        self._token = get_pref(prefs, "fallback_auth_token")
        self._refresh_token = get_pref(prefs, "fallback_refresh_token")
        mk_b64 = get_pref(prefs, "fallback_master_key")
        if mk_b64:
            try:
                # base64url, pad to multiple of 4
                padded = mk_b64 + "=" * (-len(mk_b64) % 4)
                self._master_key = base64.urlsafe_b64decode(padded)
            except Exception:
                self._master_key = None
        if self._token:
            self.session.headers.update({"Authorization": f"Bearer {self._token}"})

    def _refresh(self) -> bool:
        if not self._refresh_token or not self._base_url:
            return False
        try:
            res = self.session.post(
                f"{self._base_url}/refresh",
                json={"refresh_token": self._refresh_token},
                headers={"Content-Type": "application/json"},
                timeout=10,
            )
            if res.status_code == 200:
                data = res.json()
                self._token = data["token"]
                if "refresh_token" in data:
                    self._refresh_token = data["refresh_token"]
                self.session.headers.update({"Authorization": f"Bearer {self._token}"})
                return True
            return False
        except Exception as e:
            log.error(f"Token refresh failed: {e}")
            return False

    def _get(self, endpoint: str, **kwargs):
        res = self.session.get(f"{self._base_url}{endpoint}", **kwargs)
        if res.status_code == 401 and self._refresh():
            res = self.session.get(f"{self._base_url}{endpoint}", **kwargs)
        return res

    def _post(self, endpoint: str, **kwargs):
        res = self.session.post(f"{self._base_url}{endpoint}", **kwargs)
        if res.status_code == 401 and self._refresh():
            res = self.session.post(f"{self._base_url}{endpoint}", **kwargs)
        return res

    def get_remote_files(self, prefix: str) -> List[Dict]:
        if not self._base_url:
            return []
        all_files = []
        cursor = None
        while True:
            params: Dict[str, Any] = {"prefix": prefix, "limit": 1000}
            if cursor:
                params["after"] = cursor
            try:
                res = self._get("/api/v1/files", params=params, timeout=15)
                if res.status_code != 200:
                    break
                data = res.json()
                all_files.extend(data.get("files", []))
                cursor = data.get("next_cursor")
                if not cursor:
                    break
            except Exception as e:
                log.error(f"get_remote_files error: {e}")
                break
        return all_files

    def get_conflicts(self) -> List[Dict]:
        if not self._base_url:
            return []
        try:
            res = self._get("/api/v1/conflicts", timeout=10)
            if res.status_code == 200:
                return res.json().get("conflicts", [])
        except Exception as e:
            log.error(f"get_conflicts error: {e}")
        return []

    def upload_file(self, local_path: str, remote_path: str, progress_cb=None):
        key = self._master_key
        if not key:
            raise RuntimeError("Master key not available")
        file_size = os.path.getsize(local_path)
        updated_at = int(os.path.getmtime(local_path) * 1000)
        bsize = _block_size(file_size)
        enc_bsize = _enc_block_size(file_size)

        sha = hashlib.sha256()
        block_hashes = []
        if file_size > 0:
            with open(local_path, "rb") as f:
                while True:
                    chunk = f.read(bsize)
                    if not chunk:
                        break
                    sha.update(chunk)
                    block_hashes.append(hashlib.sha256(chunk).hexdigest())

        dirty_indices = None
        if block_hashes:
            try:
                res = self._post(
                    "/api/v1/blocks/check",
                    json={"path": remote_path, "blocks": block_hashes},
                    timeout=15,
                )
                if res.status_code == 200:
                    missing = res.json().get("missing")
                    if missing is not None and len(missing) == 0:
                        return  # already up to date
                    dirty_indices = missing
            except Exception:
                pass

        if file_size > 0:
            with open(local_path, "rb") as f:
                idx = 0
                while True:
                    chunk = f.read(bsize)
                    if not chunk:
                        break
                    if dirty_indices is None or idx in dirty_indices:
                        enc = encrypt_block(chunk, key)
                        headers = {
                            "x-vaultsync-path": remote_path,
                            "x-vaultsync-index": str(idx),
                            "x-vaultsync-offset": str(idx * enc_bsize),
                            "Content-Type": "application/octet-stream",
                        }
                        self._post("/api/v1/upload", data=enc, headers=headers, timeout=60).raise_for_status()
                    idx += 1

        empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        self._post("/api/v1/upload/finalize", json={
            "path": remote_path,
            "hash": sha.hexdigest() if file_size > 0 else empty,
            "size": file_size,
            "updated_at": updated_at,
            "device_name": DEVICE_NAME,
        }, timeout=15).raise_for_status()

    def download_file(self, remote_path: str, local_path: str, file_size: int):
        key = self._master_key
        if not key:
            raise RuntimeError("Master key not available")
        os.makedirs(os.path.dirname(local_path) or ".", exist_ok=True)
        if file_size == 0:
            open(local_path, "wb").close()
            return

        enc_bsize = _enc_block_size(file_size)
        res = self._post(
            "/api/v1/download",
            json={"filename": remote_path},
            stream=True,
            timeout=120,
        )
        res.raise_for_status()

        tmp = local_path + ".vstmp"
        try:
            with open(tmp, "wb") as f:
                buf = b""
                for chunk in res.iter_content(chunk_size=min(file_size + 1024, 1024 * 1024)):
                    buf += chunk
                    while len(buf) >= enc_bsize:
                        block, buf = buf[:enc_bsize], buf[enc_bsize:]
                        f.write(decrypt_block(block, key))
                if buf:
                    f.write(decrypt_block(buf, key))
                f.flush()
                os.fsync(f.fileno())
            if os.path.exists(local_path):
                os.remove(local_path)
            os.rename(tmp, local_path)
        except Exception:
            if os.path.exists(tmp):
                os.remove(tmp)
            raise

    def sync_system(self, system_id: str, local_path: str, progress_cb=None) -> str:
        def prog(msg):
            if progress_cb:
                progress_cb(msg)
            log.info(f"[{system_id}] {msg}")

        if not os.path.isdir(local_path):
            return f"Path not found: {local_path}"

        prefix = cloud_prefix_for(system_id, local_path)
        prog(f"Fetching remote files...")

        try:
            remote_files = {f["path"]: f for f in self.get_remote_files(prefix)}
        except Exception as e:
            return f"Failed to fetch remote files: {e}"

        # Build local file map
        local_files: Dict[str, Dict] = {}
        for root, _, files in os.walk(local_path):
            for fname in files:
                if fname.endswith(".vstmp"):
                    continue
                abs_path = os.path.join(root, fname)
                rel = os.path.relpath(abs_path, local_path).replace("\\", "/")
                cloud_rel = get_cloud_rel_path(system_id, rel)
                if not cloud_rel:
                    continue
                local_files[f"{prefix}/{cloud_rel}"] = {
                    "abs_path": abs_path,
                    "size": os.path.getsize(abs_path),
                    "mtime": int(os.path.getmtime(abs_path) * 1000),
                }

        errors = []

        # Upload new / changed local files
        for rkey, lf in local_files.items():
            rf = remote_files.get(rkey)
            if rf is None or lf["size"] != rf["size"] or abs(lf["mtime"] - rf["updated_at"]) > 2000:
                prog(f"Uploading {rkey.split('/')[-1]}...")
                try:
                    self.upload_file(lf["abs_path"], rkey)
                except Exception as e:
                    errors.append(f"Upload {rkey}: {e}")
                    log.error(errors[-1])

        # Download missing / changed remote files
        for rkey, rf in remote_files.items():
            if not rkey.startswith(prefix + "/"):
                continue
            if rkey in local_files:
                continue
            cloud_rel = rkey[len(prefix) + 1:]
            dest = os.path.join(local_path, cloud_rel)
            prog(f"Downloading {rkey.split('/')[-1]}...")
            try:
                self.download_file(rkey, dest, rf["size"])
                os.utime(dest, (rf["updated_at"] / 1000,) * 2)
            except Exception as e:
                errors.append(f"Download {rkey}: {e}")
                log.error(errors[-1])

        return "Sync complete" if not errors else f"Sync finished with {len(errors)} error(s)"

# ---------------------------------------------------------------------------
# Bridge daemon
# ---------------------------------------------------------------------------

class BridgeDaemon:
    def __init__(self):
        self._client = SyncClient()
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="sync")
        self._sync_task: Optional[asyncio.Task] = None
        self._is_syncing = False
        self._last_progress = "Idle"
        self._last_sync_time: Optional[float] = None

    # ---- HTTP handlers ----

    async def _handle_status(self, request: web.Request) -> web.Response:
        return web.json_response({
            "is_syncing": self._is_syncing,
            "is_online": self._client._base_url is not None,
            "last_progress": self._last_progress,
            "last_sync_time": self._last_sync_time,
            "timestamp": time.time(),
        })

    async def _handle_systems(self, request: web.Request) -> web.Response:
        prefs = read_prefs()
        systems = list(get_systems(prefs).keys())
        return web.json_response({"systems": systems})

    async def _handle_conflicts(self, request: web.Request) -> web.Response:
        loop = asyncio.get_running_loop()
        try:
            self._client.reload()
            conflicts = await loop.run_in_executor(self._executor, self._client.get_conflicts)
            return web.json_response({"conflicts": conflicts})
        except Exception as e:
            return web.json_response({"error": str(e)}, status=500)

    async def _handle_sync(self, request: web.Request) -> web.Response:
        system_id: Optional[str] = request.match_info.get("system_id")
        if self._is_syncing:
            return web.json_response({"error": "Sync already in progress"}, status=400)
        self._sync_task = asyncio.create_task(self._run_sync(system_id=system_id))
        return web.json_response({"message": f"Sync triggered{' for ' + system_id if system_id else ''}"})

    # ---- Sync runner ----

    async def _run_sync(self, system_id: Optional[str] = None):
        self._is_syncing = True
        self._last_progress = "Starting sync..."
        loop = asyncio.get_running_loop()
        try:
            self._client.reload()
            if not self._client._base_url:
                self._last_progress = "Server URL not configured — open VaultSync app first"
                return
            if not self._client._master_key:
                self._last_progress = "Master key missing — open VaultSync app and log in first"
                return

            prefs = read_prefs()
            systems = get_systems(prefs)

            targets = (
                {system_id: systems[system_id]}
                if system_id and system_id in systems
                else systems
            )

            for sid, path in targets.items():
                def do_sync(sid=sid, path=path):
                    return self._client.sync_system(
                        sid, path,
                        progress_cb=lambda m: setattr(self, "_last_progress", m),
                    )
                result = await loop.run_in_executor(self._executor, do_sync)
                log.info(f"[{sid}] {result}")

            self._last_sync_time = time.time()
            self._last_progress = "Sync complete"
        except Exception as e:
            self._last_progress = f"Error: {e}"
            log.error(f"Sync failed: {e}")
        finally:
            self._is_syncing = False

    # ---- Application ----

    def build_app(self) -> web.Application:
        app = web.Application()
        app.router.add_get("/status", self._handle_status)
        app.router.add_get("/systems", self._handle_systems)
        app.router.add_get("/conflicts", self._handle_conflicts)
        app.router.add_post("/sync", self._handle_sync)
        app.router.add_post("/sync/{system_id}", self._handle_sync)
        return app

    async def run(self):
        self._client.reload()
        app = self.build_app()
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", BRIDGE_PORT)
        await site.start()
        log.info(f"VaultSync bridge running on 127.0.0.1:{BRIDGE_PORT}")
        if not self._client._base_url:
            log.warning("Server URL not yet configured — open the VaultSync app to configure")
        try:
            await asyncio.Event().wait()  # run forever
        finally:
            await runner.cleanup()
            self._executor.shutdown(wait=False)


if __name__ == "__main__":
    asyncio.run(BridgeDaemon().run())
