"""Read regular Git blobs, never a PR checkout. Reject unsupported Ruby syntax wholesale."""

import json
import re
import subprocess
import sys

VERSION = r"[0-9]+(?:\.[0-9A-Za-z]+)*"
REQUIREMENT = rf"(?:(?:~>|>=|<=|!=|=|>|<) *)?{VERSION}"
GEM = r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}"
# Literal metadata has no effect on resolution. Exclude interpolation and escapes.
STRING = r'"[^"\\#\x00-\x1f]*"'
ARRAY = rf"\[(?:{STRING}(?:, {STRING})*)?\]"


class Unsupported(ValueError):
    pass


def blob(repo, sha, path):
    def git(*args):
        return subprocess.check_output(["git", "-C", repo, *args])

    entry = git("ls-tree", "-l", sha, "--", path).split()
    if len(entry) != 5 or entry[0] not in (b"100644", b"100755") or int(entry[3]) > 65536:
        raise Unsupported()
    source = git("cat-file", "blob", entry[2]).decode("utf-8").replace("\r\n", "\n")
    if re.search(r"[\x00-\x08\x0b-\x1f\x7f]", source):
        raise Unsupported()
    return source


def statements(body):
    return [line.strip(" \t") for line in body.split("\n")
            if line.strip(" \t") and not line.lstrip(" \t").startswith("#")]


def metadata(spec, version_file):
    # Check the complete enclosing programs too. Looking only for add_dependency
    # lines would silently accept conditionals, requires and later overrides.
    version_lines = statements(version_file)
    if not version_file.startswith("module NitroIntelligence\n") or len(version_lines) != 3:
        raise Unsupported()
    version = re.fullmatch(rf'VERSION = "({VERSION})"\.freeze', version_lines[1])
    if not version or version_lines[-1] != "end":
        raise Unsupported()

    header = 'require_relative "lib/nitro_intelligence/version"\n'
    if not spec.startswith(header):
        raise Unsupported()
    lines = statements(spec[len(header):])
    if lines[:1] != ["Gem::Specification.new do |s|"] or lines[-1:] != ["end"]:
        raise Unsupported()

    dependencies = {}
    fields = {}
    body = iter(lines[1:-1])
    for line in body:
        if match := re.fullmatch(r's\.(name|version|required_ruby_version)[ \t]*= (.+)', line):
            key, value = match.groups()
            if key in fields:
                raise Unsupported()
            fields[key] = value
        elif match := re.fullmatch(rf's\.add_(?:runtime_)?dependency "({GEM})"((?:, "{REQUIREMENT}")*)', line):
            name, constraints = match.groups()
            if name in dependencies or len(dependencies) >= 128:
                raise Unsupported()
            dependencies[name] = re.findall(r'"([^"]+)"', constraints) or [">= 0"]
        elif re.fullmatch(rf's\.(?:authors|email|homepage|summary|description|license)[ \t]*= (?:{STRING}|{ARRAY})', line):
            continue
        elif re.fullmatch(rf's\.metadata\[{STRING}\] = {STRING}', line):
            continue
        elif re.fullmatch(rf's\.files = Dir\[{STRING}\] \+', line) and re.fullmatch(ARRAY, next(body, "")):
            continue
        else:
            raise Unsupported()

    ruby = re.fullmatch(rf'"({REQUIREMENT})"', fields.get("required_ruby_version", '">= 0"'))
    if not ruby or fields.get("name") != '"nitro_intelligence"' or fields.get("version") != "NitroIntelligence::VERSION":
        raise Unsupported()
    return {"version": version[1], "ruby": ruby[1], "dependencies": dependencies}


if __name__ == "__main__":
    repo, sha = sys.argv[1:]
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        sys.exit(1)
    try:
        candidate = metadata(blob(repo, sha, "nitro_intelligence.gemspec"),
                             blob(repo, sha, "lib/nitro_intelligence/version.rb"))
    except (Unsupported, UnicodeError):
        sys.exit(2)
    print(json.dumps(candidate, separators=(",", ":")))
