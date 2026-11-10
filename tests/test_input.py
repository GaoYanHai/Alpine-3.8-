"""Prompt validation on all platforms; real terminal editing tests on Linux."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'xray.sh').read_text(encoding='utf-8')
BASH = r'C:\Program Files\Git\bin\bash.exe' if os.name == 'nt' else '/bin/sh'


class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.library = self.root/'library.sh'
        self.library.write_text(SOURCE.rsplit('manager_main "$@"', 1)[0], encoding='utf-8')

    def validate(self, kind, value):
        env = {**os.environ, 'CHECK_KIND': kind, 'CHECK_VALUE': value, 'PYTHONUTF8': '1',
               'MSYS2_ENV_CONV_EXCL': 'CHECK_VALUE'}
        return subprocess.run([BASH, '-c', '. "$1"; input_validate "$CHECK_KIND" "$CHECK_VALUE"',
                               self.library.as_posix(), self.library.as_posix()], env=env, capture_output=True).returncode

    def test_required_whitespace_control_and_multiline_values_rejected(self):
        for kind in ['required', 'password', 'domain', 'port', 'username', 'token', 'bundle-password']:
            for value in ['', ' ', '\t', 'word\r', 'one\ntwo', 'word\x7f']:
                with self.subTest(kind=kind, value=repr(value)):
                    self.assertNotEqual(self.validate(kind, value), 0)

    def test_domain_and_port_formats(self):
        for value in ['sub.example.com', 'a.b', 'SUB.Example.com', 'node-1.example.com']:
            self.assertEqual(self.validate('domain', value), 0, value)
        for value in ['example', 'https://a.b', 'a.b:443', 'a.b/path', '*.a.b',
                      '127.0.0.1', '-node.example.com', 'a..b', 'a.b.', 'a_b.example.com']:
            self.assertNotEqual(self.validate('domain', value), 0, value)
        for value in ['1', '443', '65535']:
            self.assertEqual(self.validate('port', value), 0)
        for value in ['0', '65536', '9999999999999999999999', '0443', '-1', '80a']:
            self.assertNotEqual(self.validate('port', value), 0)

    def test_optional_fields_are_explicit_and_validated_when_present(self):
        for kind in ['optional', 'optional-domain', 'optional-tunnel-token']:
            self.assertEqual(self.validate(kind, ''), 0)
        self.assertNotEqual(self.validate('optional-domain', 'http://a.b'), 0)
        self.assertNotEqual(self.validate('optional-tunnel-token', 'short'), 0)
        self.assertEqual(self.validate('optional-tunnel-token', 'A'*40), 0)

    def test_other_typed_fields(self):
        cases = [('ipv4', '203.0.113.10', True), ('ipv4', '127.0.0.1', False),
            ('ipv4', '256.2.3.4', False), ('ipv4', '01.2.3.4', False),
            ('uuid', 'new', True), ('uuid', 'ea3d5ec1-64a1-4057-8034-aaf7b2b73723', True),
            ('uuid', 'bad', False), ('shortid', '0001', True), ('shortid', 'abc', False),
            ('loglevel', 'warning', True), ('loglevel', 'warn', False),
            ('socks-port', 'off', True), ('socks-port', 'no', False),
            ('username', 'a.b_1@x', True), ('username', 'a user', False),
            ('boolean', 'n', True), ('boolean', 'maybe', False),
            ('choice:|1|2|3|', '2', True), ('choice:|1|2|3|', '12', False),
            ('bundle-password', '12345678', True), ('bundle-password', 'short', False),
            ('password', 'a b : %', True)]
        for kind, value, accepted in cases:
            with self.subTest(kind=kind, value=value):
                self.assertEqual(self.validate(kind, value) == 0, accepted)

    def test_file_paths_and_output_no_overwrite(self):
        existing = self.root/'certificate with spaces.pem'
        existing.write_text('test certificate')
        self.assertEqual(self.validate('file', existing.as_posix()), 0)
        self.assertNotEqual(self.validate('file', (self.root/'missing').as_posix()), 0)
        self.assertNotEqual(self.validate('output', existing.as_posix()), 0)
        self.assertEqual(self.validate('output', (self.root/'new.p12').as_posix()), 0)

    def test_pipe_invalid_input_does_not_consume_following_menu_action(self):
        driver = self.root/'pipe.sh'
        driver.write_text('''. "$(dirname "$0")/library.sh"
exec 9<&0
value=$(manager_read_default 'DOMAIN' '' domain)
status=$?
IFS= read -r following <&9
printf '%s|%s' "$status" "$following"
''', encoding='utf-8')
        result = subprocess.run([BASH, driver.as_posix()], input=b'\n7\n', capture_output=True)
        self.assertEqual(result.stdout, b'1|7')


@unittest.skipUnless(sys.platform.startswith('linux'), 'Requires Linux PTY / termios')
class TerminalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root/'library.sh').write_text(SOURCE.rsplit('manager_main "$@"', 1)[0])

    def terminal(self, expression, keys, expected=None, fallback=False, signal_exit=False, erase=None,
                 setup='', marker=b'PROMPT: '):
        import fcntl
        import pty
        import select
        import termios
        driver = self.root/'driver.sh'
        driver.write_text('''#!/bin/sh
. "$(dirname "$0")/library.sh"
exec 9<>/dev/tty
exec 3<>/dev/tty
''' + setup + '\n' + ('input_terminal_python() { input_terminal_shell "$@"; }\n' if fallback else '') +
            'printf READY\\n >&2\nvalue=$('+expression+')\nstatus=$?\n'
            'printf "%s" "$value" > "$(dirname "$0")/result"\n'
            'printf "%s" "$status" > "$(dirname "$0")/status"\n')
        master, slave = pty.openpty()
        if erase is not None:
            attributes = termios.tcgetattr(slave)
            attributes[6][termios.VERASE] = erase
            termios.tcsetattr(slave, termios.TCSANOW, attributes)
        before = termios.tcgetattr(slave)
        def setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        process = subprocess.Popen(['/bin/sh', str(driver)], stdin=slave, stdout=slave, stderr=slave, preexec_fn=setup)
        output = bytearray()
        def collect_until(marker, deadline=10):
            end = time.monotonic()+deadline
            while marker not in output and time.monotonic() < end:
                if select.select([master], [], [], .1)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError:
                        break
            self.assertIn(marker, output, bytes(output))
        try:
            collect_until(marker)
            if signal_exit:
                # Deliver to the entire process group, as a terminal disconnect would.
                os.killpg(process.pid, signal.SIGTERM)
            else:
                os.write(master, keys)
            process.wait(timeout=15)
            if signal_exit:
                # The shell can exit before its Python child handles the same signal.
                deadline = time.monotonic()+2
                while termios.tcgetattr(slave) != before and time.monotonic() < deadline:
                    time.sleep(.01)
            while select.select([master], [], [], 0)[0]:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
            self.assertEqual(termios.tcgetattr(slave), before, 'Terminal mode was not restored')
            if expected is not None:
                self.assertEqual((self.root/'result').read_text(), expected, bytes(output))
                self.assertEqual((self.root/'status').read_text(), '0', bytes(output))
            return bytes(output)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            os.close(master)
            os.close(slave)

    def test_backspace_bs_and_del_ignore_existing_erase_setting(self):
        for erase in [b'\x08', b'\x7f']:
            self.terminal("manager_read_default 'PROMPT' '' domain", b'bad\x08\x7f\x08sub.example.com\r', 'sub.example.com', erase=erase)

    def test_empty_whitespace_and_invalid_domain_reprompt_without_advancing(self):
        output = self.terminal("manager_read_default 'PROMPT' '' domain",
            b'\r   \rhttps://bad.example.com\rsub.example.com\r', 'sub.example.com')
        self.assertEqual(output.count(b'PROMPT: '), 4)

    def test_subscription_and_installation_prompts_use_the_same_editor(self):
        for expression in ["subscription_prompt 'PROMPT' '' domain", "prompt_input 'PROMPT' '' domain"]:
            self.terminal(expression, b'x\x7fsub.example.com\r', 'sub.example.com')

    def test_hidden_secrets_edit_without_echo_or_ansi_leak(self):
        output = self.terminal("manager_read_secret 'PROMPT'", b'Secretbad\x08\x7f\x08-123\r', 'Secret-123')
        self.assertNotIn(b'Secret', output)
        self.assertNotIn(b'123', output)

    def test_unicode_backspace_and_arrow_delete(self):
        self.terminal("manager_read_default 'PROMPT' '' required", '错误'.encode()+b'\x08\x7fcorrect\r', 'correct')
        self.terminal("manager_read_default 'PROMPT' '' required", b'abxc\x1b[D\x1b[D\x1b[3~\r', 'abc')

    def test_ctrl_u_clears_and_ctrl_c_eof_restore_terminal(self):
        self.terminal("manager_read_default 'PROMPT' '' domain", b'bad\x15sub.example.com\r', 'sub.example.com')
        for key, status in [(b'\x03', '130'), (b'\x04', '1')]:
            self.terminal("manager_read_secret 'PROMPT'", key)
            self.assertEqual((self.root/'status').read_text(), status)

    def test_signal_restores_terminal(self):
        self.terminal("manager_read_secret 'PROMPT'", b'', signal_exit=True)

    def test_no_python_fallback_backspace_validation_hidden_and_interrupt(self):
        self.terminal("manager_read_default 'PROMPT' '' port", b'\r52x\x08\x7f2300\r', '52300', fallback=True)
        output = self.terminal("manager_read_secret 'PROMPT'", b'hiddenX\x7f\r', 'hidden', fallback=True)
        self.assertNotIn(b'hidden', output)
        self.terminal("manager_read_default 'PROMPT' '' port", b'\x03', fallback=True)
        self.assertEqual((self.root/'status').read_text(), '130')

    def test_optional_http_domain_can_still_be_empty(self):
        self.terminal("manager_read_default 'PROMPT' '' optional-domain", b'\r', '')

    def test_https_configuration_rejects_empty_domain_before_confirmation_or_backup(self):
        (self.root/'config.json').write_text('{}')
        (self.root/'client-link.txt').write_text('unchanged')
        setup = '''
XRAY_DIR=$(dirname "$0")
XRAY_CONFIG="$XRAY_DIR/config.json"
SHARE_FILE="$XRAY_DIR/client-link.txt"
manager_require_platform() { XRAY_PLATFORM=debian; }
load_node_settings() {
    printf '%s\n' "CLASH_SUB_HOST=''" "CLASH_SUB_TLS_CERT=''" "CLASH_SUB_TLS_KEY=''"
}
'''
        output = self.terminal('manager_edit_https', b'1\r\r   \rbad-domain\rsub.example.com\rn\r',
                               setup=setup, marker='请选择 [1–3]: '.encode())
        self.assertEqual(output.count('此项不能为空'.encode()), 2)
        self.assertIn('域名无效'.encode(), output)
        self.assertEqual((self.root/'status').read_text(), '0')
        self.assertFalse((self.root/'.manager-config-lock').exists())
        self.assertEqual(list(self.root.glob('config-backup-*')), [])
        self.assertEqual((self.root/'client-link.txt').read_text(), 'unchanged')

    def test_https_install_wizard_does_not_ask_for_port_until_domain_is_valid(self):
        setup = '''
CLASH_SUB_HTTPS=cloudflare
CLASH_SUB_HOST=''
subscription_setup_cloudflare() { :; }
'''
        output = self.terminal('configure_subscription_https', b'\rbad-domain\rsub.example.com\r\rq\r',
            setup=setup, marker='完整订阅域名，例如 sub.example.com: '.encode())
        self.assertIn('此项不能为空'.encode(), output)
        self.assertIn('域名无效'.encode(), output)
        port_position = output.find('公网订阅端口'.encode())
        self.assertGreater(port_position, output.find('域名无效'.encode()))
        self.assertEqual((self.root/'status').read_text(), '1')


if __name__ == '__main__':
    unittest.main(verbosity=2)
