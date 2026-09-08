import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import test as runner


class PublicDownloadTests(unittest.TestCase):
    def test_build_does_not_require_local_platform_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = {"name": "example"}
            executable = root / "example"
            for system in ("Linux", "Darwin"):
                with self.subTest(system=system), patch.object(runner, "ROOT", root), \
                     patch.object(runner.platform, "system", return_value=system), \
                     patch.object(runner, "build_target", return_value=executable) as build:
                    self.assertEqual(
                        runner.build_targets("roc", [target], False, None),
                        {"example": executable},
                    )
                    build.assert_called_once_with("roc", target, False, None)


if __name__ == "__main__":
    unittest.main()
