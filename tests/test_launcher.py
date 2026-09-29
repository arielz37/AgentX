import contextlib
import io
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import start_wellphone as launcher


def device(udid):
    return {'hardwareProperties': {'udid': udid}, 'identifier': 'core-' + udid}


class LauncherTests(unittest.TestCase):
    def test_device_selection_never_guesses_multiple_devices(self):
        devices = [device('one'), device('two')]
        with contextlib.redirect_stdout(io.StringIO()):
            for choices in ([], devices):
                with self.assertRaises(launcher.StartupError):
                    launcher.select_device(choices, interactive=False)
        self.assertEqual(launcher.select_device(devices, 'CORE-two'), devices[1])
        self.assertEqual(launcher.select_device(devices[:1]), devices[0])
        with self.assertRaises(launcher.StartupError):
            launcher.select_device(devices, 'not-connected')

    def test_forwarder_requires_same_project_and_device(self):
        script = Path('/project/scripts/forward_rpc_localhost.py')
        self.assertTrue(launcher.is_forwarder_command(
            'python3 scripts/forward_rpc_localhost.py --udid one', '/project', script, {'one'}))
        for command in (
            'python3 scripts/forward_rpc_localhost.py --udid two',
            'python3 /other/scripts/forward_rpc_localhost.py --udid one',
            'python3 something_else.py --udid one',
        ):
            self.assertFalse(launcher.is_forwarder_command(command, '/project', script, {'one'}))

    def test_existing_worker_lock_is_reused_without_removing_it(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(launcher, 'ROOT', Path(temp)):
            self.assertFalse(launcher.worker_running())
            held = launcher.lock_file(Path(temp) / 'wellphone-data/.worker.lock')
            try:
                self.assertTrue(launcher.worker_running())
                self.assertTrue(launcher.worker_running())
            finally:
                held.close()
            self.assertFalse(launcher.worker_running())

    def test_cleanup_only_signals_owned_live_processes(self):
        services = launcher.Services()
        live = Mock(pid=111)
        live.poll.return_value = None
        exited = Mock(pid=222)
        exited.poll.return_value = 0
        services.children = [('worker', live), ('forwarder', exited)]
        with patch.object(launcher.os, 'killpg') as kill:
            services.close()
        kill.assert_called_once_with(111, signal.SIGINT)

    def test_check_and_reuse_never_spawn_services(self):
        for arguments in (['--check'], []):
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as temp, \
                 patch.object(launcher, 'RUNTIME', Path(temp)), \
                 patch.object(sys, 'argv', ['launcher', *arguments]), \
                 patch.object(launcher, 'discover_devices', return_value=[device('one')]), \
                 patch.object(launcher, 'forwarder_running', return_value=True), \
                 patch.object(launcher, 'worker_running', return_value=True), \
                 patch.object(launcher, 'connection_label', return_value='connected') as status, \
                 patch.object(launcher.shutil, 'which', return_value='/usr/bin/xcrun'), \
                 patch('wellphone_model.load_env'), \
                 patch.dict(launcher.os.environ, {'OPENAI_API_KEY': 'test-placeholder'}), \
                 patch.object(launcher.Services, 'start') as start, \
                 contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(launcher.main(), 0)
                start.assert_not_called()
                self.assertEqual(status.call_count, 0 if arguments else 1)

    def test_conflicting_port_fails_without_starting_or_killing(self):
        with patch.object(launcher.socket, 'socket') as sock, \
             patch.object(launcher, 'run', return_value=Mock(stdout='p123\n')) as run, \
             patch.object(launcher.os, 'killpg') as kill:
            sock.return_value.__enter__.return_value.bind.side_effect = OSError('busy')
            with self.assertRaises(launcher.StartupError):
                launcher.forwarder_running(device('one'))
            kill.assert_not_called()


if __name__ == '__main__':
    unittest.main()
