"""Validate the isolated loader's JSON before publishing it as a job output."""
import json
import re
import sys

GEM = r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}"
VERSION = r"[0-9]+(?:\.[0-9A-Za-z]+)*"
REQUIREMENT = rf"(?:~>|>=|<=|!=|=|>|<) {VERSION}"
MAX_BYTES = 65536


def unique_keys(pairs):
    obj = dict(pairs)
    if len(obj) != len(pairs):
        raise ValueError("Duplicate key")
    return obj


def requirements(values):
    return (isinstance(values, list) and bool(values)
            and all(isinstance(value, str) and re.fullmatch(REQUIREMENT, value) for value in values))


def metadata(stream):
    raw = stream.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("Oversized metadata")
    data = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_keys)
    if not isinstance(data, dict) or data.keys() != {"name", "platform", "version", "ruby", "dependencies"}:
        raise ValueError("Unexpected metadata fields")
    if data["name"] != "nitro_intelligence" or data["platform"] != "ruby":
        raise ValueError("Unexpected gem name or platform")
    version, ruby, dependencies = data["version"], data["ruby"], data["dependencies"]
    if not isinstance(version, str) or not re.fullmatch(VERSION, version) or not requirements(ruby):
        raise ValueError("Invalid version or Ruby requirements")
    if not isinstance(dependencies, dict) or len(dependencies) > 128:
        raise ValueError("Invalid runtime dependencies")
    for name, constraints in dependencies.items():
        if not re.fullmatch(GEM, name) or not requirements(constraints):
            raise ValueError("Invalid runtime dependency")
    return {"version": version, "ruby": ruby, "dependencies": dependencies}


if __name__ == "__main__":
    try:
        data = metadata(sys.stdin.buffer)
    except (ValueError, RecursionError):
        sys.exit(2)
    print(json.dumps(data, separators=(",", ":")))
