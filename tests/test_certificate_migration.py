"""Real encrypted certificate migration, with isolated files and no network."""
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import unittest

import test_https_setup as https
from test_subscription import ROOT, SCRIPTS, executable


def bundle_program():
    return https.wizard_source(SCRIPTS[0]).split(
        'subscription_certificate_bundle() {', 1)[1].split(
            "<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]


class CertificateMigrationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.openssl = executable('openssl')
        if not cls.openssl or not executable('bash'):
            raise unittest.SkipTest('openssl and bash required')
        cls.fixtures = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.fixtures.cleanup)
        folder = Path(cls.fixtures.name)
        cls.ca, cls.key, cls.cert = folder/'ca.pem', folder/'key.pem', folder/'fullchain.pem'
        root_key, csr, leaf = folder/'ca.key', folder/'leaf.csr', folder/'leaf.pem'
        def openssl(*args):
            subprocess.run([cls.openssl, *map(str, args)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        openssl('req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
                '-nodes', '-keyout', root_key, '-out', cls.ca, '-days', '3',
                '-subj', '/CN=Migration Test CA', '-addext', 'basicConstraints=critical,CA:TRUE')
        openssl('req', '-new', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1',
                '-nodes', '-keyout', cls.key, '-out', csr, '-subj', '/CN=sub.example.com')
        extensions = folder/'extensions.cnf'
        extensions.write_text('subjectAltName=DNS:other.example.com,DNS:sub.example.com\n'
                              'extendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n')
        openssl('x509', '-req', '-in', csr, '-CA', cls.ca, '-CAkey', root_key,
                '-CAcreateserial', '-out', leaf, '-days', '3', '-extfile', extensions)
        cls.cert.write_bytes(leaf.read_bytes()+cls.ca.read_bytes())

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = Path(self.tmp.name)
        self.bundle = self.folder/'sub-cert.p12'
        self.destination = self.folder/'tls'
        self.env = dict(os.environ, CERT_BUNDLE_PASSWORD='fixture-password-123',
                        SSL_CERT_FILE=str(self.ca), PYTHONIOENCODING='utf-8',
                        PATH=str(Path(self.openssl).parent)+os.pathsep+os.environ.get('PATH', ''))

    def operation(self, action, host='sub.example.com', **kwargs):
        cert = self.cert if action == 'export' else self.destination
        args = [sys.executable, '-', action, str(self.bundle), host, str(cert), str(self.key)]
        return subprocess.run(args, input=bundle_program(), text=True, encoding='utf-8',
                              capture_output=True, env=kwargs.get('env', self.env), timeout=30)

    def export(self):
        result = self.operation('export')
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.bundle.read_bytes()

    def test_encrypted_roundtrip_preserves_chain_private_key_and_domain(self):
        data = self.export()
        self.assertNotIn(b'PRIVATE KEY', data)
        # Export output cannot be opened without the correct password.
        probe = subprocess.run([self.openssl, 'pkcs12', '-in', str(self.bundle),
                                '-noout', '-passin', 'stdin'], input=b'wrong-password\n',
                               capture_output=True)
        self.assertNotEqual(probe.returncode, 0)
        result = self.operation('import', host='')
        self.assertEqual(result.returncode, 0, result.stderr)
        host, cert, key = result.stdout.splitlines()
        # The first SAN differs: our exact export hostname must survive.
        self.assertEqual(host, 'sub.example.com')
        self.assertEqual(Path(cert).read_bytes().count(b'BEGIN CERTIFICATE'), 2)
        ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER).load_cert_chain(cert, key)
        def public_key(path, cert=False):
            return subprocess.check_output([self.openssl, 'x509' if cert else 'pkey',
                                            '-in', str(path), '-pubkey' if cert else '-pubout',
                                            *(['-noout'] if cert else [])])
        self.assertEqual(public_key(self.key), public_key(key))
        self.assertEqual(public_key(self.key), public_key(cert, cert=True))
        if os.name != 'nt':
            self.assertEqual(self.bundle.stat().st_mode & 0o777, 0o600)
            self.assertEqual(Path(key).stat().st_mode & 0o777, 0o600)
            self.assertEqual(Path(cert).parent.stat().st_mode & 0o777, 0o700)

    def test_wrong_password_tampering_mismatch_and_untrusted_fail_before_writes(self):
        original = self.export()
        self.destination.mkdir()
        sentinel = self.destination/'working.pem'
        sentinel.write_text('unchanged')
        scenarios = [
            ('password', dict(self.env, CERT_BUNDLE_PASSWORD='incorrect-password'), 'sub.example.com', original),
            ('domain', self.env, 'wrong.example.com', original),
            ('corrupt', self.env, 'sub.example.com', original[:120]),
            ('untrusted', {k:v for k,v in self.env.items() if k != 'SSL_CERT_FILE'}, 'sub.example.com', original),
        ]
        for name, env, host, data in scenarios:
            with self.subTest(name=name):
                self.bundle.write_bytes(data)
                result = self.operation('import', host=host, env=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(self.destination.iterdir()), [sentinel])
                self.assertEqual(sentinel.read_text(), 'unchanged')
                self.assertNotIn('fixture-password-123', result.stdout+result.stderr)
                self.assertNotIn('PRIVATE KEY', result.stdout+result.stderr)

    def test_refuses_overwrite_and_creates_unique_validated_imports(self):
        original = self.export()
        result = self.operation('export')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.bundle.read_bytes(), original)
        first = self.operation('import')
        second = self.operation('import')
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotEqual(first.stdout.splitlines()[1], second.stdout.splitlines()[1])
        self.assertEqual(len(list(self.destination.iterdir())), 2)

    def test_password_requirements(self):
        for value in ('short', 'abcdefgh\ninject', 'abcdefgh\r'):
            with self.subTest(value=value):
                result = self.operation('export', env=dict(self.env, CERT_BUNDLE_PASSWORD=value))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.bundle.exists())

    def test_expired_certificate_rejected_before_publication(self):
        leaf = self.folder/'expired.pem'
        subprocess.run([self.openssl, 'x509', '-in', str(self.cert), '-signkey', str(self.key),
                        '-days', '0', '-out', str(leaf)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        secret = b'fixture-password-123\n'
        subprocess.run([self.openssl, 'pkcs12', '-export', '-in', str(leaf),
                        '-inkey', str(self.key), '-out', str(self.bundle), '-passout', 'stdin'],
                       input=secret, check=True, capture_output=True)
        result = self.operation('import', env=dict(self.env, SSL_CERT_FILE=str(leaf)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.destination.exists())

    def test_export_wrapper_reads_saved_settings_without_executing_them(self):
        saved = self.folder/'sub.env'
        marker = self.folder/'injected'
        saved.write_text('CLASH_SUB_HOST=sub.example.com\n'
                         'CLASH_SUB_TLS_CERT='+self.cert.as_posix()+'\n'
                         'CLASH_SUB_TLS_KEY='+self.key.as_posix()+'\n'
                         'OTHER=$(touch '+marker.as_posix()+')\n', encoding='utf-8')
        source = https.wizard_source(SCRIPTS[0]).replace('/etc/xray/clash-sub.env', saved.as_posix())
        harness = https.HttpsSetupTest()
        harness.folder, harness.cert = self.folder, self.ca
        result = harness.run_shell('''
id() { printf 0; }
export CERT_BUNDLE_PASSWORD
subscription_export_certificate "$TEST_BUNDLE"
''', dict(TEST_BUNDLE=self.bundle.as_posix(), CERT_BUNDLE_PASSWORD='fixture-password-123'), source)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertTrue(self.bundle.exists())
        self.assertFalse(marker.exists())

    def test_wizard_import_uses_bundle_and_never_requests_acme(self):
        self.export()
        harness = https.HttpsSetupTest()
        harness.folder = self.folder
        harness.cert = self.ca
        source = https.wizard_source(SCRIPTS[0]).replace('/etc/xray/tls', self.destination.as_posix())
        result = harness.run_shell('''
subscription_setup_cloudflare() { echo unexpected-acme >&2; exit 98; }
export CERT_BUNDLE_PASSWORD
configure_subscription_https
printf 'RESULT=%s\\n' "$CLASH_SUB_HOST" "$CLASH_SUB_TLS_CERT" "$CLASH_SUB_TLS_KEY"
''', dict(CLASH_SUB_CERT_BUNDLE=self.bundle.as_posix(), CERT_BUNDLE_PASSWORD='fixture-password-123'), source)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('RESULT=sub.example.com', result.stdout)
        self.assertIn('subscription-update.sh --https', result.stdout)
        self.assertNotIn('unexpected-acme', result.stdout+result.stderr)

    def test_installer_export_exits_before_installation(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                source = (ROOT/script).read_text(encoding='utf-8')
                dispatch = source.split('# Certificate export exits before installation', 1)[1].split('\n', 1)[1].split(
                    '\n# 0.5 ' if script.startswith('debian') else '\n# 1. ', 1)[0]
                target = self.folder/'dispatch.sh'
                target.write_text('''set -eu
subscription_export_certificate() { printf '%s' "$1"; }
error_exit() { exit 1; }
'''+dispatch+'\necho UNEXPECTED_INSTALL\n', encoding='utf-8', newline='\n')
                result = subprocess.run([executable('bash'), target.as_posix(), '--export-cert',
                                         '/root/backup.p12'], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, '/root/backup.p12')


if __name__ == '__main__':
    unittest.main()
