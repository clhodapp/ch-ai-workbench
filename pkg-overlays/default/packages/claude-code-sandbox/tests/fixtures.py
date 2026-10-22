# SPDX-License-Identifier: MIT
"""A registry on disk, in the shape the home-manager module emits: a base
part, one part per sandbox module, and the always-on module names."""

import json
from pathlib import Path

BASE = {
    "closure": ["/nix/store/bbb-base"],
    "pathFirst": ["/nix/store/ssh-wrapper/bin"],
    "pathLast": ["/nix/store/base-farm/bin", "/nix/store/bwrap/bin"],
    "shell": "/nix/store/bash/bin/bash",
    "socketShell": "/nix/store/ccs-socket-shell",
}

WORK = {
    "description": "the work tools",
    "masked": True,
    "closure": ["/nix/store/aaa-hello"],
    "path": ["/nix/store/work-farm/bin"],
}

# What composing just WORK yields, before the CLI adds the checkout root.
WORK_FRAGMENT = {
    "sandbox": {
        "enabled": True,
        "failIfUnavailable": True,
        "allowUnsandboxedCommands": False,
        "filesystem": {
            "denyRead": ["/nix/store"],
            "allowRead": ["/nix/store/aaa-hello", "/nix/store/bbb-base"],
        },
    },
    "env": {
        "PATH": "/nix/store/ssh-wrapper/bin:/nix/store/work-farm/bin"
        ":/nix/store/base-farm/bin:/nix/store/bwrap/bin",
        "SHELL": "/nix/store/bash/bin/bash",
    },
}


def write_registry(config: Path, modules: dict, base_modules=(), base=BASE, credentials=None):
    """Write each part and the registry under ``config``; returns the
    part paths by module name, for tests that change a part later."""
    parts = config / "parts"
    parts.mkdir(parents=True, exist_ok=True)
    base_path = parts / "base.json"
    base_path.write_text(json.dumps(base))
    paths = {}
    for name, part in modules.items():
        paths[name] = parts / f"module-{name}.json"
        paths[name].write_text(json.dumps(part))
    registry = {
        "base": str(base_path),
        "modules": {name: str(path) for name, path in paths.items()},
        "baseModules": list(base_modules),
    }
    if credentials is not None:
        registry["credentials"] = credentials
    (config / "registry.json").write_text(json.dumps(registry))
    paths["base"] = base_path
    return paths
