"""Linux integration: temporary Xray WS and subscription processes; no live service edits.

Run as a user able to read existing Xray templates:
    python3 tests/integration_tunnel.py [path/to/xray.sh]
"""
import base64
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
from urllib.parse import parse_qs, urlsplit


def main():
    os.umask(0o077)
    source = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'xray.sh').read_text()
    root = Path('/etc/xray')
    names = ['config.json', 'clash-sub.env', 'clash-meta.yaml', 'xray-client.json', 'v2rayn.txt']
    baseline = {name: hashlib.sha256((root/name).read_bytes()).digest() for name in names}
    processes = []
    logs = []

    def block(function):
        return re.search(r"<<\s*'PY'\n(.*?)\nPY", source.split(function+'() {', 1)[1], re.S)[1]

    def run(args, **kwargs):
        result = subprocess.run(args, capture_output=True, text=True, timeout=40, **kwargs)
        if result.returncode:
            raise AssertionError('Subprocess failed: '+str(args[0])+'; private output omitted')
        return result.stdout

    def wait(port):
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.2):
                    return
            except OSError:
                time.sleep(.05)
        raise AssertionError('Temporary listener did not become ready')

    with tempfile.TemporaryDirectory(prefix='xray-tunnel-validation-') as tmp:
        folder = Path(tmp)
        sockets = []
        try:
            for _ in range(5):
                probe = socket.socket()
                probe.bind(('127.0.0.1', 0))
                sockets.append(probe)
            ports = [v.getsockname()[1] for v in sockets]
        finally:
            for probe in sockets:
                probe.close()
        ws, sub, metrics, socks, unused = ports
        cfg = json.loads((root/'config.json').read_text())
        cfg['inbounds'] = []
        cfg['log'] = {'loglevel': 'warning'}
        (folder/'config.json').write_text(json.dumps(cfg))
        (folder/'clash-sub.env').write_text(f'CLASH_SUB_PORT={unused}\nCLASH_SUB_TOKEN=integration-only-token\n')
        stage = folder/'stage'
        stage.mkdir()
        env = {**os.environ, 'TUNNEL_NODE_HOST': 'node.example.com', 'TUNNEL_SUB_HOST': 'sub.example.com',
            'TUNNEL_WS_PORT': str(ws), 'TUNNEL_SUB_PORT': str(sub), 'TUNNEL_METRICS_PORT': str(metrics),
            'TUNNEL_WS_PATH': '/integration-ws'}
        run([sys.executable, '-c', block('tunnel_stage'), str(folder/'config.json'),
            str(folder/'tunnel.json'), str(folder/'clash-sub.env'), str(stage), 'enable'], env=env)
        (folder/'tunnel.json').write_bytes((stage/'tunnel.json').read_bytes())
        for name in ['clash-meta.yaml', 'xray-client.json', 'v2rayn.txt']:
            (folder/name).write_bytes((root/name).read_bytes())
        code = block('write_clash_sub_httpd').replace('/etc/xray/', str(folder)+'/')
        (folder/'server.py').write_text(code)
        binary = '/usr/local/bin/xray'
        run([binary, 'run', '-test', '-c', str(stage/'config.json')])

        def launch(args, logname, env=None):
            log = open(folder/logname, 'w')
            logs.append(log)
            proc = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, env=env)
            processes.append(proc)
            return proc

        def request(path, port=sub, headers=None):
            conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
            try:
                conn.request('GET', path, headers=headers or {})
                reply = conn.getresponse()
                return reply.status, b'' if reply.status == 101 else reply.read()
            finally:
                conn.close()

        try:
            launch([binary, 'run', '-c', str(stage/'config.json')], 'ws-server.log')
            wait(ws)
            subscription = launch([sys.executable, str(folder/'server.py')], 'subscription.log',
                {**os.environ, 'XRAY_SUB_TUNNEL': '1'})
            wait(sub)
            run([sys.executable, '-c', block('tunnel_health'), str(folder/'tunnel.json'),
                 str(folder/'clash-sub.env'), 'subscription'])
            print('PASS subscription readiness without requiring a Cloudflare connection', flush=True)
            headers = {'Host': 'node.example.com', 'Connection': 'Upgrade', 'Upgrade': 'websocket',
                'Sec-WebSocket-Version': '13', 'Sec-WebSocket-Key': base64.b64encode(os.urandom(16)).decode()}
            assert request('/integration-ws', ws, headers)[0] == 101
            assert request('/wrong-path', ws, headers)[0] != 101
            print('PASS actual Xray WebSocket upgrade and path rejection', flush=True)
            status, yaml = request('/integration-only-token/clash.yaml')
            assert status == 200 and b'network: ws' in yaml and b'node.example.com' in yaml
            assert b'reality-opts:' not in yaml and b'flow: xtls-rprx-vision' not in yaml
            assert request('/wrong-token/clash.yaml')[0] == 404
            status, data = request('/integration-only-token/vless.txt')
            assert status == 200
            link = urlsplit(base64.b64decode(data).decode().strip())
            assert parse_qs(link.query)['path'] == ['/integration-ws']
            status, data = request('/integration-only-token/xray.json')
            assert status == 200
            client = json.loads(data)
            outbound = next(v for v in client['outbounds'] if v.get('protocol') == 'vless')
            assert outbound['streamSettings']['security'] == 'tls'
            print('PASS Clash, native VLESS, Xray subscriptions and token rejection', flush=True)
            # Exercise WS transport locally; TLS termination belongs to Cloudflare and is not simulated here.
            outbound['settings']['vnext'][0].update(address='127.0.0.1', port=ws)
            outbound['streamSettings']['security'] = 'none'
            outbound['streamSettings'].pop('tlsSettings')
            client = {'log': {'loglevel': 'warning'}, 'inbounds': [{'listen': '127.0.0.1', 'port': socks,
                'protocol': 'socks', 'settings': {'auth': 'noauth'}}], 'outbounds': [outbound]}
            (folder/'client.json').write_text(json.dumps(client))
            run([binary, 'run', '-test', '-c', str(folder/'client.json')])
            launch([binary, 'run', '-c', str(folder/'client.json')], 'ws-client.log')
            wait(socks)
            address = run(['curl', '-fsS', '--connect-timeout', '8', '--max-time', '25',
                '--socks5-hostname', '127.0.0.1:'+str(socks), 'https://api.ipify.org'])
            ipaddress.ip_address(address.strip())
            print('PASS real VLESS WebSocket handshake and HTTPS proxy egress', flush=True)
            subscription.terminate()
            subscription.wait(timeout=10)
            (folder/'clash-sub.env').write_text(f'CLASH_SUB_PORT={unused}\nCLASH_SUB_TOKEN=rotated-integration-token\n')
            launch([sys.executable, str(folder/'server.py')], 'subscription-rotated.log',
                {**os.environ, 'XRAY_SUB_TUNNEL': '1'})
            wait(sub)
            assert request('/integration-only-token/clash.yaml')[0] == 404
            assert request('/rotated-integration-token/clash.yaml')[0] == 200
            print('PASS subscription token rotation', flush=True)
        finally:
            for proc in reversed(processes):
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=5)
            for log in logs:
                log.close()
        for name, digest in baseline.items():
            assert hashlib.sha256((root/name).read_bytes()).digest() == digest, 'Live file changed: '+name
        print('PASS existing VPS files preserved; temporary processes and credentials removed', flush=True)
    print('COMPLETE: local integration passed; real Cloudflare tunnel and public TLS routes not tested', flush=True)


if __name__ == '__main__':
    main()
