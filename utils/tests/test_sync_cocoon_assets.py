"""Tests for sync_cocoon_assets.py — TDD suite covering all merge logic."""
import json
import pytest
from pathlib import Path
from vaultsync_app.utils.sync_cocoon_assets import (
    extract_extensions,
    merge_system_metadata,
    merge_emulators,
    infer_folders,
    extract_libretro_core,
    build_new_system,
    discover_platforms,
    sync_icons,
    run_sync,
)


# ---------------------------------------------------------------------------
# Phase 2 – System metadata merge
# ---------------------------------------------------------------------------

class TestExtractExtensions:
    def test_extracts_pipe_separated_exts(self):
        regex = r"^(.*)\\.(?:7z|zip)$"
        assert extract_extensions(regex) == ["7z", "zip"]

    def test_single_extension(self):
        regex = r"^(.*)\\.(?:iso)$"
        assert extract_extensions(regex) == ["iso"]

    def test_many_extensions(self):
        regex = r"^(.*)\\.(?:bin|n64|ndd|u1|v64|z64)$"
        assert extract_extensions(regex) == ["bin", "n64", "ndd", "u1", "v64", "z64"]

    def test_returns_empty_for_no_match(self):
        assert extract_extensions(".*") == []

    def test_deduplicates(self):
        """Multiple players may share the same extension; merged list must be unique."""
        regex = r"^(.*)\\.(?:zip|7z|zip)$"
        assert extract_extensions(regex) == ["zip", "7z"]


class TestMergeSystemMetadata:
    """Verify name + extensions are updated while folders are preserved."""

    def _vs(self, **overrides):
        base = {
            "system": {
                "id": "cps2",
                "name": "Old Name",
                "folders": ["cps2", "cps"],        # custom – must be preserved
                "extensions": ["zip"],
                "ignored_folders": [],
            },
            "emulators": [],
        }
        base["system"].update(overrides)
        return base

    def _cocoon_platform(self, name="CP System II", players=None):
        return {
            "platform": {"name": name, "uniqueId": "cps2", "shortname": "cps2"},
            "playerList": players or [],
        }

    def test_updates_name(self):
        vs = self._vs()
        cocoon = self._cocoon_platform(name="CP System II")
        result = merge_system_metadata(vs, cocoon)
        assert result["system"]["name"] == "CP System II"

    def test_preserves_folders(self):
        vs = self._vs()
        cocoon = self._cocoon_platform()
        result = merge_system_metadata(vs, cocoon)
        assert result["system"]["folders"] == ["cps2", "cps"]

    def test_updates_extensions_from_all_players(self):
        players = [
            {"uniqueId": "cps2.ra64.fbneo", "acceptedFilenameRegex": r"^(.*)\\.(?:7z|zip)$", "name": "RA64 fbneo", "amStartArguments": ""},
            {"uniqueId": "cps2.ra32.fba",   "acceptedFilenameRegex": r"^(.*)\\.(?:iso|zip)$", "name": "RA32 fba", "amStartArguments": ""},
        ]
        vs = self._vs()
        cocoon = self._cocoon_platform(players=players)
        result = merge_system_metadata(vs, cocoon)
        exts = result["system"]["extensions"]
        assert "7z" in exts
        assert "zip" in exts
        assert "iso" in exts
        assert len(exts) == len(set(exts)), "No duplicates"

    def test_does_not_clear_existing_extensions_when_no_players(self):
        """If CocoonFE has no players we keep the existing extensions intact."""
        vs = self._vs(extensions=["zip", "iso"])
        cocoon = self._cocoon_platform(players=[])
        result = merge_system_metadata(vs, cocoon)
        assert set(result["system"]["extensions"]) == {"zip", "iso"}

    def test_preserves_ignored_folders(self):
        vs = self._vs()
        vs["system"]["ignored_folders"] = ["bios", "cheats"]
        cocoon = self._cocoon_platform()
        result = merge_system_metadata(vs, cocoon)
        assert result["system"]["ignored_folders"] == ["bios", "cheats"]


# ---------------------------------------------------------------------------
# Phase 2 – Emulators merge
# ---------------------------------------------------------------------------

