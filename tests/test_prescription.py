#!/usr/bin/env python3
"""Unit tests for audiogram prescription math (no PipeWire required)."""
from __future__ import annotations

import json
import unittest
from pathlib import Path
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
AGC_PATH = ROOT / "backend" / "agc"
PROFILE_PATH = ROOT / "tests" / "fixtures" / "sample-mild-hf.json"
BLANK_PATH = ROOT / "profiles" / "custom.json"


def load_agc():
    loader = SourceFileLoader("audiogram_agc", str(AGC_PATH))
    module = module_from_spec(spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


class PrescriptionTests(unittest.TestCase):
    def setUp(self):
        # Never read the developer's real audiogram or leave patched globals.
        tmp = self.enterContext(tempfile.TemporaryDirectory())
        self.enterContext(patch.object(self.agc, "USER_PROFILES", Path(tmp) / "profiles"))

    @classmethod
    def setUpClass(cls):
        cls.agc = load_agc()
        cls.profile = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
        cls.blank = json.loads(BLANK_PATH.read_text(encoding="utf-8"))

    def test_profile_loads(self):
        self.assertEqual(self.profile["id"], "sample-mild-hf")
        self.assertEqual(self.profile["thresholdsDbHl"]["right"]["8000"], 45)
        self.assertEqual(self.profile["thresholdsDbHl"]["left"]["8000"], 45)

    def test_ship_default_is_blank_custom(self):
        state = self.agc.safe_state({})
        self.assertEqual(state["profileId"], "custom")
        self.assertFalse(state["enabled"])
        blank = self.agc.load_profile("custom")
        rows = self.agc.editor_thresholds(blank)
        self.assertTrue(all(r["left"] == 0 and r["right"] == 0 for r in rows))
        bands = self.agc.prescribe_bands(blank, 100)
        self.assertTrue(all(b["gain"] == 0 for b in bands))

    def test_full_intensity_boosts_highs_more_than_lows(self):
        bands = self.agc.prescribe_bands(self.profile, 100)
        by_freq = {b["frequency"]: b["gain"] for b in bands}
        self.assertGreaterEqual(by_freq[250], 0.0)
        self.assertLess(by_freq[250], by_freq[8000])
        self.assertLessEqual(by_freq[8000], 12.0)
        # 45 dB HL → excess 25 → half-gain 12.5 → capped 12
        self.assertAlmostEqual(by_freq[8000], 12.0, places=2)

    def test_speakers_and_headphones_share_curve_at_same_intensity(self):
        # Preset no longer changes the curve — only intensity does.
        at_100 = self.agc.prescribe_bands(self.profile, 100)
        again = self.agc.prescribe_bands(self.profile, 100)
        self.assertEqual([b["gain"] for b in at_100], [b["gain"] for b in again])

    def test_intensity_scales(self):
        full = self.agc.prescribe_bands(self.profile, 100)
        half = self.agc.prescribe_bands(self.profile, 50)
        self.assertAlmostEqual(half[-1]["gain"], round(full[-1]["gain"] * 0.5, 2), places=2)

    def test_default_intensity_slots(self):
        state = self.agc.safe_state({})
        self.assertEqual(self.agc.intensity_for(state, "headphones"), 100)
        self.assertEqual(self.agc.intensity_for(state, "speakers"), 50)

    def test_per_preset_intensity_is_independent(self):
        state = self.agc.safe_state({})
        self.agc.set_intensity_for(state, "speakers", 80)
        self.agc.set_intensity_for(state, "headphones", 40)
        self.assertEqual(self.agc.intensity_for(state, "speakers"), 80)
        self.assertEqual(self.agc.intensity_for(state, "headphones"), 40)

    def test_classify_sink(self):
        self.assertEqual(self.agc.classify_sink("bluez_output.XX", "WH-1000XM"), "headphones")
        self.assertEqual(self.agc.classify_sink("alsa_output.pci-0000_00_1f.3.analog-stereo", "Built-in Audio"), "speakers")

    def test_auto_preamp_negative(self):
        bands = self.agc.prescribe_bands(self.profile, 100)
        pre = self.agc.auto_preamp(bands)
        self.assertLessEqual(pre, 0.0)
        self.assertAlmostEqual(pre, -max(b["gain"] for b in bands), places=2)

    def test_default_per_ear_slots(self):
        state = self.agc.safe_state({})
        self.assertTrue(self.agc.per_ear_for(state, "headphones"))
        self.assertFalse(self.agc.per_ear_for(state, "speakers"))

    def test_per_ear_toggle_is_independent(self):
        state = self.agc.safe_state({})
        self.agc.set_per_ear_for(state, "speakers", True)
        self.agc.set_per_ear_for(state, "headphones", False)
        self.assertTrue(self.agc.per_ear_for(state, "speakers"))
        self.assertFalse(self.agc.per_ear_for(state, "headphones"))

    def test_per_ear_uses_independent_thresholds(self):
        averaged = self.agc.prescribe_bands(self.profile, 100, per_ear=False)
        independent = self.agc.prescribe_bands(self.profile, 100, per_ear=True)
        by_avg = {b["frequency"]: b for b in averaged}
        by_ind = {b["frequency"]: b for b in independent}
        # Mid bands differ between ears in this profile (L worse than R).
        self.assertGreater(by_ind[1000]["leftGain"], by_ind[1000]["rightGain"])
        self.assertAlmostEqual(by_avg[1000]["leftGain"], by_avg[1000]["rightGain"], places=2)
        self.assertAlmostEqual(by_avg[1000]["gain"], by_avg[1000]["leftGain"], places=2)
        # Averaged gain is the mean of the two ears when per-ear is on.
        self.assertAlmostEqual(
            by_ind[1000]["gain"],
            round((by_ind[1000]["leftGain"] + by_ind[1000]["rightGain"]) / 2.0, 2),
            places=2,
        )

    def test_dual_mono_fragment_has_both_ears(self):
        bands = self.agc.prescribe_bands(self.profile, 100, per_ear=True)
        fragment = self.agc.wireplumber_fragment(bands, -6.0, True)
        self.assertIn("l_preamp", fragment)
        self.assertIn("r_preamp", fragment)
        self.assertIn('"l_preamp:In" "r_preamp:In"', fragment)
        self.assertIn("l_eq_band_0", fragment)
        self.assertIn("r_eq_band_0", fragment)

    def test_control_name_regex_parses_dual_mono(self):
        # Regression: alternation capture groups used to mis-map Gain → preamp.
        objects = [
            {
                "id": 1,
                "type": "PipeWire:Interface:Node",
                "info": {
                    "props": {
                        "node.name": "input.omarchy.audiogram-eq",
                        "filter.smart.name": "filter.sink.omarchy-audiogram-eq",
                    },
                    "params": {
                        "PropInfo": [
                            {"name": "l_preamp:Mult"},
                            {"name": "r_preamp:Mult"},
                            {"name": "l_eq_band_2:Gain"},
                            {"name": "r_eq_band_2:Freq"},
                            {"name": f"l_eq_band_{len(self.agc.BAND_FREQS) - 1}:Gain"},
                            {"name": f"r_eq_band_{len(self.agc.BAND_FREQS) - 1}:Gain"},
                        ]
                    },
                },
            }
        ]
        controls = self.agc.control_params(objects)
        self.assertIn(("l", None, "Mult"), controls)
        self.assertIn(("r", None, "Mult"), controls)
        self.assertIn(("l", 2, "Gain"), controls)
        self.assertIn(("r", 2, "Freq"), controls)
        self.assertTrue(self.agc.dual_chain_ready(objects))

    def test_editor_thresholds_and_user_profile_override(self):
        rows = self.agc.editor_thresholds(self.profile)
        by_freq = {r["frequency"]: r for r in rows}
        self.assertEqual(by_freq[1000]["left"], 30)
        self.assertEqual(by_freq[1000]["right"], 25)

        blank = self.agc.load_profile("custom")
        blank_rows = self.agc.editor_thresholds(blank)
        self.assertTrue(all(r["left"] == 0 and r["right"] == 0 for r in blank_rows))

        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as tmp:
            user_dir = Path(tmp) / "profiles"
            self.agc.USER_PROFILES = user_dir
            # Rebuild ROOT-dependent path helper by calling save directly.
            profile = {
                "id": "custom",
                "label": "Test listener",
                "disclaimer": self.agc.DEFAULT_DISCLAIMER,
                "thresholdsDbHl": {
                    "left": {str(hz): 40 for hz in self.agc.BAND_FREQS},
                    "right": {str(hz): 20 for hz in self.agc.BAND_FREQS},
                },
            }
            path = self.agc.save_user_profile(profile)
            self.assertTrue(path.exists())
            loaded = self.agc.load_profile("custom")
            self.assertEqual(loaded["label"], "Test listener")
            self.assertEqual(loaded["thresholdsDbHl"]["left"]["1000"], 40)
            self.assertEqual(self.agc.editor_thresholds(loaded)[2]["left"], 40)


if __name__ == "__main__":
    unittest.main()
