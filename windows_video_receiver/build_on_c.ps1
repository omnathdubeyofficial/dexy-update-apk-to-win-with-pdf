$ErrorActionPreference = "Continue"

$srcDir = "C:\Users\omnat\OneDrive\Desktop\Dex Dev\Dex Official\Dexy Update APK To Win With PDF\windows_video_receiver"
$buildDir = "C:\dexy_win_build"
$outputDir = Join-Path $srcDir "build\windows\x64\runner\Release"

if (!(Test-Path $srcDir)) {
    Write-Host "Source folder not found: $srcDir" -ForegroundColor Red
    exit 1
}

Get-Process windows_video_receiver, DexyMusic -ErrorAction SilentlyContinue | Stop-Process -Force

if (Test-Path $buildDir) {
    Remove-Item -Recurse -Force $buildDir
}
New-Item -ItemType Directory -Path $buildDir | Out-Null

Write-Host "Copying project to $buildDir ..." -ForegroundColor Cyan
robocopy $srcDir $buildDir /E /MT /R:1 /W:1 /NFL /NDL /NJH /NJS /XD .dart_tool build .idea .git installer ephemeral linux macos ios android web
if ($LASTEXITCODE -ge 8) {
    Write-Host "Robocopy failed with code $LASTEXITCODE" -ForegroundColor Red
    exit 1
}

Get-ChildItem $buildDir -Recurse -Force -Directory -Filter ".plugin_symlinks" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force

Set-Location $buildDir
Write-Host "Running flutter pub get ..." -ForegroundColor Cyan
flutter pub get
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Get-ChildItem $buildDir -Recurse -Force -Directory -Filter ".plugin_symlinks" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force

$env:CMAKE_POLICY_VERSION_MINIMUM = "3.5"
Write-Host "Building Windows release ..." -ForegroundColor Cyan
flutter build windows --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (!(Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
Copy-Item -Path "$buildDir\build\windows\x64\runner\Release\*" -Destination $outputDir -Recurse -Force

Write-Host ""
Write-Host "BUILD COMPLETE! Output: $outputDir" -ForegroundColor Green
Get-ChildItem $outputDir -Filter "*.exe" | ForEach-Object { Write-Host $_.FullName }
