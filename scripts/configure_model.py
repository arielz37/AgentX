#!/usr/bin/env python3
"""Run interactively in Terminal. Key input is hidden and is never printed."""
from getpass import getpass
from pathlib import Path
import os
path = Path(__file__).resolve().parents[1] / '.env'
if path.exists():
    raise SystemExit('.env already exists; edit it locally without sharing the key.')
key = getpass('OpenAI API Key (hidden): ').strip()
if not key or '\n' in key: raise SystemExit('Empty/invalid key; nothing saved.')
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write('OPENAI_API_KEY=' + key + '\nAGENTX_MODEL=gpt-4.1-mini\n')
print('Saved Mac-only .env (0600). Key not printed.')
