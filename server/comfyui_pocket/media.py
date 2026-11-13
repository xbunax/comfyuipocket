from pathlib import Path, PurePosixPath


MEDIA_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp", ".heic", ".tif", ".tiff",
                    ".mp4", ".mov", ".webm", ".m4v", ".avi", ".mkv"}


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
