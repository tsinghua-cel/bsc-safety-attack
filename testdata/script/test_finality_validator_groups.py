"""Regression tests for Go validator-group parsing used by finality analyzers."""
from pathlib import Path
import importlib.util
import sys
import tempfile
import unittest

SCRIPT_DIR = Path(__file__).resolve().parent
ANALYZERS = [
    "analyze_attack_2_finalized_heights.py",
    "analyze_attack_2_8_finalized_heights.py",
    "analyze_repair_finalized_heights.py",
    "analyze_repair_8_finalized_heights.py",
]
SOURCE = '''package params

const (
    expAddrA = "0x0000000000000000000000000000000000000006"
    expAddrB = "0x0000000000000000000000000000000000000008"
    expAddrC = "0x0000000000000000000000000000000000000017"
)

// Canonical validator-index comments.
// "0x0000000000000000000000000000000000000006": "enode-a", // 6
// "0x0000000000000000000000000000000000000008": "enode-b", // 8
// "0x0000000000000000000000000000000000000017": "enode-c", // 17

// These short address aliases must not overwrite the numeric node mapping.
var AllValidators = map[string]string{
    "0x0000000000000000000000000000000000000006": "enode-a", // 5f
    "0x0000000000000000000000000000000000000008": "enode-b", // 50
    "0x0000000000000000000000000000000000000017": "enode-c", // 511
}

/*
var ValidatorsAddB = map[string]string{
    "0x0000000000000000000000000000000000000017": "enode-c", // 17
}
*/
var ValidatorsAddA = map[string]string{
    "0x0000000000000000000000000000000000000006": "enode-a", // 6
}
var ValidatorsAddB = map[string]string{
    "0x0000000000000000000000000000000000000008": "enode-b", // 8
}

var after410LegacyTargetsA = []string{
    expAddrC,
    // expAddrB,
}
var after410LegacyTargetsB = []string{
    expAddrB,
}
var after411LegacyTargetsA = []string{
    expAddrC,
    // expAddrB,
}
var after411LegacyTargetsB = []string{
    expAddrB,
}
var after487LegacyTargetsA = []string{
    expAddrC,
    // expAddrB,
}
var after487LegacyTargetsB = []string{
    expAddrB,
}
'''


def load_module(name: str):
    path = SCRIPT_DIR / name
    spec = importlib.util.spec_from_file_location(f"finality_parser_{name}", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class FinalityValidatorGroupTest(unittest.TestCase):
    def test_aliases_and_commented_go_do_not_change_numeric_groups(self):
        with tempfile.TemporaryDirectory(prefix="finality-groups-") as tmp:
            validators = Path(tmp) / "validators.go"
            validators.write_text(SOURCE)
            for name in ANALYZERS:
                with self.subTest(script=name):
                    a_nodes, b_nodes = load_module(name).parse_validators(validators)
                    self.assertEqual(a_nodes, {"6", "17"})
                    self.assertEqual(b_nodes, {"8"})
                    self.assertFalse(a_nodes & b_nodes)


if __name__ == "__main__":
    unittest.main()
