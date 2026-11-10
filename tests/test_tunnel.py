"""Exercise real embedded Python and shell rollback without Cloudflare credentials."""
import base64
import copy
import http.client
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit

SOURCE = (Path(__file__).resolve().parents[1] / 'xray.sh').read_text(encoding='utf-8')


def embedded(function):
    text = SOURCE.split(function + '() {', 1)[1]
    return re.search(r"<<\s*'PY'\n(.*?)\nPY", text, re.S)[1]


def free_ports(count):
    sockets = []
    try:
        for _ in range(count):
            s = socket.socket()
            s.bind(('127.0.0.1', 0))
            sockets.append(s)
        return [s.getsockname()[1] for s in sockets]
    finally:
        for s in sockets:
            s.close()


class TunnelTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.out = self.root / 'stage'
        self.out.mkdir()
        self.ports = free_ports(5)
        self.config = {'inbounds': [{'tag': 'reality', 'listen': '0.0.0.0',
            'protocol': 'vless', 'port': self.ports[0], 'settings': {'clients': []},
            'streamSettings': {'network': 'tcp', 'security': 'reality'}}],
            'outbounds': [{'protocol': 'freedom'}]}
        (self.root / 'config.json').write_text(json.dumps(self.config))
        (self.root / 'clash-sub.env').write_text(
            f'CLASH_SUB_PORT={self.ports[1]}\nCLASH_SUB_TOKEN=unit-test-secret\n')
        self.env = {**os.environ, 'PYTHONUTF8': '1', 'TUNNEL_NODE_HOST': 'node.example.com',
            'TUNNEL_SUB_HOST': 'sub.example.com', 'TUNNEL_WS_PORT': str(self.ports[2]),
            'TUNNEL_SUB_PORT': str(self.ports[3]), 'TUNNEL_METRICS_PORT': str(self.ports[4]),
            'TUNNEL_WS_PATH': '/private-test-path'}

    def stage(self, action='enable', changes=None):
        return subprocess.run([sys.executable, '-c', embedded('tunnel_stage'),
            str(self.root / 'config.json'), str(self.root / 'tunnel.json'),
            str(self.root / 'clash-sub.env'), str(self.out), action],
            env={**self.env, **(changes or {})}, capture_output=True, text=True, encoding='utf-8')

    def metadata(self):
        result = self.stage()
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((self.out / 'tunnel.json').read_text())

    def test_stage_preserves_reality_and_adds_loopback_ws_without_flow(self):
        meta = self.metadata()
        cfg = json.loads((self.out / 'config.json').read_text())
        self.assertEqual(cfg['inbounds'][0], self.config['inbounds'][0])
        node = cfg['inbounds'][1]
        self.assertEqual(node['listen'], '127.0.0.1')
        self.assertEqual(node['streamSettings']['network'], 'ws')
        self.assertEqual(node['settings']['clients'], [{'id': meta['uuid']}])
        self.assertNotIn('flow', node['settings']['clients'][0])
        self.assertEqual(json.loads((self.root / 'config.json').read_text()), self.config)

    def test_reconfigure_keeps_identity_and_disable_preserves_other_inbounds(self):
        meta = self.metadata()
        (self.root / 'tunnel.json').write_text(json.dumps(meta))
        (self.root / 'config.json').write_bytes((self.out / 'config.json').read_bytes())
        self.assertEqual(self.stage(changes={'TUNNEL_WS_PATH': ''}).returncode, 0)
        new = json.loads((self.out / 'tunnel.json').read_text())
        self.assertEqual(new['uuid'], meta['uuid'])
        self.assertEqual(new['path'], meta['path'])
        self.assertEqual(self.stage('disable').returncode, 0)
        self.assertEqual(json.loads((self.out / 'config.json').read_text()), self.config)
        self.assertFalse(json.loads((self.out / 'tunnel.json').read_text())['enabled'])

    def test_invalid_settings_fail_before_writing_or_modifying_live_files(self):
        cases = [{'TUNNEL_NODE_HOST': v} for v in (
            'https://node.example.com', '127.0.0.1', 'a.example.com\ncommand', '*.example.com')]
        cases += [{'TUNNEL_SUB_HOST': 'node.example.com'}, {'TUNNEL_WS_PORT': '0'},
            {'TUNNEL_WS_PORT': '65536'}, {'TUNNEL_WS_PORT': '018081'},
            {'TUNNEL_WS_PORT': str(self.ports[0])},
            {'TUNNEL_SUB_PORT': str(self.ports[2])}, {'TUNNEL_WS_PATH': '/bad?path'},
            {'TUNNEL_WS_PATH': '/path\ncommand'}]
        original = (self.root / 'config.json').read_bytes()
        for changes in cases:
            with self.subTest(changes=changes):
                self.assertNotEqual(self.stage(changes=changes).returncode, 0)
                self.assertEqual(list(self.out.iterdir()), [])
                self.assertEqual((self.root / 'config.json').read_bytes(), original)

    def test_busy_port_rejected(self):
        with socket.socket() as busy:
            busy.bind(('127.0.0.1', self.ports[2]))
            busy.listen()
            self.assertNotEqual(self.stage().returncode, 0)
        self.assertEqual(list(self.out.iterdir()), [])

    def test_existing_foreign_tag_not_overwritten(self):
        cfg = copy.deepcopy(self.config)
        cfg['inbounds'].append({'tag': 'xray-cf-ws', 'protocol': 'socks'})
        (self.root / 'config.json').write_text(json.dumps(cfg))
        self.assertNotEqual(self.stage().returncode, 0)

    def server_namespace(self, tunnel=True):
        meta = self.metadata()
        (self.root / 'tunnel.json').write_text(json.dumps(meta))
        code = embedded('write_clash_sub_httpd')
        code = code.replace('"/etc/xray/clash-sub.env"', repr(str(self.root / 'clash-sub.env')))
        code = code.replace('"/etc/xray/tunnel.json"', repr(str(self.root / 'tunnel.json')))
        previous = os.environ.get('XRAY_SUB_TUNNEL')
        os.environ['XRAY_SUB_TUNNEL'] = '1' if tunnel else '0'
        try:
            namespace = {'__name__': 'test_subscription'}
            exec(compile(code, 'subscription-server', 'exec'), namespace)
        finally:
            if previous is None:
                os.environ.pop('XRAY_SUB_TUNNEL', None)
            else:
                os.environ['XRAY_SUB_TUNNEL'] = previous
        return namespace, meta

    def test_rendered_clash_has_ws_tls_and_preserves_groups_and_rules(self):
        server, meta = self.server_namespace()
        template = ('proxies:\n  - name: Test-Reality\n    type: vless\n    flow: xtls-rprx-vision\n'
            '    reality-opts:\n      public-key: old\n\nproxy-groups:\n  - name: Choose\n'
            '    type: select\n    proxies: [Test-Reality]\nrules:\n  - MATCH,Choose\n')
        result = server['tunnel_response']('/token/clash.yaml', template.encode()).decode()
        self.assertIn('network: ws', result)
        self.assertIn('tls: true', result)
        self.assertIn(meta['node_host'], result)
        self.assertNotIn('flow:', result)
        self.assertNotIn('reality-opts:', result)
        self.assertEqual(result.split('proxy-groups:')[1], template.split('proxy-groups:')[1])

    def test_native_link_encodes_path_and_has_no_reality_flow(self):
        server, meta = self.server_namespace()
        uri = urlsplit(base64.b64decode(server['tunnel_response']('/token/vless.txt', b'old')).decode().strip())
        params = parse_qs(uri.query)
        self.assertEqual((uri.hostname, uri.port, uri.username), (meta['node_host'], 443, meta['uuid']))
        self.assertEqual(params['path'], [meta['path']])
        self.assertEqual(params['security'], ['tls'])
        self.assertNotIn('flow', params)
        self.assertNotIn('pbk', params)

    def test_xray_client_replaces_only_proxy_preserving_routing(self):
        server, meta = self.server_namespace()
        original = {'outbounds': [{'tag': 'proxy', 'protocol': 'vless', 'settings': {},
            'streamSettings': {'network': 'tcp', 'realitySettings': {}}}, {'tag': 'direct', 'protocol': 'freedom'}],
            'routing': {'domainStrategy': 'IPIfNonMatch'}}
        result = json.loads(server['tunnel_response']('/token/xray.json', json.dumps(original).encode()))
        self.assertEqual(result['routing'], original['routing'])
        self.assertEqual(result['outbounds'][1], original['outbounds'][1])
        stream = result['outbounds'][0]['streamSettings']
        self.assertEqual((stream['network'], stream['security']), ('ws', 'tls'))
        self.assertNotIn('realitySettings', stream)

    def test_http_listener_transforms_subscriptions_and_rejects_wrong_token(self):
        server, meta = self.server_namespace()
        fixture = self.root / 'native.txt'
        fixture.write_text('original unchanged')
        server['ROUTES']['/unit-test-secret/vless.txt'] = (str(fixture), 'text/plain')
        httpd = server['HTTPServer'](('127.0.0.1', 0), server['Handler'])
        worker = threading.Thread(target=httpd.serve_forever, daemon=True)
        worker.start()
        try:
            for path, expected in [('/unit-test-secret/vless.txt', 200), ('/bad/vless.txt', 404), ('/', 404)]:
                conn = http.client.HTTPConnection('127.0.0.1', httpd.server_port, timeout=3)
                conn.request('GET', path)
                response = conn.getresponse()
                data = response.read()
                self.assertEqual(response.status, expected)
                if expected == 200:
                    self.assertIn(meta['node_host'].encode(), base64.b64decode(data))
                conn.close()
        finally:
            httpd.shutdown()
            httpd.server_close()
            worker.join()
        self.assertEqual(fixture.read_text(), 'original unchanged')

    def test_direct_listener_ignores_tunnel_and_keeps_original_routes(self):
        server, _ = self.server_namespace(tunnel=False)
        self.assertFalse(server['TUNNEL'])
        self.assertEqual(server['PORT'], self.ports[1])
        self.assertNotIn('/unit-test-secret/xray.json', server['ROUTES'])

    def test_broken_yaml_template_rejected(self):
        server, _ = self.server_namespace()
        with self.assertRaises(ValueError):
            server['tunnel_response']('/token/clash.yaml', b'broken')

    def shell_configure(self, fail=False, cancel=False, existing=False, action='enable', restart_fail=False):
        bash = shutil.which('bash')
        if os.name == 'nt':
            bash = r'C:\Program Files\Git\bin\bash.exe'
        if not bash or not Path(bash).exists():
            self.skipTest('POSIX shell unavailable')
        if existing:
            meta = self.metadata()
            (self.root / 'tunnel.json').write_text(json.dumps(meta))
            (self.root / 'tunnel-token').write_text('old-private-token')
            (self.root / 'config.json').write_bytes((self.out / 'config.json').read_bytes())
        before = {p.name: p.read_bytes() for p in self.root.iterdir() if p.is_file()}
        library = self.root / 'library.sh'
        library.write_text(SOURCE.rsplit('manager_main "$@"', 1)[0], encoding='utf-8')
        driver = self.root / 'driver.sh'
        driver.write_text('''#!/bin/sh
set -e
. "$(dirname "$0")/library.sh"
XRAY_DIR=$(dirname "$0")
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_BIN=/bin/true
manager_require_platform() { XRAY_PLATFORM=debian; }
manager_read_default() { printf '%s' "$2"; }
manager_read_secret() { printf '%040d' 1; }
manager_read() { printf '%s' "$TEST_CONFIRM"; }
tunnel_install_binary() { echo install >> "$XRAY_DIR/events"; }
write_clash_sub_httpd() { :; }
manager_restart_xray() {
    echo restart >> "$XRAY_DIR/events"
    if [ "$TEST_RESTART_FAIL" = 1 ] && [ ! -f "$XRAY_DIR/restart-failed-once" ]; then
        touch "$XRAY_DIR/restart-failed-once"
        return 1
    fi
}
manager_check_listeners() { :; }
tunnel_services() { echo "services:$1" >> "$XRAY_DIR/events"; }
tunnel_health() { return "$TEST_HEALTH_EXIT"; }
tunnel_show() { :; }
tunnel_configure "$TEST_ACTION"
'''.replace('set -e\n', 'set -e\npython3() { '+shlex.quote(Path(sys.executable).as_posix())+' "$@"; }\n', 1), encoding='utf-8')
        env = {**self.env, 'TEST_CONFIRM': 'n' if cancel else 'y', 'TEST_HEALTH_EXIT': '1' if fail else '0',
               'MSYS2_ENV_CONV_EXCL': 'TUNNEL_WS_PATH', 'TEST_ACTION': action,
               'TEST_RESTART_FAIL': '1' if restart_fail else '0'}
        env.pop('XRAY_TUNNEL_TOKEN', None)
        result = subprocess.run([bash, driver.as_posix()], env=env, capture_output=True, text=True, encoding='utf-8')
        self.assertFalse((self.root / '.manager-config-lock').exists(), result.stderr)
        if fail or cancel or restart_fail:
            for name, data in before.items():
                self.assertEqual((self.root / name).read_bytes(), data, name)
            if not existing:
                self.assertFalse((self.root / 'tunnel.json').exists())
                self.assertFalse((self.root / 'tunnel-token').exists())
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads((self.root / 'tunnel.json').read_text())['enabled'], action == 'enable')
            if action == 'disable':
                self.assertFalse((self.root / 'tunnel-token').exists())
                self.assertEqual(json.loads((self.root / 'config.json').read_text()), self.config)
        return result

    def test_shell_enable_commits_after_health_check(self):
        self.shell_configure()

    def test_shell_first_enable_failure_restores_config_and_removes_credentials(self):
        result = self.shell_configure(fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('services:stop', (self.root / 'events').read_text())

    def test_shell_update_failure_restores_previous_identity_token_and_services(self):
        result = self.shell_configure(fail=True, existing=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('services:start', (self.root / 'events').read_text())

    def test_shell_cancel_leaves_live_files_untouched(self):
        self.assertEqual(self.shell_configure(cancel=True).returncode, 0)
        self.assertFalse((self.root / 'events').exists())

    def test_shell_disable_removes_only_tunnel_inbound_and_current_token(self):
        self.shell_configure(existing=True, action='disable')
        self.assertIn('services:stop', (self.root / 'events').read_text())

    def test_shell_disable_restart_failure_restores_previous_config_and_token(self):
        result = self.shell_configure(existing=True, action='disable', restart_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('services:start', (self.root / 'events').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
