import sys
from pathlib import Path

ASSEMBLER_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = ASSEMBLER_DIR.parents[1]

sys.path.insert(0, str(ASSEMBLER_DIR))
