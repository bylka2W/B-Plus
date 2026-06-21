1..5 | ForEach-Object {
    $i = $_
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Get-Content go_50k.txt | .\dot_speed.exe > $null
    $sw.Stop()
    Write-Host "Run $i`: $($sw.ElapsedMilliseconds) ms"
}
