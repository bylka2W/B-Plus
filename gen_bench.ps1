$sb = [System.Text.StringBuilder]::new()
for ($i = 0; $i -lt 500; $i++) {
    $next = ($i + 1) % 500
    $annot = ""
    if ($i -lt 50) { $annot = "    @hot(0.95)`n" }
    elseif ($i -gt 450) { $annot = "    @cold(0.01)`n" }
    [void]$sb.AppendLine("state State$i {")
    [void]$sb.AppendLine("    var x: int = $i")
    [void]$sb.AppendLine("${annot}    on tick -> State$next { x = x + 1 }")
    [void]$sb.AppendLine("}")
    [void]$sb.AppendLine()
}
[void]$sb.AppendLine("entry main { run }")
Set-Content -Path "bench_real.bp" -Value $sb.ToString()
Write-Host "Done: bench_real.bp"