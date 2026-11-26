"""End-to-end tests with a synthetic consumer, two Git commits and public RubyGems metadata."""
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import candidate

HERE = Path(__file__).resolve().parent
GEMSPEC = '''require_relative "lib/nitro_intelligence/version"
require_relative "dependencies"

Gem::Specification.new do |s|
  s.name = "nitro_intelligence"
  s.version = NitroIntelligence::VERSION
  s.required_ruby_version = ['>= 3.3', '< 4']
  REQUIREMENTS.each { |name, bounds| s.add_dependency(name, *bounds) }
  s.add_development_dependency 'test-only'
end
'''
VERSION = 'module NitroIntelligence\n  VERSION = "2.0.0".freeze\nend\n'


class CompatibilityTest(unittest.TestCase):
    def test_invalid_loader_output_is_rejected(self):
        valid = {"name": "nitro_intelligence", "platform": "ruby", "version": "2.0.0",
                 "ruby": [">= 3.3"], "dependencies": {}}
        for change in [
            {"name": "other"}, {"platform": "java"}, {"version": []}, {"ruby": []},
            {"ruby": ">= 3.3"}, {"ruby": [">= 3.3\n"]}, {"unknown": True},
            {"dependencies": {"a/b": ["= 1"]}}, {"dependencies": {"a": [1]}},
            {"dependencies": {f"gem-{n}": [">= 0"] for n in range(129)}},
        ]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                candidate.metadata(io.BytesIO(json.dumps({**valid, **change}).encode()))
        encoded = json.dumps(valid).encode()
        for raw in [b"", encoded + b"junk", encoded.replace(b'"ruby": [', b'"ruby": [], "ruby": ['),
                    encoded + b" " * candidate.MAX_BYTES]:
            with self.subTest(size=len(raw)), self.assertRaises(ValueError):
                candidate.metadata(io.BytesIO(raw))

    def test_targeted_update_on_two_revisions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            repo.mkdir()

            def git(*args):
                return subprocess.check_output(["git", "-C", repo, *args], text=True).strip()

            git("init", "-q")
            version = repo / "lib/nitro_intelligence/version.rb"
            version.parent.mkdir(parents=True)
            version.write_text(VERSION)
            gemspec = repo / "nitro_intelligence.gemspec"
            gemspec.write_text(GEMSPEC)
            shas = []
            # Support 3.13 requires moving the consumer's rspec-core. Support 3.11 conflicts with it.
            for requirement in ["= 3.13.0", "= 3.11.0"]:
                (repo / "dependencies.rb").write_text(f"REQUIREMENTS = {{'rspec-support' => ['{requirement}']}}\n")
                git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.org",
                    "-c", "commit.gpgsign=false", "commit", "-qm", "Change the candidate")
                shas.append(git("rev-parse", "HEAD"))

            snapshot = root / "snapshot"
            snapshot.mkdir()
            ruby, bundler = subprocess.check_output(
                ["ruby", "-rbundler", "-e", "puts RUBY_VERSION, Bundler::VERSION"], text=True).splitlines()
            (snapshot / ".ruby-version").write_text(ruby + "\n")
            # Bundler lists the Windows-only root under DEPENDENCIES without a spec on this platform.
            (snapshot / "Gemfile.lock").write_text(f"""GIT
  remote: https://example.invalid/component.git
  revision: {'a' * 40}
  specs:
    example-component (1)
      nitro_intelligence (= 1)
      rspec-core (>= 3.12, <= 3.13.0)

PATH
  remote: absent
  specs:
    example-app (1)
      example-component
      nitro_intelligence (= 1)

GEM
  remote: https://rubygems.org/
  specs:
    nitro_intelligence (1)
      rspec-support (~> 3.12.0)
    rake (13.2.1)
    rspec-core (3.12.0)
      rspec-support (~> 3.12.0)
    rspec-support (3.12.0)

PLATFORMS
  ruby

DEPENDENCIES
  example-app!
  example-component!
  example-windows-only
  nitro_intelligence (= 1)
  rake

BUNDLED WITH
   {bundler}
""")
            for sha, expected in zip(shas, (0, 6)):
                work = root / sha
                work.mkdir()
                git("checkout", "-q", "--detach", sha)
                raw = work / "raw.json"
                subprocess.run(["ruby", HERE / "load_gemspec.rb", raw], cwd=repo, check=True)
                with raw.open("rb") as stream:
                    metadata = subprocess.check_output([sys.executable, HERE / "candidate.py"], stdin=stream)
                self.assertEqual(set(json.loads(metadata)["dependencies"]), {"rspec-support"})
                self.assertCountEqual(json.loads(metadata)["ruby"], [">= 3.3", "< 4"])
                (work / "candidate.json").write_bytes(metadata)
                run = subprocess.run(["ruby", HERE / "resolve.rb", snapshot, "candidate.json"],
                                     cwd=work, capture_output=True, text=True,
                                     env={**os.environ, "BUNDLER_VERSION": bundler, "BUNDLE_IGNORE_CONFIG": "1"})
                self.assertEqual(run.returncode, expected, run.stdout + run.stderr)
                if expected == 0:
                    lock = (work / "Gemfile.lock").read_text()
                    self.assertIn("    nitro_intelligence (2.0.0)", lock)
                    self.assertIn("    rspec-support (3.13.0)", lock)
                    self.assertIn("    rspec-core (3.13.0)", lock)
                    self.assertIn("    rake (13.2.1)", lock)
                    self.assertIn("  remote: https://rubygems.org/", lock)
                    self.assertIn("  remote: stubs", lock)
                    self.assertIn("    example-component (1)", lock)
                    self.assertIn("    example-app (1)", lock)
                    self.assertNotIn("example-windows-only", lock)
                    self.assertNotIn("example.invalid", lock)
                else:
                    # A conflict leaves Bundler's starting lockfile in the working directory.
                    self.assertEqual((work / "Gemfile.lock").read_bytes(), (snapshot / "Gemfile.lock").read_bytes())
            self.assertNotEqual(*shas)

            gemspec.rename(repo / "linked.rb")
            gemspec.symlink_to("linked.rb")
            result = subprocess.run(["ruby", HERE / "load_gemspec.rb", root / "linked.json"], cwd=repo)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
