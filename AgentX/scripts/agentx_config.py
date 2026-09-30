"""AgentX's single port configuration; never falls back to PhoneAgent."""
from pathlib import Path
import plistlib
ROOT = Path(__file__).resolve().parents[1]
CONFIG = plistlib.loads((ROOT / 'AgentXConfig.plist').read_bytes())
APP_ID = 'agentx'
PROTOCOL_VERSION = 1
PORT = CONFIG['RPCPort']
if CONFIG['AppID'] != APP_ID or CONFIG['ProtocolVersion'] != PROTOCOL_VERSION or type(PORT) is not int or not 1024 <= PORT <= 65535 or PORT == 45678:
    raise ValueError('Invalid AgentX identity/port; legacy port is forbidden')


def load_model_env():
    # Read existing authorized configuration; never copy secrets into this tree.
    from wellphone_model import load_env
    load_env(ROOT / '.env')
    load_env(ROOT.parent / '.env')
