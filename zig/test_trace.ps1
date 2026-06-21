$bytes = [System.IO.File]::ReadAllBytes("$PWD\test_for2.exe")
$code_off = 0x200
$code_len = 5212

# Entry point: first instruction in code section
# PE image base = 0x400000 (typical), code RVA = 0x1000
# So code section starts at file offset 0x200, RVA 0x1000

# Find the print("ok") string in the binary
for ($i = 0x200; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -eq [byte][char]'o' -and $bytes[$i+1] -eq [byte][char]'k' -and $bytes[$i+2] -eq 0) {
        Write-Host "'ok\0' at file offset 0x$('{0:X}' -f $i)"
    }
}
for ($i = 0x200; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -eq [byte][char]'X' -and $bytes[$i+1] -eq 0) {
        Write-Host "'X\0' at file offset 0x$('{0:X}' -f $i)"
        break
    }
}

# Find LEA instructions referencing "ok" string
# LEA RDX, [rip+disp] = 48 8D 15 xx xx xx xx
$ok_offset = 0x11A8  # will be set after finding ok
for ($i = $code_off; $i -lt $code_off + $code_len - 7; $i++) {
    if ($bytes[$i] -eq 0x48 -and $bytes[$i+1] -eq 0x8D -and $bytes[$i+2] -eq 0x15) {
        $disp = [System.BitConverter]::ToInt32($bytes, $i+3)
        $target = ($i + 7) + $disp
        if ($target -eq 0x11A8) {
            Write-Host "LEA RDX,[rip+0x$('{0:X}' -f $disp)] at file offset 0x$('{0:X}' -f $i), target='ok'"
        }
    }
}
