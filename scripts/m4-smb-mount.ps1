# P7 M4g: mount labshare over SMB from INSIDE vm-pe-test (Run Command, Windows PowerShell 5.1).
# The storage key arrives as a Run Command parameter; it is never printed. Rotate key1 after this test.
param([string]$k)
$ErrorActionPreference = 'Continue'
$acct = 'stpelabjj1103'
$h = "$acct.file.core.windows.net"

$ip = (Resolve-DnsName $h -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }) -join ','
"DNS  file : A=$ip"
"TCP  445  : $((Test-NetConnection $h -Port 445 -WarningAction SilentlyContinue).TcpTestSucceeded)"
if (-not $k) { 'KEY  : not supplied, stopping'; return }

try {
    $cred = New-Object System.Management.Automation.PSCredential("localhost\$acct", (ConvertTo-SecureString $k -AsPlainText -Force))
    New-PSDrive -Name Z -PSProvider FileSystem -Root "\\$h\labshare" -Credential $cred -ErrorAction Stop | Out-Null
    'MOUNT: Z: -> \\<account>.file.core.windows.net\labshare OK'
    "LIST : $((Get-ChildItem Z:\finance | ForEach-Object { $_.Name }) -join ', ')"
    "READ : report.txt = [$((Get-Content Z:\finance\report.txt) -join ' ')]"
    "P7 M4g written from vm-pe-test over SMB via private endpoint, $(Get-Date -Format o)" | Set-Content Z:\finance\from-vm.txt
    "WRITE: from-vm.txt = [$((Get-Content Z:\finance\from-vm.txt) -join ' ')]"
    $smb = Get-SmbConnection -ServerName $h -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($smb) { "SMB  : dialect=$($smb.Dialect) encrypted=$($smb.Encrypted)" }
    # Share snapshot over SMB ("Previous Versions" path token)
    $tok = '@GMT-2026.11.03-22.43.10'
    try { "SNAP : budget.txt in snapshot $tok = [$((Get-Content "\\$h\labshare\$tok\finance\budget.txt" -ErrorAction Stop) -join ' ')]" }
    catch { "SNAP : snapshot path read failed: $($_.Exception.Message)" }
    Remove-PSDrive Z
    'UNMOUNT: OK'
} catch { "MOUNT: FAILED $($_.Exception.Message)" }
