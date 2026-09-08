import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import test as runner

WARNING = "── ● roc version mismatch ─ /cache/main.roc:9:13\nThis header pins Roc version nightly-old, but you are running nightly-new.\n── 0 errors and 1 warning ─ example.roc\n"


class PinWarningTests(unittest.TestCase):
    def test_only_pin_warnings(self):
        self.assertTrue(runner.only_pin_mismatch_warnings(WARNING))
        self.assertTrue(runner.only_pin_mismatch_warnings(WARNING.replace("── 0 errors and 1 warning ─ example.roc", "All (0) tests passed in 11.2 ms.")))
        self.assertTrue(runner.only_pin_mismatch_warnings("\x1b[33m" + WARNING + "\x1b[0m"))
        for output in ("", "0 errors and 1 warning", WARNING.replace("version mismatch", "unused variable"),
                       WARNING.replace("0 errors", "1 error"), WARNING.replace("1 warning", "2 warnings"),
                       WARNING + "── ● unused variable ─ app.roc\n"):
            with self.subTest(output=output):
                self.assertFalse(runner.only_pin_mismatch_warnings(output))

    def test_exit_code_and_opt_in_are_required(self):
        for code, allowed, passes in ((2, True, True), (2, False, False), (1, True, False), (3, True, False)):
            with self.subTest(code=code, allowed=allowed), patch.object(runner.subprocess, "run", return_value=subprocess.CompletedProcess([], code, WARNING)):
                if passes:
                    runner.run(["roc", "check", "example.roc"], capture=True, allow_pin_warning=allowed)
                else:
                    with self.assertRaises(runner.TestFailure):
                        runner.run(["roc", "check", "example.roc"], capture=True, allow_pin_warning=allowed)
