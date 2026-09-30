"""Public checkout configuration is local to AgentX and preserves env precedence."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import agentx_config


class ModelConfigurationTests(unittest.TestCase):
    def test_parent_config_is_not_loaded_and_agentx_name_is_supported(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {}, clear=True):
            parent = Path(tmp)
            root = parent / 'AgentX'
            root.mkdir()
            (parent / '.env').write_text('OPENAI_API_KEY=parent-placeholder\n')
            (root / '.env').write_text('AGENTX_MODEL=project-model\n')
            with patch.object(agentx_config, 'ROOT', root):
                agentx_config.load_model_env()
            self.assertNotIn('OPENAI_API_KEY', os.environ)
            self.assertEqual(os.environ['AGENTX_MODEL'], 'project-model')

    def test_process_environment_takes_precedence(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, {'AGENTX_MODEL': 'process-model'}, clear=True):
            root = Path(tmp)
            (root / '.env').write_text('OPENAI_API_KEY=local-placeholder\nAGENTX_MODEL=file-model\n')
            with patch.object(agentx_config, 'ROOT', root):
                agentx_config.load_model_env()
            self.assertEqual(os.environ['OPENAI_API_KEY'], 'local-placeholder')
            self.assertEqual(os.environ['AGENTX_MODEL'], 'process-model')


if __name__ == '__main__':
    unittest.main()
