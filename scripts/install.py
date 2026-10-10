"""Entry point for the installer. scripts/install.sh finds a python3 and runs this."""

import sys
from pathlib import Path

# Named here rather than through PYTHONPATH, which would be exported to every
# tool a step runs.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from installer.cli import main

if __name__ == "__main__":
    sys.exit(main())
