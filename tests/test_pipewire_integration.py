"""Opt-in graph test with a private PipeWire server and no device manager."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

from test_prescription import load_agc


@unittest.skipUnless(os.environ.get("AUDIOGRAM_PIPEWIRE_TEST") == "1", "opt-in private PipeWire test")
class PipeWireIntegrationTests(unittest.TestCase):
    def test_generated_graph_and_batched_controls(self):
        for tool in ("pipewire", "pw-dump", "pw-cli"):
            self.assertIsNotNone(shutil.which(tool), tool)
        agc = load_agc()
        with tempfile.TemporaryDirectory(prefix="audiogram-pw-") as tmp:
            root = Path(tmp)
            env = {**os.environ, "XDG_RUNTIME_DIR": tmp, "XDG_CONFIG_HOME": tmp,
                   "PIPEWIRE_RUNTIME_DIR": tmp, "PIPEWIRE_REMOTE": "audiogram-test",
                   "PIPEWIRE_CONFIG_DIR": tmp, "PIPEWIRE_CONFIG_PREFIX": ""}
            env.pop("PIPEWIRE_CONFIG_NAME", None)
            spa = '''context.spa-libs = {
                audio.convert.* = audioconvert/libspa-audioconvert
                support.* = support/libspa-support
            }
'''
            client_modules = '''
                { name = libpipewire-module-protocol-native }
                { name = libpipewire-module-client-node }
                { name = libpipewire-module-adapter }
                { name = libpipewire-module-metadata }
'''
            (root / "client.conf").write_text(spa + "context.modules = [" + client_modules + "]")
            (root / "server.conf").write_text(spa + '''
context.properties = { core.daemon = true core.name = audiogram-test }
context.modules = [
''' + client_modules + '''
    { name = libpipewire-module-access }
    { name = libpipewire-module-spa-node-factory }
    { name = libpipewire-module-link-factory }
]
''')
            profile = json.loads((Path(__file__).parent / "fixtures" / "sample-mild-hf.json").read_text())
            bands = agc.prescribe_bands(profile, 100, per_ear=True)
            fragment = agc.wireplumber_fragment(bands, -12, True)
            args = fragment.split("arguments = ", 1)[1].split("\n    provides =", 1)[0]
            (root / "filter.conf").write_text(spa + "context.modules = [" + client_modules
                + "{ name = libpipewire-module-filter-chain args = " + args + " } ]")
            processes = []
            with (root / "log").open("w+") as log:
                try:
                    processes.append(subprocess.Popen(["pipewire", "-c", "server.conf"], env=env, stdout=log, stderr=log))
                    deadline = time.monotonic() + 5
                    while not (root / "audiogram-test").exists() and time.monotonic() < deadline:
                        time.sleep(0.05)
                    self.assertTrue((root / "audiogram-test").exists(), "private server socket missing")
                    processes.append(subprocess.Popen(["pipewire", "-c", "filter.conf"], env=env, stdout=log, stderr=log))

                    def run(command, timeout=5):
                        return subprocess.run(command, env=env, capture_output=True, text=True, timeout=timeout)

                    with patch.object(agc, "run", side_effect=run):
                        objects = agc.wait_for_graph(5)
                        self.assertTrue(agc.dual_chain_ready(objects), "generated graph did not expose expected controls")
                        for enabled in (False, True):
                            agc.apply_runtime(bands, -12, enabled, objects)
                            current = agc.eq_node(agc.dump_objects())
                            values = {}
                            for entry in current["info"]["params"]["Props"]:
                                props = entry.get("params", [])
                                values.update(props if isinstance(props, dict) else dict(zip(props[::2], props[1::2])))
                            self.assertIn("l_preamp:Mult", values)
                            self.assertAlmostEqual(values["l_preamp:Mult"], 10 ** (-12 / 20) if enabled else 1, places=5)
                            self.assertAlmostEqual(values["r_eq_band_7:Gain"], bands[7]["rightGain"] if enabled else 0)
                except Exception as exc:
                    log.flush()
                    log.seek(0)
                    raise AssertionError(str(exc) + "\n" + log.read()) from exc
                finally:
                    for process in reversed(processes):
                        process.terminate()
                        try:
                            process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=3)
