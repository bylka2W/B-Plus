$bytes = [System.IO.File]::ReadAllBytes("$PWD\test_for2.exe")
$code_off = 0x200
$code_bytes = $bytes[$code_off..($code_off + 5211)]
$idx = 0
while ($idx -lt $code_bytes.Length - 3) {
    if ($code_bytes[$idx] -eq 0x33 -and $code_bytes[$idx+1] -eq 0xC0) {
        # Check if followed by MOV [RBP+...] pattern (89 45 xx or 89 55 xx)
        if ($idx + 4 -lt $code_bytes.Length) {
            if ($code_bytes[$idx+2] -eq 0x89) {
                Write-Host "Found XOR EAX,EAX at code offset 0x$('{0:X}' -f $idx)"
                $end = [Math]::Min($idx + 200, $code_bytes.Length)
                $chunk = $code_bytes[$idx..($end-1)]
                $line = ""
                for ($j = 0; $j -lt $chunk.Length; $j++) {
                    $line += " $('{0:X2}' -f $chunk[$j])"
                    if (($j + 1) % 16 -eq 0 -or $j -eq $chunk.Length - 1) {
                        Write-Host "0x$('{0:X4}' -f ($idx + $j - ($j % 16))):$line"
                        $line = ""
                    }
                }
                break
            }
        }
    }
    $idx++
}
