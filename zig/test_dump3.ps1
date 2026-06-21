$bytes = [System.IO.File]::ReadAllBytes("$PWD\test_for2.exe")
$code_off = 0x200
$code_len = 5212
$start = 0x258
$end = [Math]::Min($start + 100, $code_len)
$line = ""
for ($j = $start; $j -lt $end; $j++) {
    $line += " $('{0:X2}' -f $bytes[$code_off + $j])"
    if (($j - $start + 1) % 16 -eq 0 -or $j -eq $end - 1) {
        Write-Host "0x$('{0:X4}' -f $j):$line"
        $line = ""
    }
}
