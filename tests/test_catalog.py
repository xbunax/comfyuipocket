import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("catalog", ROOT / "server/comfyui_pocket/catalog.py")
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)

PROMPT = {"1": {"class_type": "CLIPTextEncode", "inputs": {"text": "测试", "clip": ["2", 1], "seed": 9007199254740993}}}


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = catalog.Catalog(self.temp.name)

    def test_roundtrip_preserves_graph_links_and_integer_precision(self):
        value = self.store.save({"name": "测试工作流", "prompt": PROMPT})
        self.assertEqual(self.store.get(value["id"])["prompt"], PROMPT)
        self.assertEqual(self.store.list()[0]["nodes"], 1)
        self.assertEqual(len(list(pathlib.Path(self.temp.name).glob("*.tmp"))), 0)

    def test_overwrite_and_delete(self):
        first = self.store.save({"name": "One", "prompt": PROMPT})
        second = self.store.save({**first, "name": "Two"})
        self.assertEqual(second["id"], first["id"])
        self.assertEqual(self.store.list()[0]["name"], "Two")
        self.store.delete(first["id"])
        self.assertEqual(self.store.list(), [])

    def test_path_traversal_is_rejected(self):
        for key in ["../outside", "/tmp/file", "..%2foutside", "A" * 32, "x", ""]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.store.get(key)

    def test_reject_ui_graph_and_malformed_prompt(self):
        for prompt in [{}, {"nodes": []}, {"1": {"class_type": "X"}}, {"1": {"class_type": 42, "inputs": {}}}]:
            with self.subTest(prompt=prompt), self.assertRaises(ValueError):
                self.store.save({"name": "Bad", "prompt": prompt})

    def test_reject_nonfinite_values_and_large_payload(self):
        with self.assertRaises(ValueError):
            self.store.save({"name": "Bad", "prompt": {"1": {"class_type": "X", "inputs": {"x": float("nan")}}}})
        with self.assertRaises(ValueError):
            self.store.save({"name": "Bad", "prompt": PROMPT, "workflow": "x" * catalog.MAX_BYTES})

    def test_invalid_catalog_entry_does_not_break_listing(self):
        pathlib.Path(self.temp.name, "f" * 32 + ".json").write_text("not json")
        self.store.save({"name": "OK", "prompt": PROMPT})
        self.assertEqual(len(self.store.list()), 1)


if __name__ == "__main__":
    unittest.main()
