#!/usr/bin/env bash
# pytest.sh [pytest args] — run the integration suite (tests/py) with
# whatever pytest is available: the system one, else a virtualenv under
# build/venv that is created on first use (needs network once). The
# suite needs pytest and requests.
set -euo pipefail
cd "$(dirname "$0")/.."
if python3 -c 'import pytest, requests' 2>/dev/null; then
    PY=python3
else
    if ! build/venv/bin/python -c 'import pytest, requests' 2>/dev/null; then
        echo "pytest.sh: creating build/venv with pytest + requests"
        python3 -m venv build/venv
        build/venv/bin/pip install -q pytest requests
    fi
    PY=build/venv/bin/python
fi
[ $# -gt 0 ] || set -- tests/py
exec "$PY" -m pytest -q "$@"