class TestMergeEmulators:
    def _player(self, uid, name, args=""):
        return {"uniqueId": uid, "name": name, "amStartArguments": args, "acceptedFilenameRegex": ""}

    def test_adds_new_emulator(self):
        existing = []
        players = [self._player("cps2.ra64.fbneo", "RetroArch (64 bits) - fbneo")]
        result = merge_emulators(existing, players)
        assert len(result) == 1
        assert result[0]["unique_id"] == "cps2.ra64.fbneo"

    def test_new_emulator_default_false(self):
        existing = []
        players = [self._player("cps2.ra64.fbneo", "RetroArch (64 bits) - fbneo")]
        result = merge_emulators(existing, players)
        assert result[0]["default"] is False

    def test_updates_name_of_existing_emulator(self):
        existing = [{"unique_id": "cps2.ra64.fbneo", "name": "Old Name", "default": True}]
        players = [self._player("cps2.ra64.fbneo", "New Name from CocoonFE")]
        result = merge_emulators(existing, players)
        assert result[0]["name"] == "New Name from CocoonFE"

    def test_preserves_default_flag_for_existing(self):
        existing = [{"unique_id": "cps2.ra64.fbneo", "name": "RA fbneo", "default": True}]
        players = [self._player("cps2.ra64.fbneo", "RA fbneo updated")]
        result = merge_emulators(existing, players)
        assert result[0]["default"] is True

    def test_no_duplicates_on_second_run(self):
        """Idempotency: running merge twice produces the same list."""
        existing = [{"unique_id": "cps2.ra64.fbneo", "name": "RA fbneo", "default": True}]
        players = [self._player("cps2.ra64.fbneo", "RA fbneo")]
        first  = merge_emulators(existing, players)
        second = merge_emulators(first, players)
        assert len(second) == 1

    def test_mixed_new_and_existing(self):
        existing = [{"unique_id": "cps2.ra64.fbneo", "name": "RA fbneo", "default": True}]
        players = [
            self._player("cps2.ra64.fbneo", "RA fbneo"),
            self._player("cps2.ra32.fbneo", "RA32 fbneo"),
        ]
        result = merge_emulators(existing, players)
        assert len(result) == 2
        uid_map = {e["unique_id"]: e for e in result}
        assert uid_map["cps2.ra64.fbneo"]["default"] is True
        assert uid_map["cps2.ra32.fbneo"]["default"] is False


# ---------------------------------------------------------------------------
# Phase 3 – New system generation
# ---------------------------------------------------------------------------

class TestInferFolders:
    def test_shortname_always_first(self):
        folders = infer_folders("n64", "Nintendo 64")
        assert folders[0] == "n64"

    def test_includes_name_words(self):
        folders = infer_folders("n64", "Nintendo 64")
        assert "Nintendo 64" in folders or any("Nintendo" in f for f in folders)

    def test_deduplicates(self):
        folders = infer_folders("gb", "Game Boy")
        assert len(folders) == len(set(f.lower() for f in folders))

    def test_no_empty_entries(self):
        folders = infer_folders("gb", "Game Boy")
        assert all(f.strip() for f in folders)


class TestBuildNewSystem:
    def _cocoon(self, uid="testid", name="Test System", players=None):
        return {
            "platform": {"uniqueId": uid, "shortname": uid, "name": name},
            "playerList": players or [],
        }

    def test_creates_correct_id(self):
        result = build_new_system(self._cocoon())
        assert result["system"]["id"] == "testid"

    def test_creates_name(self):
        result = build_new_system(self._cocoon(name="Test System"))
        assert result["system"]["name"] == "Test System"

    def test_generates_folders(self):
        result = build_new_system(self._cocoon(uid="n64", name="Nintendo 64"))
        assert isinstance(result["system"]["folders"], list)
        assert len(result["system"]["folders"]) > 0

    def test_creates_empty_ignored_folders(self):
        result = build_new_system(self._cocoon())
        assert result["system"]["ignored_folders"] == []

    def test_extensions_from_players(self):
        players = [
            {"uniqueId": "x.ra.foo", "name": "RA", "amStartArguments": "",
             "acceptedFilenameRegex": r"^(.*)\\.(?:bin|iso)$"},
        ]
        result = build_new_system(self._cocoon(players=players))
        assert "bin" in result["system"]["extensions"]
        assert "iso" in result["system"]["extensions"]

    def test_emulators_populated(self):
        players = [
            {"uniqueId": "x.ra.foo", "name": "RA", "amStartArguments": "",
             "acceptedFilenameRegex": ""},
        ]
        result = build_new_system(self._cocoon(players=players))
        assert len(result["emulators"]) == 1


