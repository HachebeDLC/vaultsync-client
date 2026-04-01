"""
sync_cocoon_assets.py
─────────────────────
Developer script: merges CocoonFE platform definitions into VaultSync's
assets/systems/*.json files.

Usage
─────
    # Dry-run (shows what would change, writes nothing)
    python sync_cocoon_assets.py --dry-run

    # Live sync
    python sync_cocoon_assets.py

Arguments
─────────
  --dry-run          Print a diff-style report without modifying any files.
  --cocoon-dir DIR   Path to CocoonFE/platforms/ (default: auto-detected).
  --vs-dir DIR       Path to vaultsync_app/assets/systems/ (default: auto-detected).
  --verbose          Show detailed per-file logs.
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import shutil
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Public helpers (tested individually)
# ---------------------------------------------------------------------------

def extract_extensions(regex: str) -> list[str]:
    """Parse a CocoonFE acceptedFilenameRegex and return unique file extensions.

    Example:
        ``^(.*)\\.(?:7z|zip)$``  →  ``['7z', 'zip']``
    """
    match = re.search(r'\(\?:([^)]+)\)', regex)
    if not match:
        return []
    seen: set[str] = set()
    result: list[str] = []
    for ext in match.group(1).split('|'):
        if ext and ext not in seen:
            seen.add(ext)
            result.append(ext)
    return result


def extract_libretro_core(am_start_args: str) -> str | None:
    """Extract the LIBRETRO core path from an amStartArguments string.

    Returns the .so path string, or None if not a RetroArch player.
    """
    match = re.search(r'-e\s+LIBRETRO\s+(\S+)', am_start_args)
    return match.group(1) if match else None


def infer_folders(shortname: str, name: str) -> list[str]:
    """Generate ``system.folders`` for a new system that has no VaultSync entry.

    The shortname always comes first, followed by the full name, with duplicates
    and empty strings removed (case-insensitive dedup).
    """
    candidates = [shortname, name]
    seen: set[str] = set()
    folders: list[str] = []
    for c in candidates:
        c = c.strip()
        if c and c.lower() not in seen:
            seen.add(c.lower())
            folders.append(c)
    return folders


def merge_system_metadata(
    vs_data: dict[str, Any],
    cocoon_data: dict[str, Any],
) -> dict[str, Any]:
    """Update name and extensions in *vs_data* from *cocoon_data*, preserving folders.

    Mutates and returns the VaultSync dict.
    """
    platform = cocoon_data['platform']
    players = cocoon_data.get('playerList', [])

    vs_data['system']['name'] = platform['name']

    new_exts = _collect_extensions(players)
    if new_exts:
        # Merge: union of existing + CocoonFE, preserving order (existing first)
        merged: list[str] = list(vs_data['system'].get('extensions', []))
        existing_set = set(merged)
        for ext in new_exts:
            if ext not in existing_set:
                merged.append(ext)
                existing_set.add(ext)
        vs_data['system']['extensions'] = merged

    return vs_data


def merge_emulators(
    existing: list[dict[str, Any]],
    players: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Merge CocoonFE playerList entries into the VaultSync emulators list.

    Rules
    ─────
    - Match by ``unique_id`` (VaultSync) == ``uniqueId`` (CocoonFE).
    - For existing emulators: update ``name``, preserve ``default`` flag.
    - For new emulators: append with ``default = False``.
    - Idempotent: a second run with the same players produces the same list.
    """
    by_uid: dict[str, dict[str, Any]] = {e['unique_id']: e for e in existing}

    for player in players:
        uid = player['uniqueId']
        if uid in by_uid:
            by_uid[uid]['name'] = player['name']
            # default flag is intentionally kept as-is
        else:
            by_uid[uid] = {
                'name': player['name'],
                'unique_id': uid,
                'default': False,
            }

    # Preserve original ordering for existing entries, append new ones at end.
    seen: set[str] = set()
    result: list[dict[str, Any]] = []
    for e in existing:
        result.append(by_uid[e['unique_id']])
        seen.add(e['unique_id'])
    for player in players:
        uid = player['uniqueId']
        if uid not in seen:
            result.append(by_uid[uid])
            seen.add(uid)
    return result


def build_new_system(cocoon_data: dict[str, Any]) -> dict[str, Any]:
    """Create a brand-new VaultSync system dict from a CocoonFE platform definition."""
    platform = cocoon_data['platform']
    players = cocoon_data.get('playerList', [])
    shortname = platform.get('shortname') or platform['uniqueId']

    extensions = _collect_extensions(players)
    emulators = merge_emulators([], players)
    folders = infer_folders(shortname, platform['name'])

    return {
        'system': {
            'id': shortname,
            'name': platform['name'],
            'folders': folders,
            'extensions': extensions,
            'ignored_folders': [],
        },
        'emulators': emulators,
    }


