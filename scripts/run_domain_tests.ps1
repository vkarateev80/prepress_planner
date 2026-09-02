# Прогон всех тестов домена packages/core (эквивалент `dart test` без pub.dev).
# Использование:  powershell -File scripts/run_domain_tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$core = Join-Path $root 'packages/core'
$dart = Join-Path $root '.tools/dart-sdk/bin/dart.exe'
if (-not (Test-Path $dart)) { $dart = 'dart' }

Push-Location $core
try {
    $tests = Get-ChildItem 'test' -Filter '*_test.dart' | Sort-Object Name
    $failed = @()
    foreach ($t in $tests) {
        Write-Host "=== $($t.Name) ===" -ForegroundColor Cyan
        & $dart "test/$($t.Name)"
        if ($LASTEXITCODE -ne 0) { $failed += $t.Name }
    }
    if ($failed.Count -eq 0) {
        Write-Host "ALL PASS ($($tests.Count) files)" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}
