import os
import hashlib
import shutil
import tempfile
from pathlib import Path, PurePosixPath


MEDIA_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".heic", ".tif", ".tiff",
                    ".mp4", ".mov", ".webm", ".m4v", ".avi", ".mkv"}


def linked(path):
    return path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction())


def list_output(directory, folder="", offset=0, limit=60, sort="time", direction="descending"):
    """List one output directory, without following links or scanning descendants."""
    if (not isinstance(folder, str) or any(c in folder for c in "\\:\x00\r\n")
            or folder.startswith("/") or any(p in (".", "..") for p in folder.split("/"))):
        raise ValueError("Invalid output folder")
    if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 100:
        raise ValueError("Invalid page")
    if sort not in ("time", "name", "size") or direction not in ("ascending", "descending"):
        raise ValueError("Invalid sort order")
    root = Path(directory).resolve()
    relative = PurePosixPath(folder)
    current = root
    for part in relative.parts:
        current /= part
        if linked(current):
            raise ValueError("Linked folders cannot be browsed")
    current = current.resolve()
    if current != root and root not in current.parents:
        raise ValueError("Output folder escapes its directory")
    if not current.is_dir():
        raise FileNotFoundError("Output folder not found")
    folder = current.relative_to(root).as_posix() if current != root else ""
    entries = []
    with os.scandir(current) as children:
        for child in children:
            try:
                path = Path(child.path)
                if linked(path) or any(c in child.name for c in "\\:\x00\r\n"):
                    continue
                is_folder = child.is_dir(follow_symlinks=False)
                if not is_folder and (not child.is_file(follow_symlinks=False)
                                      or path.suffix.lower() not in MEDIA_EXTENSIONS):
                    continue
                stat = child.stat(follow_symlinks=False)
                entries.append({"name": child.name, "path": f"{folder}/{child.name}" if folder else child.name,
                                "kind": "folder" if is_folder else "file", "subfolder": folder,
                                "size": 0 if is_folder else stat.st_size,
                                "modified": stat.st_mtime_ns // 1_000_000})
            except OSError:
                continue  # A concurrently removed or inaccessible file must not break the page.
    # Apply a stable directory-wide sort BEFORE slicing pages. Folders stay first.
    def key(item):
        value = {"time": item["modified"], "name": item["name"].casefold(), "size": item["size"]}[sort]
        return value, item["name"].casefold(), item["name"]
    folders = sorted((item for item in entries if item["kind"] == "folder"), key=key, reverse=direction == "descending")
    files = sorted((item for item in entries if item["kind"] == "file"), key=key, reverse=direction == "descending")
    entries = folders + files
    return {"folder": folder, "entries": entries[offset:offset + limit], "total": len(entries),
            "nextOffset": offset + limit if offset + limit < len(entries) else None}


def media_path(data, directories):
    if not isinstance(data, dict):
        raise ValueError("Expected a media object")
    kind = data.get("type", "output")
    filename = data.get("filename")
    subfolder = data.get("subfolder", "")
    if not isinstance(kind, str) or kind not in directories:
        raise ValueError("Unsupported media directory")
    if not isinstance(filename, str) or not filename or any(c in filename for c in "/\\:\x00\r\n"):
        raise ValueError("Invalid filename")
    if not isinstance(subfolder, str) or any(c in subfolder for c in "\\:\x00\r\n"):
        raise ValueError("Invalid subfolder")
    relative = PurePosixPath(subfolder)
    if relative.is_absolute() or any(p in (".", "..") for p in subfolder.split("/")) or Path(filename).suffix.lower() not in MEDIA_EXTENSIONS:
        raise ValueError("Invalid media path")
    root = Path(directories[kind]).resolve()
    candidate = root
    for part in (*relative.parts, filename):
        candidate = candidate / part
        if linked(candidate):
            raise ValueError("Linked media cannot be used through this endpoint")
    resolved = candidate.resolve()
    if root not in resolved.parents:
        raise ValueError("Media path escapes its directory")
    if resolved.exists() and not resolved.is_file():
        raise ValueError("Expected a media file")
    return resolved


def delete_media(data, directories):
    resolved = media_path(data, {kind: path for kind, path in directories.items() if kind in ("output", "temp")})
    try:
        resolved.unlink()
    except FileNotFoundError:
        return {"deleted": True, "alreadyMissing": True}
    return {"deleted": True}


def import_media(data, directories):
    """Make an existing server asset available to a node that expects input media."""
    source = media_path(data, directories)
    info = source.stat()
    root = Path(directories["input"]).resolve()
    if data.get("type") == "input":
        return {"value": source.relative_to(root).as_posix()}
    revision = f"{source}:{info.st_size}:{info.st_mtime_ns}"
    key = hashlib.sha256(revision.encode()).hexdigest()[:20]
    dest = root / f"pocket-{key}{source.suffix.lower()}"
    if linked(dest) or (dest.exists() and not dest.is_file()):
        raise ValueError("Invalid imported media destination")
    if not dest.exists():
        with source.open("rb") as reader, tempfile.NamedTemporaryFile(dir=root, delete=False) as target:
            stage = Path(target.name)
            try:
                shutil.copyfileobj(reader, target, length=1024 * 1024)
                target.close()
                current = source.stat()
                if (info.st_size, info.st_mtime_ns) != (current.st_size, current.st_mtime_ns):
                    raise OSError("Source changed during import")
                os.replace(stage, dest)
            finally:
                target.close()
                stage.unlink(missing_ok=True)
    return {"value": dest.relative_to(root).as_posix()}
