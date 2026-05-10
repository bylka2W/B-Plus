param([string]$Configuration = "Release")

$root = Split-Path -Parent $PSCommandPath
$proj = "$root\BPlusLanguage\BPlusLanguage.csproj"
$out = "$root\BPlusLanguage\bin\$Configuration"
$vsix = "$root\..\..\BPlusLanguage.vsix"

# Build the project
$msbuild = "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe"
& $msbuild $proj /p:Configuration=$Configuration /t:Build /v:minimal /noconlog
if ($LASTEXITCODE -ne 0) { Write-Error "Build failed"; exit 1 }

# Create VSIX
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

Remove-Item -Path $vsix -Force -ErrorAction SilentlyContinue

$zip = [System.IO.Compression.ZipFile]::Open($vsix, [System.IO.Compression.ZipArchiveMode]::Create)

# [Content_Types].xml
$entry = $zip.CreateEntry("[Content_Types].xml")
$w = New-Object System.IO.StreamWriter($entry.Open())
$w.Write('<?xml version="1.0" encoding="utf-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="vsixmanifest" ContentType="text/xml" /><Default Extension="dll" ContentType="application/octet-stream" /></Types>')
$w.Close()

# extension.vsixmanifest
$entry = $zip.CreateEntry("extension.vsixmanifest")
$w = New-Object System.IO.StreamWriter($entry.Open())
$w.Write([System.IO.File]::ReadAllText("$root\BPlusLanguage\source.extension.vsixmanifest"))
$w.Close()

# BPlusLanguage.dll
$entry = $zip.CreateEntry("BPlusLanguage.dll")
$bytes = [System.IO.File]::ReadAllBytes("$out\BPlusLanguage.dll")
$s = $entry.Open()
$s.Write($bytes, 0, $bytes.Length)
$s.Close()

$zip.Dispose()
Write-Output "VSIX: $vsix ($((Get-Item $vsix).Length) bytes)"