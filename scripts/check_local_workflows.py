"""Read-only compatibility audit; never submits a prompt or copies private workflow content."""
import argparse
import importlib.util
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("catalog", root / "server/comfyui_pocket/catalog.py")
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)
parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
args = parser.parse_args()
report = {"valid_api_workflows": 0, "editable_fields": 0, "preserved_link_or_array_inputs": 0, "canvas_or_other_files": 0, "invalid_files": []}
for path in args.directory.glob("*.json"):
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        if isinstance(data, dict) and "nodes" in data:
            report["canvas_or_other_files"] += 1
            continue
        prompt = data.get("prompt", data)
        catalog.validate_prompt(prompt)
        report["valid_api_workflows"] += 1
        for node in prompt.values():
            for value in node["inputs"].values():
                if isinstance(value, (str, int, float, bool)):
                    report["editable_fields"] += 1
                elif isinstance(value, list):
                    report["preserved_link_or_array_inputs"] += 1
    except (ValueError, KeyError, AttributeError) as error:
        report["invalid_files"].append({"file": path.name, "error": str(error)})
print(json.dumps(report, ensure_ascii=False, indent=2))
