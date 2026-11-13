param([string]$ComfyUIPath = 'D:\AI_video\ComfyUI')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repo 'server\comfyui_pocket'
$root = (Resolve-Path -LiteralPath $ComfyUIPath).Path
if (-not (Test-Path -LiteralPath (Join-Path $root 'main.py'))) { throw 'Not a ComfyUI directory.' }
$target = Join-Path $root 'custom_nodes\comfyui_pocket'
if (Test-Path -LiteralPath $target) { throw "Plugin already exists at $target. Review/backup the existing folder before replacing it." }
New-Item -ItemType Directory -Path $target | Out-Null
foreach ($relative in @('__init__.py', 'catalog.py', 'routes.py', 'README.md', 'web\pocket.js')) {
    $destination = Join-Path $target $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $destination
}
Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination (Join-Path $target 'LICENSE')
Write-Output "Installed: $target. Restart ComfyUI to enable Pocket."
