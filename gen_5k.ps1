$sb = [System.Text.StringBuilder]::new()
for ($i = 0; $i -lt 5000; $i++) {
    $next = ($i + 1) % 5000
    $hot = if ($i -lt 500) { "@hot(0.95)`n    " } else { "" }
    $cold = if ($i -gt 4500) { "@cold(0.01)`n    " } else { "" }
    [void]$sb.AppendLine("state State$i {")
    [void]$sb.AppendLine("    ${hot}${cold}var x: int = $i")
    [void]$sb.AppendLine("    on tick -> State$next { x = x + 1 }")
    [void]$sb.AppendLine("}")
    [void]$sb.AppendLine()
}
[void]$sb.AppendLine("entry main { run }")
Set-Content -Path "bench_5k.bp" -Value $sb.ToString()
Write-Host "Done: bench_5k.bp"