"""Offline checks for generated subscriptions and the embedded HTTP/TLS server."""
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ('alpine_xray_improved.sh', 'debian_xray_improved.sh')


def executable(name):
    git_path = Path('C:/Program Files/Git/usr/bin') / (name + '.exe')
    return str(git_path) if git_path.is_file() else shutil.which(name)


class SubscriptionTest(unittest.TestCase):
    def test_update_reuses_matching_node_and_rejects_stale_link(self):
        source = (ROOT/'subscription-update.sh').read_text(encoding='utf-8')
        parser = source.split('> "$task_tmp/node.env" <<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            node = {'inbounds': [{'protocol': 'vless', 'port': 52300,
                                 'settings': {'clients': [{'id': 'fixture-uuid', 'flow': 'xtls-rprx-vision'}]},
                                 'streamSettings': {'realitySettings': {'serverNames': ['example.com'],
                                                                       'shortIds': ['0123456789abcdef']}}}]}
            link = ('vless://fixture-uuid@203.0.113.10:52300?flow=xtls-rprx-vision'
                    '&security=reality&sni=example.com&sid=0123456789abcdef&fp=chrome&type=tcp&pbk=fixture-key')
            (folder/'config.json').write_text(json.dumps(node))
            (folder/'share.txt').write_text(link+'\n')
            (folder/'sub.env').write_text('CLASH_SUB_TOKEN=original-token\nCLASH_SUB_PORT=58472\n')
            env = os.environ.copy()
            env['CLASH_SUB_PORT'] = '58473'
            args = [sys.executable, '-', str(folder/'config.json'), str(folder/'share.txt'), str(folder/'sub.env')]
            result = subprocess.run(args, input=parser, text=True, capture_output=True, env=env, encoding='utf-8')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('CLASH_SUB_TOKEN=original-token', result.stdout)
            self.assertIn('CLASH_SUB_PORT=58473', result.stdout)
            self.assertIn('PUB_KEY=fixture-key', result.stdout)
            (folder/'share.txt').write_text(link.replace('fixture-uuid@', 'stale-uuid@'))
            result = subprocess.run(args, input=parser, text=True, capture_output=True, env=env, encoding='utf-8')
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads((folder/'config.json').read_text()), node)

    def test_native_subscription_matches_share_link(self):
        bash = executable('bash')
        if not bash:
            self.skipTest('bash is required')
        for script in SCRIPTS:
            with self.subTest(script=script), tempfile.TemporaryDirectory() as tmp:
                folder = Path(tmp)
                source = (ROOT / script).read_text(encoding='utf-8')
                function = 'write_client_routing_files() {' + source.split(
                    'write_client_routing_files() {', 1)[1].split('\nis_truthy() {', 1)[0]
                function = function.replace('/etc/xray/clash-sub.env', (folder/'sub.env').as_posix())
                link = ('vless://11111111-1111-4111-8111-111111111111@203.0.113.10:52300'
                        '?encryption=none&flow=xtls-rprx-vision&security=reality'
                        '&sni=example.com&fp=chrome&pbk=' + 'A'*43
                        + '&sid=0000000000000010&type=tcp#Reality')
                values = dict(
                    CLASH_FILE=(folder/'clash.yaml').as_posix(),
                    XRAY_CLIENT_FILE=(folder/'client.json').as_posix(),
                    V2RAYN_SUB_FILE=(folder/'vless.txt').as_posix(),
                    SHARE_FILE=(folder/'share.txt').as_posix(),
                    SHARE_LINK=link, CLEAR_IP='203.0.113.10', PORT='52300',
                    USER_UUID='11111111-1111-4111-8111-111111111111',
                    SNI='example.com', PUB_KEY='A'*43, SHORT_ID='0000000000000010',
                    CLASH_SUB_PORT='58472', CLASH_SUB_TOKEN='test-token',
                    CLASH_SUB_HOST='sub.example.com', CLASH_SUB_TLS_CERT='', CLASH_SUB_TLS_KEY='')
                assignments = '\n'.join(k+'='+shlex.quote(v) for k, v in values.items())
                runner = ('set -eu\n' + ('PATH=/usr/bin:$PATH\n' if os.name == 'nt' else '') + assignments + '\n'
                          + 'error_exit() { echo "$*" >&2; exit 1; }\n' + function
                          + '\nwrite_client_routing_files\n'
                          + 'printf "%s" "$V2RAYN_SUB_URL"\n')
                result = subprocess.run([bash], input=runner, text=True, capture_output=True,
                                        encoding='utf-8')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(base64.b64decode((folder/'vless.txt').read_bytes()).decode(), link+'\n')
                self.assertIn('http://sub.example.com:58472/test-token/vless.txt', result.stdout)
                yaml = (folder/'clash.yaml').read_text(encoding='utf-8')
                self.assertIn('server: 203.0.113.10', yaml)
                self.assertIn('short-id: "0000000000000010"', yaml)
                self.assertEqual(yaml.count('    format: text\n'), 15)
                self.assertEqual(json.loads((folder/'client.json').read_text())['outbounds'][0]
                                 ['settings']['vnext'][0]['address'], '203.0.113.10')

    def test_http_and_https_routes(self):
        openssl = executable('openssl')
        for script in SCRIPTS:
            for secure in (False, True):
                if secure and not openssl:
                    continue
                with self.subTest(script=script, secure=secure), tempfile.TemporaryDirectory() as tmp:
                    folder = Path(tmp)
                    source = (ROOT/script).read_text(encoding='utf-8')
                    server = source.split("<< 'PY'\n", 1)[1].split('\nPY\n', 1)[0]
                    server = server.replace('/etc/xray/clash-sub.env', (folder/'sub.env').as_posix())
                    (folder/'server.py').write_text(server, encoding='utf-8')
                    yaml_data = b'proxies: []\n'
                    native_data = base64.b64encode(b'vless://fixture\n') + b'\n'
                    (folder/'clash.yaml').write_bytes(yaml_data)
                    (folder/'vless.txt').write_bytes(native_data)
                    cert = folder/'cert.pem'
                    key = folder/'key.pem'
                    if secure:
                        subprocess.run([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                                        '-keyout', str(key), '-out', str(cert), '-days', '1',
                                        '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'],
                                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    with socket.socket() as sock:
                        sock.bind(('127.0.0.1', 0))
                        port = sock.getsockname()[1]
                    env = dict(CLASH_SUB_PORT=port, CLASH_SUB_TOKEN='fixture-token',
                               CLASH_SUB_FILE=(folder/'clash.yaml').as_posix(),
                               V2RAYN_SUB_FILE=(folder/'vless.txt').as_posix(),
                               CLASH_SUB_TLS_CERT=cert.as_posix() if secure else '',
                               CLASH_SUB_TLS_KEY=key.as_posix() if secure else '')
                    (folder/'sub.env').write_text('\n'.join(f'{k}={v}' for k, v in env.items()))
                    context = ssl.create_default_context(cafile=str(cert)) if secure else None
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                                         urllib.request.HTTPSHandler(context=context))
                    url = f'{"https" if secure else "http"}://localhost:{port}'
                    process = subprocess.Popen([sys.executable, str(folder/'server.py')],
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    try:
                        for attempt in range(50):
                            try:
                                with opener.open(url+'/fixture-token/clash.yaml', timeout=1) as response:
                                    self.assertEqual(response.read(), yaml_data)
                                break
                            except urllib.error.URLError:
                                if process.poll() is not None:
                                    self.fail('subscription server exited')
                                time.sleep(0.05)
                        else:
                            self.fail('subscription server did not start')
                        with opener.open(url+'/fixture-token/vless.txt?update=1', timeout=2) as response:
                            self.assertEqual(response.read(), native_data)
                            self.assertEqual(response.headers.get_content_type(), 'text/plain')
                            self.assertEqual(response.headers['Cache-Control'], 'no-store')
                        with self.assertRaises(urllib.error.HTTPError) as error:
                            opener.open(url+'/wrong-token/vless.txt', timeout=2)
                        self.assertEqual(error.exception.code, 404)
                        if secure:
                            untrusted = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                            with self.assertRaises(urllib.error.URLError):
                                untrusted.open(url+'/fixture-token/vless.txt', timeout=2)
                    finally:
                        process.terminate()
                        process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