# ---------------------------------------------------------------------------
# Phase 3 – RetroArch LIBRETRO core extraction
# ---------------------------------------------------------------------------

class TestExtractLibretroCore:
    def test_extracts_core_path(self):
        args = (
            "-n com.retroarch.aarch64/com.retroarch.browser.retroactivity.RetroActivityFuture\n"
            "  -e ROM {file.path}\n"
            "  -e LIBRETRO /data/data/com.retroarch.aarch64/cores/fbneo_libretro_android.so\n"
            "  -e CONFIGFILE /storage/emulated/0/..."
        )
        assert extract_libretro_core(args) == "/data/data/com.retroarch.aarch64/cores/fbneo_libretro_android.so"

    def test_returns_none_for_standalone(self):
        args = "-n com.explusalpha.neoemu/com.imagine.BaseActivity\n  -d {file.path}\n"
        assert extract_libretro_core(args) is None

    def test_returns_none_for_empty(self):
        assert extract_libretro_core("") is None

    def test_handles_inline_format(self):
        args = "-e LIBRETRO /data/data/com.retroarch/cores/snes9x_libretro_android.so -e CONFIGFILE ..."
        assert extract_libretro_core(args) == "/data/data/com.retroarch/cores/snes9x_libretro_android.so"


# ---------------------------------------------------------------------------
# Phase 1 – Platform discovery
# ---------------------------------------------------------------------------

class TestDiscoverPlatforms:
    def test_returns_list(self, tmp_path):
        """discover_platforms should return a list even for an empty directory."""
        result = discover_platforms(str(tmp_path), str(tmp_path))
        assert isinstance(result, list)

    def test_matches_by_unique_id(self, tmp_path):
        import json
        cocoon_dir = tmp_path / "cocoon"
        vs_dir = tmp_path / "vs"
        cocoon_dir.mkdir(); vs_dir.mkdir()

        cocoon_file = cocoon_dir / "CPS2.json"
        cocoon_file.write_text(json.dumps({
            "platform": {"name": "CP System II", "uniqueId": "cps2", "shortname": "cps2"},
            "playerList": [],
        }))

        vs_file = vs_dir / "cps2.json"
        vs_file.write_text(json.dumps({
            "system": {"id": "cps2", "name": "CPS2", "folders": ["cps2"],
                       "extensions": [], "ignored_folders": []},
            "emulators": [],
        }))

        result = discover_platforms(str(cocoon_dir), str(vs_dir))
        assert len(result) == 1
        assert result[0]["cocoon"]["platform"]["uniqueId"] == "cps2"
        assert result[0]["vs_path"] == str(vs_file)
        assert result[0]["vs_data"] is not None

    def test_unmatched_cocoon_platform_has_no_vs_path(self, tmp_path):
        cocoon_dir = tmp_path / "cocoon"
        vs_dir = tmp_path / "vs"
        cocoon_dir.mkdir(); vs_dir.mkdir()

        (cocoon_dir / "Unknown.json").write_text(json.dumps({
            "platform": {"name": "Unknown System", "uniqueId": "unknown99", "shortname": "unknown99"},
            "playerList": [],
        }))

        result = discover_platforms(str(cocoon_dir), str(vs_dir))
        assert len(result) == 1
        assert result[0]["vs_path"] is None
        assert result[0]["vs_data"] is None


# ---------------------------------------------------------------------------
# Phase 4 – Icon sync
# ---------------------------------------------------------------------------

