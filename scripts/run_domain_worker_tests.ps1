# Прогон тестов domain-worker (эквивалент `dart test` без pub.dev).
# Использование:  powershell -File scripts/run_domain_worker_tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$worker = Join-Path $root 'services/domain-worker'
$dart = Join-Path $root '.tools/dart-sdk/bin/dart.exe'
if (-not (Test-Path $dart)) { $dart = 'dart' }

Push-Location $worker
try {
    # Зависимость только path: packages/core — офлайн, сеть/pub.dev не нужны.
    & $dart pub get --offline

    Write-Host '=== dart analyze ===' -ForegroundColor Cyan
    & $dart analyze lib bin test tool

    $failed = @()
    foreach ($t in Get-ChildItem 'test' -Filter '*_test.dart' | Sort-Object Name) {
        Write-Host "=== $($t.Name) ===" -ForegroundColor Cyan
        & $dart "test/$($t.Name)"
        if ($LASTEXITCODE -ne 0) { $failed += $t.Name }
    }

    Write-Host '=== эталонные числа (домен + HTTP) ===' -ForegroundColor Cyan
    & $dart tool/verify_reference.dart --http
    if ($LASTEXITCODE -ne 0) { $failed += 'verify_reference' }

    Write-Host '=== расчётный путь: импорт → лечение → массив → раскрой → ТЭО ===' -ForegroundColor Cyan
    & $dart tool/verify_calculation_path.dart
    if ($LASTEXITCODE -ne 0) { $failed += 'verify_calculation_path' }

    Write-Host '=== отчёты: PDF (кириллица) / XLSX / DXF ===' -ForegroundColor Cyan
    & $dart tool/verify_reports.dart
    if ($LASTEXITCODE -ne 0) { $failed += 'verify_reports' }

    if ($failed.Count -eq 0) {
        Write-Host 'ALL PASS (domain-worker)' -ForegroundColor Green
        exit 0
    } else {
        Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}
