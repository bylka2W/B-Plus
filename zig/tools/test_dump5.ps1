$bytes = [System.IO.File]::ReadAllBytes("$PWD\test_for2.exe")

# The JMP instruction at file offset 0x453 (code 0x253)
Write-Host "JMP instruction at 0x453:"
for ($i = 0x453; $i -lt 0x458; $i++) { Write-Host -NoNewline " $('{0:X2}' -f $bytes[$i])" }
Write-Host ""

# Next instruction after JMP at 0x458 (code 0x258) 
Write-Host "Bytes at 0x458 (end_lbl should be here):"
for ($i = 0x458; $i -lt 0x470; $i++) { Write-Host -NoNewline " $('{0:X2}' -f $bytes[$i])" }
Write-Host ""

# JGE instruction at file offset 0x3E4 (code 0x1E4)
Write-Host "JGE instruction at 0x3E4:"
for ($i = 0x3E4; $i -lt 0x3EA; $i++) { Write-Host -NoNewline " $('{0:X2}' -f $bytes[$i])" }
Write-Host ""

# The target of JGE at 0x3EA + 0x73 = 0x45D (code 0x25D)
Write-Host "JGE target at 0x45D (code 0x25D):"
for ($i = 0x45D; $i -lt 0x475; $i++) { Write-Host -NoNewline " $('{0:X2}' -f $bytes[$i])" }
Write-Host ""
