"""Exercise the actual panel Text blocks with Qt, without starting the shell/audio.

Only the host's caption-size token is replaced; text bindings and formatting
come directly from Panel.qml. This is not a full host-panel integration test.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNNER = shutil.which("qmltestrunner") or "/usr/lib/qt6/bin/qmltestrunner"


@unittest.skipUnless(Path(RUNNER).is_file(), "Qt qmltestrunner is not installed")
class PanelTextTests(unittest.TestCase):
    def test_external_strings_are_literal(self):
        source = (ROOT / "Panel.qml").read_text()
        bindings = [
            'text: root.state.profileLabel + " · " + root.state.deviceName',
            'text: root.errorMessage',
            'text: root.audiogramSummary()',
            'text: "Prescribed gains (preamp "',
            'text: root.state.disclaimer',
        ]
        blocks = re.findall(r"\bText\s*\{.*?^\s*\}", source, re.S | re.M)
        selected = []
        for index, binding in enumerate(bindings):
            matches = [block for block in blocks if binding in block]
            self.assertEqual(len(matches), 1, binding)
            block = matches[0].replace("Style.font.caption", "12").replace("Color.urgent", '"red"')
            selected.append(block.replace("Text {", f"Text {{ id: display{index}", 1))
        summary = source.split("  function audiogramSummary()", 1)[1].split("\n  function ", 1)[0]
        displays = ", ".join(f"display{i}" for i in range(len(selected)))
        qml = '''import QtQuick
import QtTest
Item {
    id: root
    width: 1000; height: 800
    property var state: ({})
    property string errorMessage: ""
    property string draftLabel: ""
    property var draftThresholds: [{left: 0, right: 0}]
    property bool audiogramExpanded: false
    property color dim: "black"
    property string fontFamily: "sans-serif"
    function audiogramSummary() SUMMARY
    BLOCKS
    Text {
        id: literal
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: 12
    }
    Text {
        id: automatic
        text: "<b>Injected</b>"
        font.family: root.fontFamily
        font.pixelSize: 12
    }
    TestCase {
        name: "PanelLiteralText"
        when: windowShown
        function test_plain_text() {
            var payloads = PAYLOADS
            var displays = [DISPLAYS]
            for (var p = 0; p < payloads.length; p++) {
                var value = payloads[p]
                root.state = {profileLabel: value, deviceName: value,
                    disclaimer: value, activePreset: value, preamp: 0, perEar: false}
                root.errorMessage = value
                root.draftLabel = value
                var expected = [value + " · " + value, value,
                    value + " · L≈0 / R≈0 dB HL",
                    "Prescribed gains (preamp 0 dB) · " + value + " · averaged", value]
                for (var i = 0; i < displays.length; i++) {
                    var display = displays[i]
                    compare(display.text, expected[i], "binding " + i)
                    compare(display.textFormat, Text.PlainText, "format " + i)
                    literal.text = expected[i]
                    fuzzyCompare(display.implicitWidth, literal.implicitWidth, 0.1)
                }
            }
            // Positive control: the old default interprets markup differently.
            literal.text = automatic.text
            verify(automatic.implicitWidth < literal.implicitWidth)
        }
    }
}
'''
        payloads = [
            "<b>Injected</b>",
            '<img src="file:///nonexistent-audiogram-regression.png">',
            '<a href="https://example.invalid/">link</a>',
            "Headphones <left> & right · 日本語 🎧",
            "&lt;b&gt;literal&lt;/b&gt;\nsecond line",
        ]
        qml = (qml.replace("SUMMARY", summary)
               .replace("BLOCKS", "\n".join(selected))
               .replace("DISPLAYS", displays)
               .replace("PAYLOADS", json.dumps(payloads)))
        self.run_qml(qml)

    def run_qml(self, qml):
        with tempfile.TemporaryDirectory(prefix="audiogram-qml-") as tmp:
            path = Path(tmp) / "tst_panel_text.qml"
            path.write_text(qml)
            result = subprocess.run(
                [RUNNER, "-input", str(path)], capture_output=True, text=True,
                env={**os.environ, "QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "software",
                     "QT_QPA_PLATFORMTHEME": "", "QT_QUICK_CONTROLS_STYLE": "Basic"},
                timeout=30,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_panel_command_and_draft_lifecycle(self):
        source = (ROOT / "Panel.qml").read_text()
        logic = source.split("Panel {", 1)[1].split("\n  Process {", 1)[0]
        logic = logic.replace("Color.foreground", '"black"').replace("Style.font.family", '"sans-serif"')
        qml = '''import QtQuick
import QtTest
Item {
    LOGIC
    property string moduleName
    property string ipcTarget
    property bool manageIpc
    property var bar: null
    property bool opened: false
    QtObject { id: statusProcess; property bool running: false }
    QtObject { id: mutationProcess; property bool running: false; property var command: [] }
    QtObject { id: labelField; property bool activeFocus: false; property string text: "" }
    QtObject { id: eqCurve; function requestPaint() {} }
    TestCase {
        name: "PanelLifecycle"
        function init() {
            statusProcess.running = false
            mutationProcess.running = false
            mutationProcess.command = []
            root.pendingCommands = []
            root.profileDirty = false
            root.draftRevision = 0
            root.saveRevision = -1
            root.errorMessage = ""
            root.collapseAudiogramAfterSave = false
            root.audiogramExpanded = true
            root.state = root.copyState({})
        }
        function test_status_and_mutations_are_serial() {
            root.refresh()
            verify(statusProcess.running)
            root.enqueue(["enable"])
            verify(!mutationProcess.running)
            compare(root.pendingCommands.length, 1)
            statusProcess.running = false
            root.runNextMutation()
            verify(mutationProcess.running)
            compare(mutationProcess.command[2], "enable")
            root.refresh()
            verify(!statusProcess.running)
        }
        function test_auto_reconcile_queues_once_and_stops_after_error() {
            statusProcess.running = true
            root.applyStatus({ready: true, enabled: true, needsApply: true}, false)
            compare(root.pendingCommands.length, 1)
            root.applyStatus({ready: true, enabled: true, needsApply: true}, false)
            compare(root.pendingCommands.length, 1)
            statusProcess.running = false
            root.runNextMutation()
            compare(mutationProcess.command[2], "apply")
            mutationProcess.running = false
            root.showError("could not apply")
            root.applyStatus({ready: true, enabled: true, needsApply: true}, false)
            verify(!mutationProcess.running)
            compare(root.pendingCommands.length, 0)
        }
        function test_unrelated_mutation_preserves_unsaved_profile() {
            root.draftLabel = "Unsaved <label>"
            root.markProfileDirty()
            mutationProcess.command = ["agc", "--json", "intensity", "80"]
            root.parseResult(JSON.stringify({ready: true, profileLabel: "Old saved label"}), true)
            verify(root.profileDirty)
            compare(root.draftLabel, "Unsaved <label>")
        }
        function test_successful_save_clears_only_saved_revision() {
            root.draftLabel = "Saved label"
            root.markProfileDirty()
            root.saveProfile()
            root.parseResult(JSON.stringify({ready: true, profileLabel: "Saved label",
                thresholds: [{frequency: 1000, left: 30, right: 20}]}), true)
            verify(!root.profileDirty)
            verify(!root.audiogramExpanded)
        }
        function test_edits_during_save_are_preserved() {
            root.markProfileDirty()
            root.saveProfile()
            root.draftLabel = "Newer edits"
            root.markProfileDirty()
            root.parseResult(JSON.stringify({ready: true, profileLabel: "Older save"}), true)
            verify(root.profileDirty)
            compare(root.draftLabel, "Newer edits")
            verify(root.audiogramExpanded)
        }
        function test_errors_preserve_literal_text_and_draft() {
            root.markProfileDirty()
            root.parseResult(JSON.stringify({error: "<b>device error</b>"}), true)
            compare(root.errorMessage, "<b>device error</b>")
            verify(root.profileDirty)
            root.showError("<img src='diagnostic'>")
            compare(root.errorMessage, "<img src='diagnostic'>")
        }
    }
}
'''.replace("LOGIC", logic)
        self.run_qml(qml)

    def test_response_curve_preamp_is_broadband(self):
        source = (ROOT / "components" / "EqCurve.qml").read_text()
        # Only host theme tokens are replaced; the production DSP functions run.
        source = source.replace("import qs.Commons", "")
        source = source.replace("Style.font.family", '"sans-serif"')
        source = source.replace("Color.menu.text", '"black"').replace("Color.accent", '"blue"')
        body = source.split("Canvas {", 1)[1].rsplit("}", 1)[0]
        qml = '''import QtQuick
import QtTest
Canvas {
    BODY
    TestCase {
        name: "ResponsePreamp"
        function test_broadband() {
            root.preamp = -12
            root.bands = []
            root.enabled = true
            var sections = root.buildSections("gain")
            for (var hz of [40, 250, 1000, 8000, 20000])
                fuzzyCompare(root.responseAt(sections, hz, 48000), -12, 0.001)
            root.enabled = false
            fuzzyCompare(root.responseAt(root.buildSections("gain"), 1000, 48000), 0, 0.001)
        }
    }
}
'''.replace("BODY", body)
        self.run_qml(qml)
