"""Audio lifecycle regressions using temporary config and mocked session tools."""
import contextlib
import io
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_prescription import load_agc


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.agc = load_agc()
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.agc.ROOT = self.tmp / "audiogram"
        self.agc.STATE_PATH = self.agc.ROOT / "state.json"
        self.agc.USER_PROFILES = self.agc.ROOT / "profiles"
        self.agc.WP_FRAGMENT = self.tmp / "wireplumber" / "audiogram.conf"
        self.profile = self.agc.load_profile("custom")
        for ear in ("left", "right"):
            self.profile["thresholdsDbHl"][ear] = {str(hz): 40 for hz in self.agc.BAND_FREQS}
        self.agc.save_user_profile(self.profile)
        self.bands = self.agc.prescribe_bands(self.profile, 100)
        self.objects = self.graph()
        # Any unmocked real subprocess is a test failure, never a desktop change.
        self.run = self.enterContext(patch.object(self.agc, "run", side_effect=AssertionError("unmocked subprocess")))

    def graph(self, legacy=False):
        names = []
        for ear in ("l", "r"):
            names.extend(f"{ear}_preamp:{key}" for key in (("Freq", "Q", "Gain") if legacy else ("Mult", "Add")))
            names.extend(f"{ear}_eq_band_{i}:{key}" for i in range(8) for key in ("Freq", "Q", "Gain"))
        return [{"id": 12, "type": "PipeWire:Interface:Node", "info": {
            "props": {"node.name": self.agc.EQ_NODE_NAME},
            "params": {"PropInfo": [{"name": name} for name in names]},
        }}]

    def test_runtime_uses_one_update_and_broadband_preamp(self):
        self.run.side_effect = None
        self.run.return_value = subprocess.CompletedProcess([], 0, "", "")
        self.agc.apply_runtime(self.bands, -12, True, self.objects)
        self.run.assert_called_once()
        command = self.run.call_args.args[0]
        self.assertEqual(command[:4], ["pw-cli", "set-param", "12", "Props"])
        params = json.loads(command[4])["params"]
        values = dict(zip(params[::2], params[1::2]))
        for ear in ("l", "r"):
            self.assertAlmostEqual(20 * math.log10(values[f"{ear}_preamp:Mult"]), -12)
            self.assertEqual(values[f"{ear}_preamp:Add"], 0)
            self.assertEqual(values[f"{ear}_eq_band_7:Gain"], 10)
        self.assertEqual(len(values), 52)

    def test_disabled_runtime_is_unity_and_flat(self):
        with patch.object(self.agc, "set_controls") as send:
            self.agc.apply_runtime(self.bands, -12, False, self.objects)
        params = send.call_args.args[1]
        values = dict(zip(params[::2], params[1::2]))
        self.assertTrue(all(v == 0 for k, v in values.items() if k.endswith(":Gain")))
        self.assertEqual(values["l_preamp:Mult"], 1)
        self.assertEqual(values["r_preamp:Mult"], 1)

    def test_live_update_persists_without_restart(self):
        with patch.object(self.agc, "dump_objects", return_value=self.objects), \
             patch.object(self.agc, "apply_runtime", return_value=self.objects), \
             patch.object(self.agc, "restart_wireplumber") as restart:
            self.agc.ensure_graph(self.bands, -12, True)
        self.assertEqual(self.agc.WP_FRAGMENT.read_text(), self.agc.wireplumber_fragment(self.bands, -12, True))
        self.assertEqual(self.agc.WP_FRAGMENT.stat().st_mode & 0o777, 0o600)
        restart.assert_not_called()

    def test_legacy_preamp_requires_migration(self):
        self.assertFalse(self.agc.dual_chain_ready(self.graph(legacy=True)))
        with patch.object(self.agc, "dump_objects", return_value=self.graph(legacy=True)), \
             patch.object(self.agc, "restart_wireplumber") as restart, \
             patch.object(self.agc, "wait_for_graph", return_value=self.objects), \
             patch.object(self.agc, "apply_runtime", return_value=self.objects):
            self.agc.ensure_graph(self.bands, -12, True)
        restart.assert_called_once()
        self.assertIn("name = l_preamp label = linear", self.agc.WP_FRAGMENT.read_text())

    def test_disable_persists_flat_with_and_without_live_graph(self):
        for objects in (self.objects, []):
            with self.subTest(live=bool(objects)):
                self.agc.write_wireplumber_fragment(self.bands, -12, True)
                self.agc.save_state({**self.agc.DEFAULT_STATE, "enabled": True})
                with patch.object(self.agc, "dump_objects", return_value=objects), \
                     patch.object(self.agc, "resolve_preset", return_value=("speakers", "speaker", "Speaker")), \
                     patch.object(self.agc, "apply_runtime", return_value=objects), \
                     contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(self.agc.cmd_apply(True, enable=False), 0)
                self.assertFalse(json.loads(output.getvalue())["enabled"])
                fragment = self.agc.WP_FRAGMENT.read_text()
                self.assertIn('"Mult" = 1.0', fragment)
                self.assertNotIn('"Gain" = 10', fragment)
                self.assertFalse(self.agc.load_state()["enabled"])

    def test_disabled_fresh_install_does_not_create_graph(self):
        with patch.object(self.agc, "dump_objects", return_value=[]), \
             patch.object(self.agc, "resolve_preset", return_value=("speakers", "speaker", "Speaker")), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.agc.cmd_apply(True, enable=False), 0)
        self.assertFalse(self.agc.WP_FRAGMENT.exists())

    def test_preview_requests_reconcile_only_when_enabled_and_stale(self):
        state = self.agc.safe_state({"enabled": True, "activePreset": "speakers"})
        with patch.object(self.agc, "resolve_preset", return_value=("headphones", "headset", "Headset")):
            self.assertTrue(self.agc.build_preview(state, self.objects)["needsApply"])
            state["activePreset"] = "headphones"
            self.assertFalse(self.agc.build_preview(state, self.objects)["needsApply"])
            self.assertTrue(self.agc.build_preview(state, self.graph(legacy=True))["needsApply"])
            state["enabled"] = False
            self.assertFalse(self.agc.build_preview(state, [])["needsApply"])
            # An older boosted graph must be migrated flat even if saved OFF.
            self.assertTrue(self.agc.build_preview(state, self.graph(legacy=True))["needsApply"])
            self.assertFalse(self.agc.build_preview(state, self.objects)["needsApply"])
        self.assertFalse(self.agc.WP_FRAGMENT.exists())  # status never mutates

    def test_per_ear_unavailable_audio_returns_json_error(self):
        with patch.object(self.agc, "dump_objects", side_effect=RuntimeError("audio unavailable")), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(self.agc.main(["--json", "per-ear", "toggle"]), 1)
        self.assertEqual(json.loads(output.getvalue()), {"error": "audio unavailable"})

    def test_reset_keeps_profiles(self):
        self.agc.write_wireplumber_fragment(self.bands, -12, True)
        self.agc.save_state(self.agc.DEFAULT_STATE)
        with patch.object(self.agc, "restart_wireplumber") as restart, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.agc.cmd_reset(True), 0)
        self.assertFalse(self.agc.WP_FRAGMENT.exists())
        self.assertFalse(self.agc.STATE_PATH.exists())
        self.assertTrue((self.agc.USER_PROFILES / "custom.json").exists())
        restart.assert_called_once()

    def test_invalid_numeric_profile_inputs_do_not_crash(self):
        self.assertEqual(self.agc.clamp_threshold(float("inf")), 0)
        self.assertEqual(self.agc.clamp_threshold(float("nan")), 0)
        self.assertEqual(self.agc.interpolate_threshold({"0": 20, "-1": 20, "1000": 30}, 250), 30)
        self.assertIsNone(self.agc.ear_threshold({"thresholdsDbHl": []}, "left", 1000))

    def test_profile_save_stdin_preserves_supported_payloads(self):
        for payload in (
            {"label": 'Private 日本語 "label"', "left": {"1000": 37}, "right": {"1000": 42}},
            {"label": "Nested", "thresholdsDbHl": {"left": {"1000": 37}, "right": {"1000": 42}}},
            {"label": "Rows", "thresholds": [{"frequency": 1000, "left": 37, "right": 42}]},
        ):
            with self.subTest(payload=payload), patch.object(sys, "stdin", io.StringIO(json.dumps(payload))), \
                 patch.object(self.agc, "cmd_apply", return_value=0):
                self.assertEqual(self.agc.main(["profile-save", "--json"]), 0)
            saved = self.agc.load_profile("custom")
            self.assertEqual(saved["label"], payload["label"])
            self.assertEqual(saved["thresholdsDbHl"]["left"]["1000"], 37)
            self.assertEqual(saved["thresholdsDbHl"]["right"]["1000"], 42)
            self.assertEqual((self.agc.USER_PROFILES / "custom.json").stat().st_mode & 0o777, 0o600)

    def test_profile_save_rejects_bad_stdin_and_legacy_args_without_echo(self):
        original = (self.agc.USER_PROFILES / "custom.json").read_text()
        for raw in ("", "not-json PRIVATE-MARKER", "[]", "x" * 65537):
            with self.subTest(raw=raw[:30]), patch.object(sys, "stdin", io.StringIO(raw)), \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(self.agc.main(["--json", "profile-save"]), 1)
            self.assertIn("error", json.loads(output.getvalue()))
            self.assertNotIn("PRIVATE-MARKER", output.getvalue())
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(self.agc.main(["--json", "profile-save", '{"label":"PRIVATE-MARKER"}']), 1)
        self.assertNotIn("PRIVATE-MARKER", output.getvalue())
        self.assertEqual((self.agc.USER_PROFILES / "custom.json").read_text(), original)

    def test_live_profile_save_has_no_health_data_in_proc_cmdline(self):
        # Backend blocks awaiting stdin; inspect argv before delivering health data.
        config = self.tmp / "config"
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, reply in (("pw-dump", "[]"), ("pactl", "test-speaker")):
            tool = bin_dir / name
            tool.write_text("#!/bin/sh\nprintf '%s\\n' '" + reply + "'\n")
            tool.chmod(0o700)
        payload = {"label": "PRIVATE-HEARING-MARKER 日本語", "left": {"1000": 37}, "right": {"1000": 42}}
        command = [sys.executable, str(Path(self.agc.__file__)), "--json", "profile-save"]
        with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, env={**os.environ, "XDG_CONFIG_HOME": str(config), "PATH": str(bin_dir)}) as process:
            try:
                cmdline = Path(f"/proc/{process.pid}/cmdline").read_bytes()
                self.assertNotIn(b"PRIVATE-HEARING-MARKER", cmdline)
                self.assertNotIn(b'"left"', cmdline)
                self.assertNotIn(b'"right"', cmdline)
                stdout, stderr = process.communicate(json.dumps(payload), timeout=10)
                self.assertEqual(process.returncode, 0, stderr + stdout)
                self.assertEqual(json.loads(stdout)["profileLabel"], payload["label"])
                saved = json.loads((config / "omarchy/audiogram-eq/profiles/custom.json").read_text())
                self.assertEqual(saved["thresholdsDbHl"]["left"]["1000"], 37)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
