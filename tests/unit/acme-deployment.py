#!/usr/bin/env python3
"""Exercise the ACME guard using real child processes and file locks."""

import fcntl
import json
from contextlib import contextmanager
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

RUNTIME = Path(os.environ["HOSTENV_SYSTEM_TEST_BINARY"])
UNIT = "acme-order-renew-example.test.service"
OTHER = "acme-order-renew-other.test.service"
TRUE = shutil.which("true")
SH = shutil.which("sh")
TOUCH = shutil.which("touch")


@contextmanager
def test_lock(path):
    path.parent.mkdir(mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        yield fd
    finally:
        os.close(fd)


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.manifest = self.root / "manifest.json"
        self.installed = self.root / "installed.json"
        self.lock = self.root / "private/activation.lock"
        # systemd-tmpfiles owns the lifecycle of this directory on NixOS.
        self.lock.parent.mkdir(mode=0o700)
        self.state = self.root / "state.json"
        self.log = self.root / "commands.jsonl"
        self.fake = self.root / "systemctl"
        self.fake.write_text(f'''#!{sys.executable}
import json, pathlib, subprocess, sys
root = pathlib.Path({str(self.root)!r})
args = sys.argv[1:]
with (root / "commands.jsonl").open("a") as f:
    f.write(json.dumps(args) + "\\n")
state = json.loads((root / "state.json").read_text())
if (root / "fail-systemctl").exists():
    print("deliberate systemctl failure", file=sys.stderr)
    sys.exit(1)
unit = args[-1]
if "show" in args:
    props = state.get(unit, {{"LoadState": "not-found"}})
    if (root / "finish-order").exists() and props.get("SubState") == "start":
        props.update(ActiveState="inactive", SubState="dead")
    for key, value in props.items():
        print(key + "=" + value)
elif "stop" in args:
    if (root / "probe-gate").exists():
        result = subprocess.run([
            {str(RUNTIME)!r}, "acme",
            "--manifest", str(root / "manifest.json"),
            "--lock-file", str(root / "private/activation.lock"), "condition", unit,
        ], check=False)
        if result.returncode != 1:
            sys.exit(91)
        (root / "gate-was-held").touch()
    state[unit].update(ActiveState="inactive", SubState="dead")
elif "start" in args:
    if (root / "probe-start-gate").exists():
        import fcntl, os
        lock_fd = os.open(root / "private/activation.lock", os.O_RDONLY)
        try:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                sys.exit(92)
            result = subprocess.run([
                {str(RUNTIME)!r}, "acme",
                "--manifest", str(root / "manifest.json"),
                "--lock-file", str(root / "private/activation.lock"), "condition", unit,
            ], check=False)
            if result.returncode != 0:
                sys.exit(93)
        finally:
            os.close(lock_fd)
        (root / "start-gate-was-held").touch()
    for unit in args[args.index("--") + 1:]:
        state.setdefault(unit, {{"LoadState": "loaded"}}).update(ActiveState="activating", SubState="start")
(root / "state.json").write_text(json.dumps(state))
''')
        self.fake.chmod(0o755)
        self.write_manifest(self.manifest, [UNIT, OTHER])
        self.write_manifest(self.installed, [UNIT])
        self.set_state(UNIT, "activating", "auto-restart")
        self.env = dict(os.environ)
        for key in ("DRY_ACTIVATE", "BOOT", "TEST"):
            self.env.pop(key, None)

    def write_manifest(self, path, units):
        path.write_text(json.dumps({
            "version": 1, "units": units,
            "unitsByHost": {"example.test": [UNIT]} if UNIT in units else {},
        }))

    def set_state(self, unit, active, sub):
        state = json.loads(self.state.read_text()) if self.state.exists() else {}
        state[unit] = {"LoadState": "loaded", "ActiveState": active, "SubState": sub}
        self.state.write_text(json.dumps(state))

    def command(self, *args):
        return [str(RUNTIME), "acme",
                "--manifest", str(self.manifest), "--installed-manifest", str(self.installed),
                "--lock-file", str(self.lock), "--systemctl", str(self.fake), *args]

    def run_guard(self, *args, env=None):
        return subprocess.run(self.command(*args), env=env or self.env,
                              capture_output=True, text=True, timeout=30)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def wait_file(self, path):
        deadline = time.monotonic() + 20
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(path.exists(), f"Timed out waiting for {path}")

    def launch(self, *, wait=True):
        script = self.root / "activation.py"
        script.write_text(f'''import pathlib, time, os
root = pathlib.Path({str(self.root)!r})
(root / "child-pid").write_text(str(os.getpid()))
(root / "ready").touch()
while not (root / "release").exists():
    time.sleep(0.02)
''')
        process = subprocess.Popen(self.command("run", "--", sys.executable, str(script)),
                                   env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def cleanup():
            (self.root / "release").touch()
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=20)
        self.addCleanup(cleanup)
        if wait:
            self.wait_file(self.root / "ready")
        return process

    def test_missing_lock_directory_allows_condition_without_creating_state(self):
        self.lock.parent.rmdir()
        self.assertEqual(self.run_guard("condition").returncode, 0)
        self.assertFalse(self.lock.parent.exists())
        self.assertEqual(self.calls(), [])

    def test_missing_lock_directory_rejects_activation(self):
        self.lock.parent.rmdir()
        result = self.run_guard("run", "--", TRUE)
        self.assertEqual(result.returncode, 1)
        self.assertIn("ACME lock directory is not initialised", result.stderr)
        self.assertFalse(self.lock.parent.exists())
        self.assertEqual(self.calls(), [])

    def test_condition_reads_existing_lock_without_write_access(self):
        with test_lock(self.lock):
            os.chmod(self.lock, 0o400)
        self.assertEqual(self.run_guard("condition").returncode, 0)

    def test_condition_skips_only_while_locked(self):
        with test_lock(self.lock) as fd:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.run_guard("condition").returncode, 1)
        self.assertEqual(self.run_guard("condition").returncode, 0)

    def test_unit_gate_does_not_skip_other_certificates(self):
        with test_lock(self.lock.with_name(UNIT + ".lock")) as fd:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.run_guard("condition", UNIT).returncode, 1)
            self.assertEqual(self.run_guard("condition", OTHER).returncode, 0)
        self.assertEqual(self.run_guard("condition", UNIT).returncode, 0)

    def test_second_retry_cannot_modify_units(self):
        with test_lock(self.lock.with_name("retry.lock")) as fd:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.run_guard("retry", "example.test").returncode, 1)
            self.assertEqual(self.calls(), [])

    def test_condition_rejects_path_bearing_unit(self):
        self.assertEqual(self.run_guard("condition", "../../other").returncode, 255)

    def test_symlink_is_an_error_not_a_skip(self):
        self.lock.symlink_to(self.root / "missing")
        self.assertEqual(self.run_guard("condition").returncode, 255)

    def test_world_readable_lock_file_is_rejected(self):
        self.lock.write_text("")
        os.chmod(self.lock, 0o644)
        self.assertEqual(self.run_guard("condition").returncode, 255)

    def test_shared_directory_is_rejected(self):
        self.lock.parent.chmod(0o755)
        self.assertEqual(self.run_guard("condition").returncode, 255)

    def test_second_activation_cannot_change_order_state(self):
        process = self.launch()
        self.assertEqual(self.run_guard("condition").returncode, 1)
        before = self.calls()
        second = self.run_guard("run", "--", TRUE)
        self.assertEqual(second.returncode, 1)
        self.assertIn("already running", second.stderr)
        self.assertEqual(before, self.calls())
        (self.root / "release").touch()
        self.assertEqual(process.wait(timeout=20), 0)
        self.assertEqual(self.run_guard("condition").returncode, 0)

    def test_switch_failure_and_resume_preserve_exit_code(self):
        result = self.run_guard("run", "--", SH, "-c", "exit 37")
        self.assertEqual(result.returncode, 37)
        self.assertEqual(self.run_guard("condition").returncode, 0)
        self.assertIn(["stop", "--", UNIT], self.calls())
        self.assertIn(["--no-block", "start", "--", UNIT], self.calls())

    def test_only_known_order_units_are_paused(self):
        self.set_state("database.service", "failed", "failed")
        self.assertEqual(self.run_guard("run", "--", TRUE).returncode, 0)
        self.assertTrue(all("database.service" not in args for args in self.calls()))
        self.assertTrue(all(args != ["reset-failed"] for args in self.calls()))

    def test_running_order_finishes_before_activation_without_being_stopped(self):
        self.set_state(UNIT, "activating", "start")
        process = self.launch(wait=False)
        deadline = time.monotonic() + 20
        while not self.calls() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertFalse((self.root / "ready").exists())
        (self.root / "finish-order").touch()
        self.wait_file(self.root / "ready")
        self.assertNotIn(["stop", "--", UNIT], self.calls())
        (self.root / "release").touch()
        self.assertEqual(process.wait(timeout=20), 0)

    def test_no_manifest_means_no_legacy_cleanup(self):
        self.installed.unlink()
        self.assertEqual(self.run_guard("run", "--", TRUE).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_resume_uses_installed_generation_manifest(self):
        command = f"cp '{self.manifest}' '{self.installed}'"
        self.assertEqual(self.run_guard("run", "--", SH, "-c", command).returncode, 0)
        self.assertIn(["--no-block", "start", "--", UNIT, OTHER], self.calls())
        self.assertNotIn(["stop", "--", OTHER], self.calls())

    def test_dry_and_boot_modes_do_not_touch_runtime(self):
        for flag in ("DRY_ACTIVATE", "BOOT"):
            result = self.run_guard("run", "--", SH, "-c", "exit 23", env={**self.env, flag: "1"})
            self.assertEqual(result.returncode, 23)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.lock.exists())

    def test_test_mode_is_guarded(self):
        result = self.run_guard("run", "--", TRUE, env={**self.env, "TEST": "1"})
        self.assertEqual(result.returncode, 0)
        self.assertIn(["stop", "--", UNIT], self.calls())

    def test_retry_accepts_standard_argument_separator(self):
        self.assertEqual(self.run_guard("retry", "--", "example.test").returncode, 0)
        self.assertIn(["--no-block", "start", "--", UNIT], self.calls())

    def test_retry_brings_forward_pending_restart(self):
        self.assertEqual(self.run_guard("retry", "EXAMPLE.TEST.").returncode, 0)
        calls = self.calls()
        self.assertLess(calls.index(["stop", "--", UNIT]), calls.index(["--no-block", "start", "--", UNIT]))

    def test_retry_holds_condition_gate_while_cancelling_delayed_restart(self):
        (self.root / "probe-gate").touch()
        self.assertEqual(self.run_guard("retry", "example.test").returncode, 0)
        self.assertTrue((self.root / "gate-was-held").exists())
        self.assertEqual(self.run_guard("condition", UNIT).returncode, 0)

    def test_retry_holds_activation_gate_until_start_is_dispatched(self):
        (self.root / "probe-start-gate").touch()
        result = self.run_guard("retry", "example.test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "start-gate-was-held").exists())
        self.assertEqual(self.run_guard("condition", UNIT).returncode, 0)

    def test_retry_preserves_nested_error_context(self):
        (self.root / "fail-systemctl").touch()
        result = self.run_guard("retry", "example.test")
        self.assertEqual(result.returncode, 1)
        self.assertIn("While retrying ACME certificates for example.test", result.stderr)
        self.assertIn("While inspecting ACME order " + UNIT, result.stderr)
        self.assertIn("Running: " + str(self.fake) + " show", result.stderr)
        self.assertIn("deliberate systemctl failure", result.stderr)

    def test_resume_failure_is_a_warning_and_preserves_switch_exit(self):
        command = 'touch "$1"; exit 37'
        result = self.run_guard(
            "run", "--", SH, "-c", command, "sh", str(self.root / "fail-systemctl")
        )
        self.assertEqual(result.returncode, 37)
        self.assertIn("Warning: could not resume ACME orders", result.stderr)
        self.assertEqual(self.run_guard("condition").returncode, 0)

    def test_retry_does_not_interrupt_running_order(self):
        self.set_state(UNIT, "activating", "start")
        self.assertEqual(self.run_guard("retry", "example.test").returncode, 0)
        self.assertNotIn(["stop", "--", UNIT], self.calls())

    def test_unknown_host_fails_before_systemd_changes(self):
        self.assertEqual(self.run_guard("retry", "example.test", "unknown.test").returncode, 1)
        self.assertEqual(self.calls(), [])

    def test_retry_cannot_run_during_activation(self):
        process = self.launch()
        before = self.calls()
        self.assertEqual(self.run_guard("retry", "example.test").returncode, 1)
        self.assertEqual(before, self.calls())
        (self.root / "release").touch()
        process.wait(timeout=20)

    def test_preparation_failure_does_not_run_switch(self):
        (self.root / "fail-systemctl").touch()
        sentinel = self.root / "ran"
        result = self.run_guard("run", "--", TOUCH, str(sentinel))
        self.assertEqual(result.returncode, 1)
        self.assertFalse(sentinel.exists())
        self.assertEqual(self.run_guard("condition").returncode, 0)

    def test_termination_is_forwarded_and_gate_is_released(self):
        process = self.launch()
        process.terminate()
        self.assertEqual(process.wait(timeout=20), 128 + signal.SIGTERM)
        self.assertEqual(self.run_guard("condition").returncode, 0)

    def test_child_retains_lock_after_supervisor_is_killed(self):
        process = self.launch()
        process.kill()
        self.assertEqual(process.wait(timeout=20), -signal.SIGKILL)
        self.assertEqual(self.run_guard("condition").returncode, 1)
        (self.root / "release").touch()
        deadline = time.monotonic() + 20
        while self.run_guard("condition").returncode and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertEqual(self.run_guard("condition").returncode, 0)

    def test_manifest_rejects_wildcard_units(self):
        self.write_manifest(self.manifest, ["acme-order-renew-*.service"])
        self.assertEqual(self.run_guard("retry", "example.test").returncode, 1)
        self.assertEqual(self.calls(), [])

    def test_empty_retry_is_not_all_certificates(self):
        self.assertNotEqual(self.run_guard("retry").returncode, 0)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
