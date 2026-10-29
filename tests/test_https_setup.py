"""Offline coverage for the HTTPS wizard; ACME and init commands are mocked."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

from test_subscription import ROOT, SCRIPTS, executable


def wizard_source(script):
    source = (ROOT/script).read_text(encoding='utf-8')
    return source.split('# BEGIN subscription HTTPS wizard', 1)[1].split('\n', 1)[1].split(
        '# END subscription HTTPS wizard', 1)[0]


class HttpsSetupTest(unittest.TestCase):
    def setUp(self):
        if not executable('bash') or not executable('openssl'):
            self.skipTest('bash and openssl are required')
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        self.key = self.folder/'fixture-key.pem'
        self.cert = self.folder/'fixture-cert.pem'
        subprocess.run([executable('openssl'), 'req', '-x509', '-newkey', 'rsa:2048',
                        '-nodes', '-keyout', str(self.key), '-out', str(self.cert),
                        '-days', '3', '-subj', '/CN=sub.example.com',
                        '-addext', 'subjectAltName=DNS:sub.example.com'], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def run_shell(self, code, values=None, source=None):
        env = os.environ.copy()
        for name in ('CF_Token', 'CLASH_SUB_HTTPS', 'CLASH_SUB_HOST', 'CLASH_SUB_PUBLIC_PORT',
                     'CLASH_SUB_TLS_CERT', 'CLASH_SUB_TLS_KEY'):
            env.pop(name, None)
        env.update(SSL_CERT_FILE=self.cert.as_posix(), PYTHONIOENCODING='utf-8')
        assignments = dict(CLASH_SUB_PORT='58472', PORT='52300', CLEAR_IP='203.0.113.10')
        assignments.update(values or {})
        runner = ('set -eu\n' + ('PATH=/usr/bin:$PATH\n' if os.name == 'nt' else '')
                  + 'python3() { '+shlex.quote(Path(sys.executable).as_posix())+' "$@"; }\n'
                  + '\n'.join(k+'='+shlex.quote(v) for k, v in assignments.items())
                  + '\nerror_exit() { echo "$*" >&2; exit 1; }\n'
                  + (source if source is not None else wizard_source(SCRIPTS[0]))
                  + '\n'+code+'\n')
        runner_file = self.folder/'runner.sh'
        runner_file.write_text(runner, encoding='utf-8', newline='\n')
        return subprocess.run([executable('bash'), runner_file.as_posix()], text=True,
                              capture_output=True, encoding='utf-8', env=env, timeout=30)

    def test_standalone_installers_share_wizard_and_call_it(self):
        self.assertEqual(wizard_source(SCRIPTS[0]), wizard_source(SCRIPTS[1]))
        for name in SCRIPTS:
            source = (ROOT/name).read_text(encoding='utf-8')
            self.assertIn('\nconfigure_subscription_https\nwrite_client_routing_files\n'
                          'start_clash_sub_service\nsubscription_verify_local\n', source)

    def test_noninteractive_default_keeps_http_and_explicit_https_needs_domain(self):
        result = self.run_shell('configure_subscription_https\nprintf "%s" "$CLASH_SUB_HTTPS"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.endswith('off'))
        result = self.run_shell('configure_subscription_https', {'CLASH_SUB_HTTPS': 'cloudflare'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CLASH_SUB_HOST', result.stderr)

    def test_existing_certificate_checks_hostname_trust_and_private_key(self):
        values = dict(CLASH_SUB_HOST='sub.example.com', CLASH_SUB_PUBLIC_PORT='58473',
                      CLASH_SUB_TLS_CERT=self.cert.as_posix(), CLASH_SUB_TLS_KEY=self.key.as_posix())
        result = self.run_shell('configure_subscription_https\nprintf "%s" "$CLASH_SUB_PUBLIC_PORT"', values)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.endswith('58473'))
        # A valid key pair must still fail when the hostname does not match.
        result = self.run_shell('configure_subscription_https', {**values, 'CLASH_SUB_HOST': 'wrong.example.com'})
        self.assertNotEqual(result.returncode, 0)
        # The same self-signed certificate fails when it is not in the trust store.
        result = self.run_shell('unset SSL_CERT_FILE\nconfigure_subscription_https', values)
        self.assertNotEqual(result.returncode, 0)
        result = self.run_shell('configure_subscription_https', {**values, 'CLASH_SUB_TLS_KEY': self.cert.as_posix()})
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_malformed_host_and_ports_and_tls_downgrade(self):
        for values in ({'CLASH_SUB_HOST': 'https://sub.example.com'},
                       {'CLASH_SUB_PORT': '52300'}, {'CLASH_SUB_PUBLIC_PORT': '65536'},
                       {'CLASH_SUB_HOST': 'sub.example.com\nINJECT=value'},
                       {'CLASH_SUB_PORT': '5x'}):
            with self.subTest(values=values):
                result = self.run_shell('configure_subscription_https', {'CLASH_SUB_HTTPS': 'off', **values})
                self.assertNotEqual(result.returncode, 0)
        result = self.run_shell('configure_subscription_https',
                                {'CLASH_SUB_HTTPS': 'off', 'CLASH_SUB_TLS_CERT': self.cert.as_posix()})
        self.assertNotEqual(result.returncode, 0)

    def test_cloudflare_issuance_reuse_failure_and_renewal_registration(self):
        acme_home = self.folder/'acme'
        acme_home.mkdir()
        acme = acme_home/'acme.sh'
        acme.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$TEST_LOG"
case "$1" in
    --issue) exit "$TEST_ISSUE_STATUS" ;;
    --install-cert)
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --key-file) shift; cp "$TEST_KEY" "$1" ;;
                --fullchain-file) shift; cp "$TEST_CERT" "$1" ;;
            esac
            shift
        done ;;
    *) exit 1 ;;
esac
''', encoding='utf-8', newline='\n')
        source = wizard_source(SCRIPTS[0]).replace('/root/.acme.sh', acme_home.as_posix()).replace(
            '/etc/xray/tls', (self.folder/'tls').as_posix())
        mocks = '''
subscription_install_acme() { echo acme-ready >> "$TEST_LOG"; }
subscription_write_reload_hook() { echo reload-hook >> "$TEST_LOG"; }
subscription_schedule_renewal() { echo renewal-scheduled >> "$TEST_LOG"; }
export TEST_LOG TEST_CERT TEST_KEY TEST_ISSUE_STATUS
configure_subscription_https
'''
        for status in ('0', '2', '1'):
            log = self.folder/('calls-'+status)
            values = dict(CLASH_SUB_HTTPS='cloudflare', CLASH_SUB_HOST='sub.example.com',
                          CF_Token='fixture-secret-token', TEST_LOG=log.as_posix(),
                          TEST_CERT=self.cert.as_posix(), TEST_KEY=self.key.as_posix(),
                          TEST_ISSUE_STATUS=status)
            result = self.run_shell(mocks, values, source)
            self.assertTrue(log.exists(), result.stdout+result.stderr)
            calls = log.read_text()
            self.assertNotIn('fixture-secret-token', result.stdout+result.stderr+calls)
            if status == '1':
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('--install-cert', calls)
                self.assertNotIn('renewal-scheduled', calls)
                self.assertIn('subscription-update.sh --https', result.stderr)
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('--dns dns_cf', calls)
                self.assertIn('--server letsencrypt', calls)
                self.assertNotIn('--force', calls)
                self.assertIn('--install-cert', calls)
                self.assertIn('--reloadcmd /usr/local/bin/xray-sub-cert-reload', calls)
                self.assertIn('renewal-scheduled', calls)

    def test_renewal_schedulers_for_systemd_and_alpine(self):
        for alpine in (False, True):
            folder = self.folder/('alpine' if alpine else 'debian')
            folder.mkdir()
            marker = folder/'alpine-release'
            if alpine:
                marker.touch()
            source = wizard_source(SCRIPTS[0]).replace('/etc/alpine-release', marker.as_posix()).replace(
                '/etc/systemd/system', folder.as_posix()).replace('/etc/periodic/daily', folder.as_posix())
            log = folder/'init-calls'
            mocks = '''
systemctl() { echo "systemctl $*" >> "$TEST_LOG"; }
rc-update() { echo "rc-update $*" >> "$TEST_LOG"; }
rc-service() { echo "rc-service $*" >> "$TEST_LOG"; }
subscription_schedule_renewal
'''
            result = self.run_shell(mocks, {'TEST_LOG': log.as_posix()}, source)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = log.read_text()
            if alpine:
                self.assertIn('rc-service crond start', calls)
                self.assertIn('--cron --home /root/.acme.sh', (folder/'xray-sub-renew').read_text())
            else:
                self.assertIn('enable --now xray-sub-renew.timer', calls)
                self.assertIn('Persistent=true', (folder/'xray-sub-renew.timer').read_text())
                self.assertIn('--cron --home /root/.acme.sh', (folder/'xray-sub-renew.service').read_text())


if __name__ == '__main__':
    unittest.main()
