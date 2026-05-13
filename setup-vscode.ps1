# B+ Language — VS Code Extension Installer
# Run: powershell -ExecutionPolicy Bypass -File setup-vscode.ps1

$ErrorActionPreference = "Stop"
$VSCodeDir = "$env:USERPROFILE\.vscode\extensions\bplus-lsp"
$BpcExe = ".\src\BPlusTranspiler\bin\Debug\net8.0\bpc.exe"

Write-Host "╔════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   B+ v2.5.0GH — VS Code Installer     ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# 1. Build project if needed
if (-not (Test-Path $BpcExe)) {
    Write-Host "→ Building B+ transpiler..." -ForegroundColor Yellow
    Push-Location src\BPlusTranspiler
    dotnet build --configuration Debug --output bin\Debug\net8.0
    Pop-Location
    if (-not (Test-Path $BpcExe)) {
        Write-Host "✗ Build failed. Install .NET 8 SDK from https://dotnet.microsoft.com/download" -ForegroundColor Red
        exit 1
    }
    Write-Host "  ✓ Build complete" -ForegroundColor Green
}

# 2. Install VS Code extension
Write-Host "→ Installing VS Code extension..." -ForegroundColor Yellow
Push-Location src\BPlusTranspiler
try {
    dotnet run --project BPlusTranspiler.csproj -- --install-lsp 2>&1 | ForEach-Object { Write-Host "  $_" }
}
catch {
    # --install-lsp may fail if npm not found; try direct install
    Write-Host "  ⚠ Trying direct extension creation..." -ForegroundColor Yellow
    dotnet run --project BPlusTranspiler.csproj -- --install-lsp 2>$null
}
Pop-Location

# 3. Verify installation
if (Test-Path "$VSCodeDir\package.json") {
    Write-Host ""
    Write-Host "✓ Extension installed successfully!" -ForegroundColor Green
    Write-Host "  Location: $VSCodeDir"
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor White
    Write-Host "  1. Restart VS Code"
    Write-Host "  2. Open a .bp file"
    Write-Host "  3. You'll get syntax highlighting + LSP (errors, completions)"
    Write-Host ""
    Write-Host "Optional: Build self-contained binary (no .NET required on target):"
    Write-Host "  cd src\BPlusTranspiler && dotnet publish --self-contained -r win-x64 -c Release"
    Write-Host ""
}
else {
    Write-Host "✗ Extension directory not found. Try manual install:" -ForegroundColor Red
    Write-Host "  cd src\BPlusTranspiler && dotnet run -- --install-lsp"
    exit 1
}
