$bytes = [System.IO.File]::ReadAllBytes("$PWD\test_for2.exe")
$code_off = 0x200
$code_len = 5212

# Find "ok" string in code/data
$ok_idx = -1
for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
    if ($bytes[$i] -eq [byte][char]'o' -and $bytes[$i+1] -eq [byte][char]'k') {
        # Check if this is part of instruction or string literal
        # Look for pattern: string in rdata
        if ($i -ge 0x600 -and $i -le $bytes.Length) {  # likely beyond code
            Write-Host "Found 'ok' at file offset 0x$('{0:X}' -f $i)"
        }
    }
}

# Find "X" string
for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
    if ($bytes[$i] -eq [byte][char]'X' -and $bytes[$i+1] -eq 0) {
        Write-Host "Found 'X\0' at file offset 0x$('{0:X}' -f $i)"
    }
}
