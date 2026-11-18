import hashlib
import pathlib
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
destination = root / "dist"
destination.mkdir(exist_ok=True)
with zipfile.ZipFile(destination / "comfyui_pocket-plugin.zip", "w", zipfile.ZIP_DEFLATED) as archive:
    for file in sorted((root / "server/comfyui_pocket").rglob("*")):
        if file.is_file() and "__pycache__" not in file.parts and file.suffix != ".pyc":
            archive.write(file, file.relative_to(root / "server").as_posix())
    for name in ("LICENSE", "NOTICE"):
        archive.write(root / name, f"comfyui_pocket/{name}")
print(destination / "comfyui_pocket-plugin.zip")
