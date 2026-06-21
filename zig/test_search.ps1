$bytes = [System.IO.File]::ReadAllBytes("$PWD\test_for2.exe")
for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
    if ($bytes[$i] -eq [byte][char]'o' -and $bytes[$i+1] -eq [byte][char]'k') {
        Write-Host "Found 'ok' at file offset 0x$('{0:X}' -f $i), next byte=0x$('{0:X2}' -f $bytes[$i+2])"
    }
}
for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
    if ($bytes[$i] -eq [byte][char]'X' -and $bytes[$i+1] -eq 0) {
        Write-Host "Found 'X\0' at file offset 0x$('{0:X}' -f $i)"
    }
}
