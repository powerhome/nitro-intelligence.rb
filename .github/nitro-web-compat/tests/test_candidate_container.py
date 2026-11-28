"""Exercise the actual loader container and its single validated output on the public runner."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CANDIDATE_DIR = Path(__file__).resolve().parents[1] / "candidate"


class CandidateContainerTest(unittest.TestCase):
    def test_only_validated_metadata_reaches_the_runner(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp)
            spec = source / "nitro_intelligence.gemspec"
            spec.write_text("""raise if File.writable?(__FILE__) || ENV.key?('GITHUB_OUTPUT')
puts 'gemspec output'
Gem::Specification.new do |s|
  s.name = 'nitro_intelligence'
  s.version = [1, 2].join('.')
  s.add_dependency 'example', '>= 1', '< 3'
end
""")

            def extract():
                return subprocess.run(["bash", CANDIDATE_DIR / "candidate.sh", source], capture_output=True, text=True,
                                      env={**os.environ, "GITHUB_OUTPUT": str(source / "runner-output")})

            result = extract()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), {"version": "1.2", "ruby": [">= 0"],
                                                        "dependencies": {"example": [">= 1", "< 3"]}})
            spec.write_text(spec.read_text().replace("'nitro_intelligence'", "'wrong-name'"))
            result = extract()
            self.assertEqual((result.returncode, result.stdout), (2, ""))


if __name__ == "__main__":
    unittest.main()