class TestSyncIcons:
    def test_copies_svg(self, tmp_path):
        src = tmp_path / "cocoon"
        dst = tmp_path / "vs"
        src.mkdir(); dst.mkdir()
        (src / "gb.svg").write_bytes(b"<svg/>")

        copied = sync_icons(str(src), str(dst), dry_run=False)
        assert len(copied) == 1
        assert (dst / "gb.svg").exists()

    def test_dry_run_does_not_copy(self, tmp_path):
        src = tmp_path / "cocoon"
        dst = tmp_path / "vs"
        src.mkdir(); dst.mkdir()
        (src / "gb.svg").write_bytes(b"<svg/>")

        copied = sync_icons(str(src), str(dst), dry_run=True)
        assert len(copied) == 1
        assert not (dst / "gb.svg").exists()

    def test_skips_existing_icons(self, tmp_path):
        src = tmp_path / "cocoon"
        dst = tmp_path / "vs"
        src.mkdir(); dst.mkdir()
        (src / "gb.svg").write_bytes(b"<svg/>")
        (dst / "gb.svg").write_bytes(b"<svg existing/>")

        copied = sync_icons(str(src), str(dst), dry_run=False)
        assert len(copied) == 0
        assert (dst / "gb.svg").read_bytes() == b"<svg existing/>"

    def test_copies_png(self, tmp_path):
        src = tmp_path / "cocoon"
        dst = tmp_path / "vs"
        src.mkdir(); dst.mkdir()
        (src / "snes.png").write_bytes(b"\x89PNG")

        copied = sync_icons(str(src), str(dst), dry_run=False)
        assert len(copied) == 1


# ---------------------------------------------------------------------------
# Phase 4 – run_sync integration
# ---------------------------------------------------------------------------

class TestRunSync:
    def _make_dirs(self, tmp_path):
        cocoon_dir = tmp_path / "cocoon"
        vs_dir = tmp_path / "vs"
        cocoon_dir.mkdir(); vs_dir.mkdir()
        return cocoon_dir, vs_dir

    def _write_cocoon(self, cocoon_dir: Path, uid: str, name: str, players=None):
        (cocoon_dir / f"{uid}.json").write_text(json.dumps({
            "platform": {"name": name, "uniqueId": uid, "shortname": uid},
            "playerList": players or [],
        }))

    def _write_vs(self, vs_dir: Path, uid: str, name: str = "Old Name"):
        (vs_dir / f"{uid}.json").write_text(json.dumps({
            "system": {"id": uid, "name": name, "folders": [uid],
                       "extensions": [], "ignored_folders": []},
            "emulators": [],
        }))

    def test_updates_existing_system(self, tmp_path):
        cocoon_dir, vs_dir = self._make_dirs(tmp_path)
        self._write_cocoon(cocoon_dir, "cps2", "CP System II")
        self._write_vs(vs_dir, "cps2", "Old CPS2 Name")

        run_sync(str(cocoon_dir), str(vs_dir), dry_run=False)

        result = json.loads((vs_dir / "cps2.json").read_text())
        assert result["system"]["name"] == "CP System II"

    def test_dry_run_does_not_write(self, tmp_path):
        cocoon_dir, vs_dir = self._make_dirs(tmp_path)
        self._write_cocoon(cocoon_dir, "cps2", "CP System II")
        self._write_vs(vs_dir, "cps2", "Old CPS2 Name")

        run_sync(str(cocoon_dir), str(vs_dir), dry_run=True)

        result = json.loads((vs_dir / "cps2.json").read_text())
        assert result["system"]["name"] == "Old CPS2 Name"

    def test_creates_new_system_file(self, tmp_path):
        cocoon_dir, vs_dir = self._make_dirs(tmp_path)
        self._write_cocoon(cocoon_dir, "newplatform", "New Platform")

        run_sync(str(cocoon_dir), str(vs_dir), dry_run=False)

        new_file = vs_dir / "newplatform.json"
        assert new_file.exists()
        result = json.loads(new_file.read_text())
        assert result["system"]["id"] == "newplatform"

    def test_idempotent(self, tmp_path):
        cocoon_dir, vs_dir = self._make_dirs(tmp_path)
        self._write_cocoon(cocoon_dir, "cps2", "CP System II")
        self._write_vs(vs_dir, "cps2", "CP System II")  # already up to date

        run_sync(str(cocoon_dir), str(vs_dir), dry_run=False)
        first = (vs_dir / "cps2.json").read_text()

        run_sync(str(cocoon_dir), str(vs_dir), dry_run=False)
        second = (vs_dir / "cps2.json").read_text()

        assert first == second
