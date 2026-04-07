import os
import aiohttp
import json
import decky

logger = decky.logger

class SettingsManager:
    def __init__(self, name, settings_directory):
        self.settings_file = os.path.join(settings_directory, f"{name}.json")
        self.settings = {
            "server_url": "http://localhost:5437",
            "auto_sync": True
        }
        self.read()

    def read(self):
        if os.path.exists(self.settings_file):
            try:
                with open(self.settings_file, "r") as f:
                    self.settings.update(json.load(f))
            except Exception as e:
                logger.error(f"Error loading settings: {e}")

    def save(self):
        try:
            os.makedirs(os.path.dirname(self.settings_file), exist_ok=True)
            with open(self.settings_file, "w") as f:
                json.dump(self.settings, f, indent=4)
        except Exception as e:
            logger.error(f"Error saving settings: {e}")

    def get(self, key, default=None):
        return self.settings.get(key, default)

    def set(self, key, value):
        self.settings[key] = value
        self.save()

class Plugin:
    async def get_status(self):
        try:
            url = self.settings.get("server_url", "http://localhost:5437")
            timeout = aiohttp.ClientTimeout(total=2)
            async with aiohttp.ClientSession() as session:
                async with session.get(f"{url}/status", timeout=timeout) as res:
                    if res.status == 200:
                        return await res.json()
                    return {"error": f"Bridge error: {res.status}"}
        except Exception as e:
            logger.error(f"Status error: {e}")
            return {"error": str(e), "bridge_not_found": True}

    async def get_systems(self):
        try:
            url = self.settings.get("server_url", "http://localhost:5437")
            timeout = aiohttp.ClientTimeout(total=2)
            async with aiohttp.ClientSession() as session:
                async with session.get(f"{url}/systems", timeout=timeout) as res:
                    if res.status == 200:
                        return await res.json()
                    return {"error": f"Bridge error: {res.status}"}
        except Exception as e:
            logger.error(f"Systems error: {e}")
            return {"error": str(e)}

    async def get_conflicts(self):
        try:
            url = self.settings.get("server_url", "http://localhost:5437")
            timeout = aiohttp.ClientTimeout(total=2)
            async with aiohttp.ClientSession() as session:
                async with session.get(f"{url}/conflicts", timeout=timeout) as res:
                    if res.status == 200:
                        return await res.json()
                    return {"error": f"Bridge error: {res.status}"}
        except Exception as e:
            logger.error(f"Conflicts error: {e}")
            return {"error": str(e)}

    async def trigger_sync(self, system_id=None):
        try:
            base_url = self.settings.get("server_url", "http://localhost:5437")
            url = f"{base_url}/sync"
            if system_id:
                url = f"{url}/{system_id}"
            timeout = aiohttp.ClientTimeout(total=5)
            async with aiohttp.ClientSession() as session:
                async with session.post(url, timeout=timeout) as res:
                    if res.status == 200:
                        return await res.json()
                    text = await res.text()
                    return {"error": f"Sync failed: {text}"}
        except Exception as e:
            logger.error(f"Trigger sync error: {e}")
            return {"error": str(e)}

    async def get_setting(self, key):
        return self.settings.get(key)

    async def set_setting(self, key, value):
        self.settings.set(key, value)
        return True

    async def _main(self):
        self.settings = SettingsManager(name="settings", settings_directory=decky.DECKY_PLUGIN_SETTINGS_DIR)
        logger.info("VaultSync Plugin Loaded")

    async def _unload(self):
        logger.info("VaultSync Plugin Unloaded")
