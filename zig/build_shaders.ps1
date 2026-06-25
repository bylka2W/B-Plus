$DXC = "C:\tools\DXC\build\native\bin\x64\dxc.exe"
$SRC = "shaders\fsr2"
$DST = "shaders\cso"

if (-not (Test-Path $DST)) { New-Item -ItemType Directory -Path $DST -Force | Out-Null }

$shaders = @(
    @{src="fsr2_accumulate.hlsl";     dst="fsr2_accumulate.cso";     profile="cs_6_6"},
    @{src="fsr2_rcas.hlsl";           dst="fsr2_rcas.cso";           profile="cs_6_6"},
    @{src="fsr2_depthclip.hlsl";      dst="fsr2_depthclip.cso";      profile="cs_6_6"},
    @{src="fsr2_lock.hlsl";           dst="fsr2_lock.cso";           profile="cs_6_6"},
    @{src="fsr2_reconstruct_depth.hlsl"; dst="fsr2_reconstruct_depth.cso"; profile="cs_6_6"},
    @{src="fsr2_dilate_velocity.hlsl";   dst="fsr2_dilate_velocity.cso";   profile="cs_6_6"},
    @{src="fsr2_luminance_pyramid.hlsl"; dst="fsr2_luminance_pyramid.cso"; profile="cs_6_6"},
    @{src="fsr2_easu.hlsl";           dst="fsr2_easu.cso";           profile="cs_6_6"}
)

foreach ($s in $shaders) {
    $srcPath = "$SRC\$($s.src)"
    $dstPath = "$DST\$($s.dst)"
    Write-Host "Compiling $srcPath -> $dstPath"
    & $DXC -T $s.profile -E main -Fo $dstPath $srcPath
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $($s.src)"
    } else {
        Write-Host "OK: $($s.src)"
    }
}

Write-Host "Done."
