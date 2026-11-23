"""Offline contract tests. Synthetic inputs only; no services or credentials."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

try:
    import yaml
except ImportError:
    yaml = None

ROOT = Path(__file__).resolve().parent.parent


class LocalTargetsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.calls = self.home / "external-calls"
        hostname = self.bin / "hostname"
        hostname.write_text('#!/bin/sh\nprintf "synthetic-client\\n"\n')
        hostname.chmod(0o755)
        # Fail loudly if a test accidentally attempts a connection, credential
        # export or service change. All deliberately safe paths must avoid these.
        for command in ["ssh", "scp", "curl", "docker", "infisical"]:
            stub = self.bin / command
            stub.write_text('#!/bin/sh\nprintf "forbidden external action\\n" >> "$CALL_LOG"\nexit 91\n')
            stub.chmod(0o755)
        self.env = {
            "HOME": str(self.home),
            "PATH": str(self.bin) + os.pathsep + os.environ.get("PATH", "/usr/bin:/bin"),
            "HOMELAB_TARGETS_FILE": str(self.home / "targets.sh"),
            "CALL_LOG": str(self.calls),
        }

    def run_script(self, script, *args, extra=None):
        result = subprocess.run(
            ["bash", str(ROOT / "scripts" / script), *args],
            env={**self.env, **(extra or {})}, capture_output=True, text=True,
        )
        self.assertFalse(self.calls.exists(), "attempted an external action")
        return result

    def configured(self):
        return {
            "BOX_HOST": "synthetic-box",
            "BOX_HOSTNAME": "synthetic-server",
            "BOX_URL": "https://box.example.invalid",
            "REGISTRY_HOST": "registry.example.invalid:30500",
            "DURI_DIR": str(self.home / "synthetic-app"),
        }

    def test_missing_targets_fail_before_external_actions(self):
        for script in ["deploy.sh", "deploy-duri.sh", "push-duri-env.sh", "duri-drift.sh", "verify.sh",
                       "serve-duri.sh", "serve-transmission.sh", "settings-transmission.sh"]:
            with self.subTest(script=script):
                result = self.run_script(script)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Missing local target:", result.stderr)

    def test_help_does_not_require_targets_or_external_actions(self):
        for script in ["deploy.sh", "deploy-duri.sh", "push-duri-env.sh", "duri-drift.sh", "verify.sh",
                       "serve-duri.sh", "serve-transmission.sh", "settings-transmission.sh"]:
            with self.subTest(script=script):
                result = self.run_script(script, "--help")
                self.assertEqual(result.returncode, 0)

    def test_on_box_deploy_refuses_wrong_local_hostname_before_git(self):
        result = self.run_script("deploy.sh", "--dry-run", extra=self.configured())
        self.assertEqual(result.returncode, 2)
        self.assertIn("not the locally configured server", result.stderr)

    def test_safe_serving_dry_runs_use_synthetic_targets(self):
        for script in ["serve-duri.sh", "serve-transmission.sh", "settings-transmission.sh"]:
            with self.subTest(script=script):
                result = self.run_script(script, "--dry-run", extra=self.configured())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("[dry-run]", result.stdout)
                self.assertIn("synthetic-box", result.stdout)

    def test_pin_dry_run_does_not_access_build_env_or_remote(self):
        # --tag bypasses all source/build-input reads. Uses only this public
        # repository's key-name contract and prints plans; no commands are applied.
        result = self.run_script("deploy-duri.sh", "--dry-run", "--tag", "synthetic-tag", extra=self.configured())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dry-run: skipping verify", result.stdout)

    def test_private_identifier_file_is_loaded(self):
        target = Path(self.env["HOMELAB_TARGETS_FILE"])
        target.write_text('export BOX_HOST="${BOX_HOST:-synthetic-from-file}"\n')
        result = self.run_script("settings-transmission.sh", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("synthetic-from-file", result.stdout)

    def test_environment_can_override_example_style_local_defaults(self):
        Path(self.env["HOMELAB_TARGETS_FILE"]).write_text('export BOX_HOST="${BOX_HOST:-synthetic-from-file}"\n')
        result = self.run_script("settings-transmission.sh", "--dry-run", extra={"BOX_HOST": "synthetic-override"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("synthetic-override", result.stdout)
        self.assertNotIn("synthetic-from-file", result.stdout)

    def test_missing_value_error_prints_key_not_other_target_values(self):
        values = self.configured()
        del values["BOX_URL"]
        result = self.run_script("serve-duri.sh", extra=values)
        self.assertEqual(result.returncode, 2)
        self.assertIn("BOX_URL", result.stderr)
        self.assertNotIn("synthetic-box", result.stderr + result.stdout)

    def test_default_identifier_location_is_independent_of_shell_startup(self):
        directory = self.home / ".config/homelab"
        directory.mkdir(parents=True)
        (directory / "targets.sh").write_text('export BOX_HOST="synthetic-default-file"\n')
        self.env.pop("HOMELAB_TARGETS_FILE")
        result = self.run_script("settings-transmission.sh", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("synthetic-default-file", result.stdout)


@unittest.skipUnless(yaml, "PyYAML is not already installed; YAML checks skipped")
class PublicYamlContractTest(unittest.TestCase):
    def load(self, path, revision=None):
        text = (ROOT / path).read_text() if revision is None else subprocess.check_output(
            ["git", "-C", str(ROOT), "show", revision + ":" + path], text=True
        )
        class Loader(yaml.SafeLoader):
            pass
        Loader.add_constructor("!secret", lambda loader, node: ("local-reference", loader.construct_scalar(node)))
        return yaml.load(text, Loader=Loader)

    def test_both_homekit_bridges_keep_identity_and_exposure(self):
        path = "ha/packages/homekit.yaml"
        old, new = self.load(path, "HEAD"), self.load(path)
        for bridge in old["homekit"]:
            bridge["advertise_ip"] = ("local-reference", "homekit_advertise_ip")
        self.assertTrue(old == new, "only advertise_ip may change to a local reference")

    def test_wiim_actions_keep_numeric_ip_url_contract_and_behavior(self):
        path = "ha/packages/wiim.yaml"
        old, new = self.load(path, "HEAD"), self.load(path)
        old["rest_command"]["wiim_input_bluetooth"]["url"] = ("local-reference", "wiim_bluetooth_url")
        old["rest_command"]["wiim_input_wifi"]["url"] = ("local-reference", "wiim_wifi_url")
        self.assertTrue(old == new, "only the two numeric-IP URLs may become local references")
        example = self.load("ha/local-values.example.yaml")
        self.assertEqual(set(example), {"homekit_advertise_ip", "wiim_bluetooth_url", "wiim_wifi_url"})
        self.assertIn("switchmode:bluetooth", example["wiim_bluetooth_url"])
        self.assertIn("switchmode:wifi", example["wiim_wifi_url"])

    def test_compose_registry_does_not_fall_back_to_wildcard_binding(self):
        old, new = self.load("compose.yaml", "HEAD"), self.load("compose.yaml")
        ports = new["services"]["registry"]["ports"]
        self.assertEqual(ports, ["${TAILSCALE_IP:?Set TAILSCALE_IP in local .env}:30500:5000"])
        new["services"]["registry"]["ports"] = old["services"]["registry"]["ports"]
        self.assertTrue(old == new, "other root Compose runtime fields must remain unchanged")

    def test_transmission_retains_exact_allowlist_and_namespace_contract(self):
        path = "torrent/compose.yaml"
        old, new = self.load(path, "HEAD"), self.load(path)
        env = new["services"]["transmission"]["environment"]
        self.assertEqual(env["HOST_WHITELIST"], "${BOX_FQDN:?Set BOX_FQDN in local .env},localhost,127.0.0.1")
        env["HOST_WHITELIST"] = old["services"]["transmission"]["environment"]["HOST_WHITELIST"]
        self.assertTrue(old == new, "other torrent Compose runtime fields must remain unchanged")


if __name__ == "__main__":
    unittest.main()
