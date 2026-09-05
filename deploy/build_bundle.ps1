# Bundle builder (Windows). ASCII-only on purpose (PS 5.1 + UTF-8 pitfall).
# Run:  powershell -ExecutionPolicy Bypass -File build_bundle.ps1
# Expects web build at ..\..\app\build\web (relative to deploy\).
# Result: ..\..\pp-new-server-stack.tar.gz
$ErrorActionPreference = "Stop"
$deploy = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $deploy
$web = Join-Path $root "app\build\web"

if (-not (Test-Path (Join-Path $web "index.html"))) {
  Write-Error "Web build not found: $web (run 'flutter build web' first)"
  exit 1
}

$stage = Join-Path $env:TEMP ("ppstack-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path "$stage\stack\deploy", "$stage\stack\services" | Out-Null
try {
  Copy-Item "$deploy\*" "$stage\stack\deploy\" -Recurse -Force
  Copy-Item $web "$stage\stack\deploy\web" -Recurse -Force
  Copy-Item "$root\services\converter" "$stage\stack\services\" -Recurse -Force
  Copy-Item "$root\services\auth" "$stage\stack\services\" -Recurse -Force
  Copy-Item "$root\services\payments" "$stage\stack\services\" -Recurse -Force

  Get-ChildItem $stage -Recurse -Directory -Force |
    Where-Object { $_.Name -in @("__pycache__", ".pytest_cache", "data") } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  Get-ChildItem $stage -Recurse -File -Force |
    Where-Object { $_.Extension -in @(".pyc", ".db") } |
    Remove-Item -Force -ErrorAction SilentlyContinue

  Push-Location $stage
  tar -czf "$root\pp-new-server-stack.tar.gz" stack
  Pop-Location
  $size = [math]::Round((Get-Item "$root\pp-new-server-stack.tar.gz").Length / 1MB, 1)
  Write-Output ("Bundle ready: " + $root + "\pp-new-server-stack.tar.gz (" + $size + " MB)")
} finally {
  Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}
