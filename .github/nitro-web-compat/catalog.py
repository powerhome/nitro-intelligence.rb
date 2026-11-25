"""Mirror public compact-index records reachable from the public candidate alone."""

import concurrent.futures
import json
import pathlib
import re
import sys
import urllib.error
import urllib.request

from candidate import GEM


def fetch(directory, name):
    if not re.fullmatch(GEM, name):
        raise ValueError("Unsupported public gem name")
    try:
        with urllib.request.urlopen("https://rubygems.org/info/" + name, timeout=30) as response:
            contents = response.read(16 * 1024 * 1024 + 1)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        contents = b"---\n"
    if len(contents) > 16 * 1024 * 1024:
        raise ValueError("Oversized index record")
    (directory / name).write_bytes(contents)
    children = set()
    for line in contents.decode().split("---\n", 1)[-1].splitlines():
        _, _, rest = line.partition(" ")
        dependencies = rest.partition("|")[0]
        children.update(dep.partition(":")[0] for dep in dependencies.split(",") if dep)
    return children


def mirror(directory, names):
    directory.mkdir()
    seen = set()
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as workers:
        while names:
            seen.update(names)
            if len(seen) > 1500:
                raise ValueError("Public dependency graph exceeds the verifier limit")
            results = workers.map(lambda name: fetch(directory, name), names)
            names = set().union(*results) - seen


if __name__ == "__main__":
    mirror(pathlib.Path(sys.argv[1]), set(json.load(sys.stdin)["dependencies"]))
