import os
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


def delete_media(data, directories):
    if not isinstance(data, dict):
        raise ValueError("Expected a media object")
    kind = data.get("type", "output")
    filename = data.get("filename")
    subfolder = data.get("subfolder", "")
    if kind not in ("output", "temp") or kind not in directories:
        raise ValueError("Only output and temporary media can be deleted")
    if not isinstance(filename, str) or not filename or any(c in filename for c in "/\\:\x00\r\n"):
        raise ValueError("Invalid filename")
    if not isinstance(subfolder, str) or any(c in subfolder for c in "\\:\x00\r\n"):
        raise ValueError("Invalid subfolder")
    relative = PurePosixPath(subfolder)
    if relative.is_absolute() or ".." in relative.parts or Path(filename).suffix.lower() not in MEDIA_EXTENSIONS:
        raise ValueError("Invalid media path")
    root = Path(directories[kind]).resolve()
    candidate = root
    for part in (*relative.parts, filename):
        candidate = candidate / part
        if candidate.is_symlink():
            raise ValueError("Symbolic links cannot be deleted through this endpoint")
    resolved = candidate.resolve()
    if root not in resolved.parents:
        raise ValueError("Media path escapes its directory")
    if not resolved.exists():
        return {"deleted": True, "alreadyMissing": True}
    if not resolved.is_file():
        raise ValueError("Expected a media file")
    resolved.unlink()
    return {"deleted": True}
