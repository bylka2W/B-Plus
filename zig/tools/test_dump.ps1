$bytes = [System.IO.File]::ReadAllBytes("$PWD\test_for2.exe")
$pe_sig = [System.BitConverter]::ToUInt32($bytes, 0x3C)
Write-Host "PE signature at: 0x$('{0:X}' -f $pe_sig)"
$num_sections = [System.BitConverter]::ToUInt16($bytes, $pe_sig + 6)
Write-Host "Number of sections: $num_sections"
$opt_hdr_size = [System.BitConverter]::ToUInt16($bytes, $pe_sig + 20)
Write-Host "Optional header size: $opt_hdr_size"
$sect_offset = $pe_sig + 24 + $opt_hdr_size
Write-Host "Section headers at: 0x$('{0:X}' -f $sect_offset)"
for ($i = 0; $i -lt $num_sections; $i++) {
    $so = $sect_offset + $i * 40
    $name = [System.Text.Encoding]::ASCII.GetString($bytes[$so..($so+7)]) -replace "`0", ""
    $vsize = [System.BitConverter]::ToUInt32($bytes, $so + 8)
    $vaddr = [System.BitConverter]::ToUInt32($bytes, $so + 12)
    $rsize = [System.BitConverter]::ToUInt32($bytes, $so + 16)
    $roff = [System.BitConverter]::ToUInt32($bytes, $so + 20)
    Write-Host "Section $name`: VA=0x$('{0:X}' -f $vaddr) Size=$vsize RawOff=0x$('{0:X}' -f $roff) RawSize=$rsize"
}
