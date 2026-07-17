$bytes = [System.IO.File]::ReadAllBytes("$PWD\test_for2.exe")
$code_off = 0x200
$start = 0x258
$end = $start + 80
for ($j = $start; $j -lt $end; $j += 16) {
    $line = "0x$('{0:X4}' -f $j):"
    $max = [Math]::Min($j + 16, $end)
    for ($k = $j; $k -lt $max; $k++) {
        $line += " $('{0:X2}' -f $bytes[$code_off + $k])"
    }
    Write-Host $line
}
