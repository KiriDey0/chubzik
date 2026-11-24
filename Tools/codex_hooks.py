#!/usr/bin/env python3
"""Add or remove the island observer alongside existing Codex hooks."""
import argparse
import json
import os
from pathlib import Path
import shlex
import tempfile

EVENTS = ("UserPromptSubmit", "PermissionRequest", "Stop", "SessionEnd")


def atomic_write(path, data):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="wb", dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("install", "remove"))
    parser.add_argument("app", type=Path)
    parser.add_argument("--config", type=Path, default=Path.home() / ".codex" / "hooks.json")
    args = parser.parse_args()
    config = args.config.expanduser().resolve()
    executable = args.app.expanduser().resolve() / "Contents" / "MacOS" / "Chubzik"
    if args.action == "install" and not os.access(executable, os.X_OK):
        parser.error("App executable was not found")
    command = shlex.join([str(executable), "--codex-hook"])

    raw = config.read_bytes() if config.exists() else None
    content = json.loads(raw) if raw is not None else {}
    hooks = content.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        parser.error("Expected an object under the hooks key")

    changes = 0
    for event in EVENTS:
        groups = hooks.get(event, [])
        if not isinstance(groups, list):
            parser.error(f"Expected an array for {event}")
        changed = [group for group in groups if group != {"hooks": [{"type": "command", "command": command, "timeout": 5}]}]
        if args.action == "install":
            changed.append({"hooks": [{"type": "command", "command": command, "timeout": 5}]})
        if changed == groups:
            continue
        changes += 1
        if changed:
            hooks[event] = changed
        else:
            hooks.pop(event, None)

    if changes:
        backup = config.parent / (config.name + ".before-chubzik")
        if raw is not None and not backup.exists():
            atomic_write(backup, raw)
        atomic_write(config, (json.dumps(content, ensure_ascii=False, indent=2) + "\n").encode())
    print(f"Changed Codex hook event groups: {changes}")


if __name__ == "__main__":
    main()
