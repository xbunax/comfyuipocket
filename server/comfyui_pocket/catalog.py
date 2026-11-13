import json
import os
import re
import tempfile
import uuid
from pathlib import Path

VERSION = "0.1.0"
MAX_BYTES = 20 * 1024 * 1024
ID_PATTERN = re.compile(r"^[a-f0-9]{32}$")


def validate_prompt(prompt):
    if not isinstance(prompt, dict) or not prompt:
        raise ValueError("prompt must be a non-empty ComfyUI API graph")
    for node_id, node in prompt.items():
        if not isinstance(node_id, str) or not isinstance(node, dict):
            raise ValueError("invalid node")
        if not isinstance(node.get("class_type"), str) or not node["class_type"]:
            raise ValueError(f"node {node_id} has no class_type")
        if not isinstance(node.get("inputs"), dict):
            raise ValueError(f"node {node_id} has no inputs object")
    return prompt


class Catalog:
    def __init__(self, root):
        self.root = Path(root).resolve()

    def path(self, workflow_id):
        if not isinstance(workflow_id, str) or not ID_PATTERN.fullmatch(workflow_id):
            raise ValueError("invalid workflow id")
        path = (self.root / f"{workflow_id}.json").resolve()
        if path.parent != self.root:
            raise ValueError("workflow path escapes catalog")
        return path

    def list(self):
        items = []
        if self.root.exists():
            for path in self.root.glob("*.json"):
                try:
                    value = self.get(path.stem)
                    items.append({"id": value["id"], "name": value["name"], "nodes": len(value["prompt"])})
                except (ValueError, OSError, KeyError):
                    continue
        return sorted(items, key=lambda item: item["name"].casefold())

    def get(self, workflow_id):
        path = self.path(workflow_id)
        if path.stat().st_size > MAX_BYTES:
            raise ValueError("workflow exceeds 20 MiB")
        with path.open(encoding="utf-8") as stream:
            value = json.load(stream)
        validate_prompt(value.get("prompt"))
        return value

    def save(self, data):
        if not isinstance(data, dict):
            raise ValueError("expected JSON object")
        name = data.get("name", "Untitled")
        if not isinstance(name, str) or not name.strip() or len(name) > 200:
            raise ValueError("name must be 1–200 characters")
        workflow_id = data.get("id") or uuid.uuid4().hex
        path = self.path(workflow_id)
        value = {"id": workflow_id, "name": name.strip(), "prompt": validate_prompt(data.get("prompt"))}
        if "workflow" in data:
            value["workflow"] = data["workflow"]
        encoded = json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
        if len(encoded) > MAX_BYTES:
            raise ValueError("workflow exceeds 20 MiB")
        self.root.mkdir(parents=True, exist_ok=True)
        temp = None
        try:
            with tempfile.NamedTemporaryFile(dir=self.root, prefix=".pocket-", suffix=".tmp", delete=False) as stream:
                temp = Path(stream.name)
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp, path)
        finally:
            if temp is not None and temp.exists():
                temp.unlink()
        return value

    def delete(self, workflow_id):
        self.path(workflow_id).unlink()
