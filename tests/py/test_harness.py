"""The fuzz harnesses over the seed corpus: a crash or a violated
invariant in the parsers fails the suite even without AFL++ around."""
import subprocess

import pytest

from conftest import ROOT

HTTP = ROOT / "build" / "fuzz_http"
MD = ROOT / "build" / "fuzz_md"


@pytest.mark.skipif(not (HTTP.exists() and MD.exists()), reason="harnesses not built (make harness)")
def test_corpus_replay():
    r = subprocess.run([str(ROOT / "tests" / "fuzz" / "replay.sh")], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "no crashes" in r.stdout
