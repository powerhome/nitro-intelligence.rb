"""End-to-end tests with a synthetic consumer, two real Git commits and no registry access."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import candidate

HERE = Path(__file__).resolve().parent
GEMSPEC = '''require_relative "lib/nitro_intelligence/version"

Gem::Specification.new do |s|
  s.name = "nitro_intelligence"
  s.version = NitroIntelligence::VERSION
  s.required_ruby_version = ">= 3.3"
  s.add_dependency "example-parent", "~> 1.0"
end
'''
VERSION = 'module NitroIntelligence\n  VERSION = "2.0.0".freeze\nend\n'


class CompatibilityTest(unittest.TestCase):
    def test_candidates_use_only_the_supported_literal_program(self):
        for spec, version in [
            (GEMSPEC + "nil\n", VERSION),
            (GEMSPEC.replace('"~> 1.0"', "ENV.fetch('REQUIREMENT')"), VERSION),
            (GEMSPEC.replace("  s.add_dependency", "  if false\n  s.add_dependency").replace("end\n", "end\nend\n"), VERSION),
            (GEMSPEC, VERSION + "module NitroIntelligence\nend\n"),
        ]:
            with self.subTest(spec=spec, version=version), self.assertRaises(candidate.Unsupported):
                candidate.metadata(spec, version)

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
            shas = []
            for requirement in ["~> 1.0", "~> 2.0"]:
                gemspec.write_text(GEMSPEC.replace("~> 1.0", requirement))
                git("add", ".")
                git("-c", "user.name=CI", "-c", "user.email=ci@example.org",
                    "-c", "commit.gpgsign=false", "commit", "-qm", "Change the candidate")
                shas.append(git("rev-parse", "HEAD"))

            catalog = root / "catalog"
            catalog.mkdir()
            (catalog / "example-parent").write_text("---\n1.0 example-leaf:= 1|\n2.0 example-leaf:= 2|\n")
            (catalog / "example-leaf").write_text("---\n1 |\n2 |\n")
            (catalog / "unrelated").write_text("---\n1 |\n2 |\n")
            snapshot = root / "snapshot"
            snapshot.mkdir()
            ruby, bundler = subprocess.check_output(
                ["ruby", "-rbundler", "-e", "puts RUBY_VERSION, Bundler::VERSION"], text=True).splitlines()
            (snapshot / ".ruby-version").write_text(ruby + "\n")
            (snapshot / "Gemfile.lock").write_text(f"""GIT
  remote: https://example.invalid/component.git
  revision: {'a' * 40}
  specs:
    example-component (1)
      example-leaf (= 1)
      nitro_intelligence (= 1)

PATH
  remote: absent
  specs:
    example-app (1)
      example-component
      nitro_intelligence (= 1)

GEM
  remote: https://rubygems.org/
  specs:
    example-leaf (1)
    example-parent (1.0)
      example-leaf (= 1)
    nitro_intelligence (1)
      example-parent (>= 1)
    unrelated (1)

PLATFORMS
  ruby

DEPENDENCIES
  example-app!
  example-component!
  nitro_intelligence (= 1)
  unrelated

BUNDLED WITH
   {bundler}
""")
            for sha, expected in zip(shas, (0, 6)):
                work = root / sha
                work.mkdir()
                metadata = subprocess.check_output([sys.executable, HERE / "candidate.py", repo, sha])
                (work / "candidate.json").write_bytes(metadata)
                run = subprocess.run(["ruby", HERE / "resolve.rb", snapshot, "candidate.json", catalog],
                                     cwd=work, capture_output=True, text=True,
                                     env={**os.environ, "BUNDLER_VERSION": bundler, "BUNDLE_IGNORE_CONFIG": "1"})
                self.assertEqual(run.returncode, expected, run.stdout + run.stderr)
                if expected == 0:
                    lock = (work / "Gemfile.lock").read_text()
                    self.assertIn("    nitro_intelligence (2.0.0)", lock)
                    self.assertIn("    unrelated (1)", lock)
                    self.assertNotIn("example.invalid", lock)
            self.assertNotEqual(*shas)

            gemspec.unlink()
            gemspec.symlink_to(version)
            git("add", ".")
            git("-c", "user.name=CI", "-c", "user.email=ci@example.org",
                "-c", "commit.gpgsign=false", "commit", "-qm", "Symlink")
            with self.assertRaises(candidate.Unsupported):
                candidate.blob(repo, git("rev-parse", "HEAD"), gemspec.name)


if __name__ == "__main__":
    unittest.main()
