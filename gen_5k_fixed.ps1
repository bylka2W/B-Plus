$sb = [System.Text.StringBuilder]::new()
for ($i = 0; $i -lt 5000; $i++) {
    $next = ($i + 1) % 5000
    $annot = ""
    if ($i -lt 500) { $annot = "    @hot(0.95)`n" }
    elseif ($i -gt 4500) { $annot = "    @cold(0.01)`n" }
    [void]$sb.AppendLine("state State$i {")
    [void]$sb.AppendLine("    var x: int = $i")
    [void]$sb.AppendLine("${annot}    on tick -> State$next { x = x + 1 }")
    [void]$sb.AppendLine("}")
    [void]$sb.AppendLine()
}
[void]$sb.AppendLine("entry main { run }")
Set-Content -Path "bench_5k_opt.bp" -Value $sb.ToString()
Write-Host "Done: bench_5k_opt.bp"