def discover_platforms(
    cocoon_dir: str,
    vs_dir: str,
) -> list[dict[str, Any]]:
    """Enumerate CocoonFE platforms and match each to a VaultSync system file.

    Returns a list of dicts with keys:
        ``cocoon``    – parsed CocoonFE platform dict
        ``vs_path``   – absolute path to the matching VS JSON (or None)
        ``vs_data``   – parsed VS system dict (or None)
    """
    cocoon_path = Path(cocoon_dir)
    vs_path = Path(vs_dir)

    # Build a lookup: system_id → vs file path
    vs_map: dict[str, Path] = {}
    for f in vs_path.glob('*.json'):
        try:
            data = json.loads(f.read_text(encoding='utf-8'))
            sid = data.get('system', {}).get('id', f.stem)
            vs_map[sid.lower()] = f
        except Exception:
            pass

    results: list[dict[str, Any]] = []
    for cocoon_file in sorted(cocoon_path.glob('*.json')):
        try:
            cocoon_data = json.loads(cocoon_file.read_text(encoding='utf-8'))
        except Exception:
            log.warning("Skipping unreadable CocoonFE file: %s", cocoon_file)
            continue

        platform = cocoon_data.get('platform', {})
        uid = (platform.get('uniqueId') or '').lower()
        shortname = (platform.get('shortname') or '').lower()

        if not uid:
            log.debug("Skipping non-platform file: %s", cocoon_file)
            continue

        match_path: Path | None = vs_map.get(uid) or vs_map.get(shortname)
        match_data: dict | None = None
        if match_path:
            try:
                match_data = json.loads(match_path.read_text(encoding='utf-8'))
            except Exception:
                pass

        results.append({
            'cocoon': cocoon_data,
            'vs_path': str(match_path) if match_path else None,
            'vs_data': match_data,
        })

    return results


def sync_icons(cocoon_dir: str, vs_dir: str, dry_run: bool = False) -> list[str]:
    """Copy SVG/PNG icon files from CocoonFE into the VaultSync assets directory.

    Matches by filename stem vs. system.id.  Returns a list of copied paths.
    """
    cocoon_path = Path(cocoon_dir)
    vs_path = Path(vs_dir)
    copied: list[str] = []

    for icon in sorted(cocoon_path.rglob('*.svg')) + sorted(cocoon_path.rglob('*.png')):
        target = vs_path / icon.name
        if target.exists():
            continue
        log.info("ICON: %s → %s", icon, target)
        if not dry_run:
            shutil.copy2(icon, target)
        copied.append(str(target))
    return copied


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _collect_extensions(players: list[dict[str, Any]]) -> list[str]:
    """Union of all extensions from a list of CocoonFE players."""
    seen: set[str] = set()
    result: list[str] = []
    for p in players:
        for ext in extract_extensions(p.get('acceptedFilenameRegex', '')):
            if ext not in seen:
                seen.add(ext)
                result.append(ext)
    return result


# ---------------------------------------------------------------------------
# Main sync entry-point
# ---------------------------------------------------------------------------

def run_sync(
    cocoon_dir: str,
    vs_dir: str,
    dry_run: bool = False,
    verbose: bool = False,
) -> None:
    """Merge CocoonFE platform definitions into VaultSync system JSONs."""
    if verbose:
        logging.basicConfig(level=logging.DEBUG, format='%(levelname)s %(message)s')
    else:
        logging.basicConfig(level=logging.INFO, format='%(message)s')

    vs_path = Path(vs_dir)
    platforms = discover_platforms(cocoon_dir, vs_dir)

    updated = new_systems = 0

    for entry in platforms:
        cocoon_data = entry['cocoon']
        uid = cocoon_data['platform'].get('shortname') or cocoon_data['platform']['uniqueId']
        vs_data = entry['vs_data']
        target_path = Path(entry['vs_path']) if entry['vs_path'] else vs_path / f"{uid}.json"

        if vs_data is not None:
            before = json.dumps(vs_data, sort_keys=True)
            vs_data = merge_system_metadata(vs_data, cocoon_data)
            vs_data['emulators'] = merge_emulators(
                vs_data.get('emulators', []),
                cocoon_data.get('playerList', []),
            )
            after = json.dumps(vs_data, sort_keys=True)
            if before != after:
                log.info("UPDATE  %s", target_path.name)
                updated += 1
                if not dry_run:
                    target_path.write_text(
                        json.dumps(vs_data, indent=2, ensure_ascii=False) + '\n',
                        encoding='utf-8',
                    )
            else:
                log.debug("SKIP    %s (no changes)", target_path.name)
        else:
            vs_data = build_new_system(cocoon_data)
            log.info("NEW     %s", target_path.name)
            new_systems += 1
            if not dry_run:
                target_path.write_text(
                    json.dumps(vs_data, indent=2, ensure_ascii=False) + '\n',
                    encoding='utf-8',
                )

    icons = sync_icons(cocoon_dir, vs_dir, dry_run=dry_run)

    dry_label = "[DRY RUN] " if dry_run else ""
    log.info(
        "%sDone: %d updated, %d new systems, %d icons copied.",
        dry_label, updated, new_systems, len(icons),
    )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _default_paths() -> tuple[str, str]:
    """Resolve default CocoonFE and VaultSync asset dirs relative to this file."""
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent.parent
    cocoon = repo_root / 'CocoonFE' / 'platforms'
    vs = repo_root / 'vaultsync_app' / 'assets' / 'systems'
    return str(cocoon), str(vs)


def main() -> None:
    default_cocoon, default_vs = _default_paths()

    parser = argparse.ArgumentParser(
        description='Sync CocoonFE platform configs into VaultSync assets/systems.',
    )
    parser.add_argument('--dry-run', action='store_true',
                        help='Report changes without writing any files.')
    parser.add_argument('--cocoon-dir', default=default_cocoon,
                        metavar='DIR', help='Path to CocoonFE/platforms/')
    parser.add_argument('--vs-dir', default=default_vs,
                        metavar='DIR', help='Path to vaultsync_app/assets/systems/')
    parser.add_argument('--verbose', action='store_true')
    args = parser.parse_args()

    run_sync(
        cocoon_dir=args.cocoon_dir,
        vs_dir=args.vs_dir,
        dry_run=args.dry_run,
        verbose=args.verbose,
    )


if __name__ == '__main__':
    main()
