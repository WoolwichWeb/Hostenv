#!/usr/bin/env python3
"""Local, unprivileged checks for the endpoint runtime (not a systemd VM test)."""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = os.environ.get('HOSTENV_SYSTEM_TEST_BINARY', 'hostenv-system')
PYTHON = shutil.which('python3') or sys.executable
SYSTEMD_ACTIVATE = shutil.which('systemd-socket-activate')
PROXY = os.environ.get('HOSTENV_TEST_SOCKET_PROXY', '/usr/lib/systemd/systemd-socket-proxyd')
UID = 65534 if os.getuid() == 0 else os.getuid()
GID = 65534 if os.getuid() == 0 else os.getgid()


def as_tenant() -> dict:
    return {'user': UID, 'group': GID, 'extra_groups': [], 'umask': 0o077} if os.getuid() == 0 else {'umask': 0o077}



class EndpointRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='hostenv-endpoint-')
        self.base = Path(self.temp.name)
        os.chmod(self.base, 0o755)
        self.state = self.base / 'tenant'
        self.state.mkdir(mode=0o700)
        if os.getuid() == 0:
            os.chown(self.state, UID, GID)
        self.processes = []
        self.logs = []

    def tearDown(self):
        for process in reversed(self.processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
        for log in self.logs:
            log.close()
        self.temp.cleanup()

    def run_tenant(self, command, **kwargs):
        return subprocess.run(command, capture_output=True, text=True,
                              timeout=12, **as_tenant(), **kwargs)

    def start(self, command, name):
        log = open(self.base / (name + '.log'), 'w+')
        self.logs.append(log)
        process = subprocess.Popen(command, stdout=log, stderr=log, **as_tenant())
        self.processes.append(process)
        return process, log

    def wait_file(self, path, process=None):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists():
                return
            if process and process.poll() is not None:
                break
            time.sleep(.03)
        self.fail(f'{path} did not appear; logs: ' + self.read_logs())

    def read_logs(self):
        parts = []
        for log in self.logs:
            log.flush(); log.seek(0)
            parts.append(log.read())
        return '\n'.join(parts)

    def backend(self, ports=(3000, 3001)):
        source = self.base / 'backend.py'
        source.write_text('''import os, selectors, socket, sys
from pathlib import Path
state = Path(sys.argv[1])
sel = selectors.DefaultSelector()
for text in sys.argv[2:]:
    port = int(text)
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port)); listener.listen()
    sel.register(listener, selectors.EVENT_READ, port)
(state / 'owner-ns').write_text(os.readlink('/proc/self/ns/net'))
(state / 'ready').touch()
while True:
    for key, _ in sel.select():
        connection, _ = key.fileobj.accept()
        with connection:
            connection.settimeout(2)
            data = b''
            while b"\\r\\n\\r\\n" not in data:
                chunk = connection.recv(4096)
                if not chunk: break
                data += chunk
            body = (str(key.data) + "\\n").encode()
            connection.sendall(b"HTTP/1.1 200 OK\\r\\nContent-Length: " + str(len(body)).encode() + b"\\r\\nConnection: close\\r\\n\\r\\n" + body)
''')
        isolate = self.base / 'isolate.sh'
        isolate.write_text('#!/bin/sh\nset -eu\n' + shutil.which('ip') + ' link set lo up\nexec ' +
                           shutil.which('setpriv') + ' --bounding-set=-all --inh-caps=-all --ambient-caps=-all "$@"\n')
        isolate.chmod(0o755)
        process, _ = self.start([shutil.which('unshare'), '--user', '--map-current-user',
                                 '--keep-caps', '--net', str(isolate), PYTHON, '-I', '-S',
                                 str(source), str(self.state), *map(str, ports)], 'owner')
        self.wait_file(self.state / 'ready', process)
        return process

    def manifest(self, owner, name='default', port=3000):
        control = self.base / 'systemctl-test'
        control.write_text(f"#!/bin/sh\nprintf 'MainPID={owner}\nActiveState=active\n'\n")
        control.chmod(0o755)
        data = dict(owner='fixture.service', name=name, runtime_dir=str(self.state),
                    socket=str(self.state / ('fixture.sock' if name == 'default' else f'fixture/{name}.sock')),
                    descriptor='fixture-' + name, port=port, systemctl=str(control),
                    nsenter=shutil.which('nsenter'), setpriv=shutil.which('setpriv'),
                    proxy=PROXY)
        manifest = self.base / (name + '.json')
        manifest.write_text(json.dumps(data))
        return manifest, data

    def endpoint(self, manifest, data):
        prepared = self.run_tenant([RUNTIME, 'endpoint', 'prepare', str(manifest)])
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        process, _ = self.start([SYSTEMD_ACTIVATE, '--listen=' + data['socket'],
                                 '--fdname=' + data['descriptor'], RUNTIME, 'endpoint', 'serve', str(manifest), '--timeout=2'], data['name'])
        self.wait_file(Path(data['socket']), process)
        return process

    def request(self, data):
        return self.run_tenant([shutil.which('curl'), '--noproxy', '*', '--fail', '--silent',
                                '--show-error', '--max-time', '5', '--unix-socket', data['socket'],
                                'http://localhost/'])

    def test_paths_reject_escape_and_length(self):
        manifest, data = self.manifest(os.getpid())
        cases = [
            ('traversal', '/run/test', '/run/test/../outside.sock', 'must be absolute, normalised'),
            ('relative root', 'relative', '/run/a', 'must be absolute, normalised'),
            ('unnormalised root', '/run/../test', '/run/test/foo.sock', 'must be absolute, normalised'),
            ('sibling path', '/run/test', '/run/testing/foo.sock', 'must be inside'),
            ('runtime directory itself', '/run/test', '/run/test', 'must be inside'),
            ('path too long', '/run/test', '/run/test/' + 'a'*108, 'at most 107 bytes'),
        ]
        for description, root, path, message in cases:
            with self.subTest(description=description):
                manifest.write_text(json.dumps(dict(data, runtime_dir=root, socket=path)))
                result = self.run_tenant([RUNTIME, 'endpoint', 'prepare', str(manifest)])
                self.assertNotEqual(result.returncode, 0, (root, path))
                self.assertIn('invalid endpoint manifest:', result.stderr)
                self.assertIn(message, result.stderr)

    def test_prepare_accepts_provider_setgid_runtime_directory(self):
        # The provider's tmpfiles rule uses mode 2700 for this directory.
        # Linux normally propagates its setgid bit to new subdirectories.
        os.chmod(self.state, 0o2700)
        for name in ('default', 'api'):
            manifest, data = self.manifest(os.getpid(), name)
            result = self.run_tenant([RUNTIME, 'endpoint', 'prepare', str(manifest)])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o2700)
            if name == 'api':
                directory = Path(data['socket']).parent
                self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o2700)

    def test_prepare_rejects_unsafe_runtime_directory_modes(self):
        manifest, _ = self.manifest(os.getpid())
        for mode in (0o770, 0o2710, 0o1700, 0o4700, 0o705):
            with self.subTest(mode=oct(mode)):
                os.chmod(self.state, mode)
                result = self.run_tenant([RUNTIME, 'endpoint', 'prepare', str(manifest)])
                self.assertNotEqual(result.returncode, 0, oct(mode))
                self.assertIn('must be owned by its user and private', result.stderr)

    def test_prepare_rejects_unsafe_named_endpoint_directory(self):
        os.chmod(self.state, 0o2700)
        manifest, data = self.manifest(os.getpid(), 'api')
        directory = Path(data['socket']).parent
        directory.mkdir(mode=0o700)
        if os.getuid() == 0:
            os.chown(directory, UID, GID)
        os.chmod(directory, 0o2770)
        result = self.run_tenant([RUNTIME, 'endpoint', 'prepare', str(manifest)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('endpoint directory has unsafe ownership or permissions', result.stderr)

    def test_prepare_refuses_existing_file_and_symlink(self):
        manifest, data = self.manifest(os.getpid())
        target = Path(data['socket'])
        target.write_text('do not delete')
        result = self.run_tenant([RUNTIME, 'endpoint', 'prepare', str(manifest)])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), 'do not delete')
        target.unlink(); target.symlink_to(self.base / 'missing')
        result = self.run_tenant([RUNTIME, 'endpoint', 'prepare', str(manifest)])
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(target.is_symlink())

    def test_prepare_refuses_parent_symlink(self):
        manifest, data = self.manifest(os.getpid(), 'api')
        elsewhere = self.base / 'elsewhere'; elsewhere.mkdir(mode=0o700)
        if os.getuid() == 0: os.chown(elsewhere, UID, GID)
        (self.state / 'fixture').symlink_to(elsewhere, target_is_directory=True)
        result = self.run_tenant([RUNTIME, 'endpoint', 'prepare', str(manifest)])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_missing_socket_activation_fails(self):
        manifest, _ = self.manifest(os.getpid())
        env = dict(os.environ)
        for name in ('LISTEN_PID', 'LISTEN_FDS', 'LISTEN_FDNAMES'): env.pop(name, None)
        result = self.run_tenant([RUNTIME, 'endpoint', 'serve', str(manifest)], env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('socket activation', result.stderr)

    def test_two_exports_reach_their_own_ports(self):
        owner = self.backend()
        first, a = self.manifest(owner.pid)
        second, b = self.manifest(owner.pid, 'admin', 3001)
        proxy_a = self.endpoint(first, a)
        proxy_b = self.endpoint(second, b)
        for data, port in ((a, 3000), (b, 3001), (a, 3000)):
            response = self.request(data)
            self.assertEqual(response.returncode, 0, response.stderr + self.read_logs())
            self.assertEqual(response.stdout, str(port) + '\n')
        for port in (3000, 3001):
            with socket.socket() as host:
                host.settimeout(.3)
                self.assertNotEqual(host.connect_ex(('127.0.0.1', port)), 0)
        self.assertIsNone(owner.poll())
        owner.terminate(); owner.wait(timeout=3)
        self.assertEqual(proxy_a.wait(timeout=8), 0, self.read_logs())
        self.assertEqual(proxy_b.wait(timeout=8), 0, self.read_logs())

    def test_host_namespace_is_refused(self):
        owner, _ = self.start(['/bin/sleep', '20'], 'host-owner')
        manifest, data = self.manifest(owner.pid)
        proxy = self.endpoint(manifest, data)
        response = self.request(data)
        self.assertNotEqual(response.returncode, 0)
        self.assertNotEqual(proxy.wait(timeout=6), 0)
        self.assertIn('has not entered a private network namespace', self.read_logs())

    def test_wrong_descriptor_name_is_refused(self):
        owner = self.backend()
        manifest, data = self.manifest(owner.pid)
        Path(data['socket']).parent.mkdir(exist_ok=True)
        proxy, _ = self.start([SYSTEMD_ACTIVATE, '--listen=' + data['socket'], '--fdname=wrong',
                               RUNTIME, 'endpoint', 'serve', str(manifest)], 'wrong')
        self.wait_file(Path(data['socket']), proxy)
        response = self.request(data)
        self.assertNotEqual(response.returncode, 0)
        self.assertNotEqual(proxy.wait(timeout=3), 0)
        self.assertIn('unexpected listening descriptor name', self.read_logs())

    def test_wrong_socket_path_is_refused(self):
        owner = self.backend()
        manifest, data = self.manifest(owner.pid)
        real_socket = str(self.state / 'wrong.sock')
        proxy, _ = self.start([SYSTEMD_ACTIVATE, '--listen=' + real_socket,
                               '--fdname=' + data['descriptor'], RUNTIME, 'endpoint', 'serve', str(manifest)], 'wrong-path')
        self.wait_file(Path(real_socket), proxy)
        request = self.request(dict(data, socket=real_socket))
        self.assertNotEqual(request.returncode, 0)
        self.assertNotEqual(proxy.wait(timeout=3), 0)
        self.assertIn('not the declared Unix stream listener', self.read_logs())

    def test_invalid_manifest_fields_are_refused(self):
        manifest, data = self.manifest(os.getpid())
        cases = [
            ('owner template', {'owner': 'fixture@.service'}, 'invalid owning unit name'),
            ('owner suffix', {'owner': 'fixture'}, 'invalid owning unit name'),
            ('endpoint path', {'name': '../escape'}, 'invalid endpoint name'),
            ('empty descriptor', {'descriptor': ''}, 'invalid activation descriptor name'),
            ('long descriptor', {'descriptor': 'a' * 256}, 'invalid activation descriptor name'),
            ('descriptor characters', {'descriptor': 'bad name'}, 'invalid activation descriptor name'),
            ('systemctl path', {'systemctl': 'systemctl'}, 'helper executable paths must be absolute'),
            ('nsenter path', {'nsenter': 'nsenter'}, 'helper executable paths must be absolute'),
            ('setpriv path', {'setpriv': 'setpriv'}, 'helper executable paths must be absolute'),
            ('proxy path', {'proxy': 'proxy'}, 'helper executable paths must be absolute'),
            ('NUL in helper path', {'proxy': '/bin/' + chr(0) + 'bad'}, 'helper executable paths must be absolute'),
        ]
        for description, changes, message in cases:
            with self.subTest(description=description):
                manifest.write_text(json.dumps(dict(data, **changes)))
                result = self.run_tenant([RUNTIME, 'endpoint', 'prepare', str(manifest)])
                self.assertNotEqual(result.returncode, 0, changes)
                self.assertIn('invalid endpoint manifest:', result.stderr)
                self.assertIn(message, result.stderr)

    def test_invalid_manifest_port_is_refused(self):
        manifest, data = self.manifest(os.getpid())
        for port in (0, 65536, True, '3000'):
            with self.subTest(port=port):
                manifest.write_text(json.dumps(dict(data, port=port)))
                result = self.run_tenant([RUNTIME, 'endpoint', 'prepare', str(manifest)])
                self.assertNotEqual(result.returncode, 0, port)
                self.assertIn('invalid endpoint manifest:', result.stderr)
                if type(port) is int:
                    self.assertIn('the private TCP port must be between 1 and 65535', result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
