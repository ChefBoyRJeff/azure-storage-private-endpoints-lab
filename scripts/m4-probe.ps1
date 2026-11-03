# P7 M4 network probe. Runs INSIDE vm-pe-test via Run Command (Windows PowerShell 5.1).
# Prints DNS answers, TCP reachability and a managed-identity blob read. Never prints the token.
$ErrorActionPreference = 'Continue'
$acct = 'stpelabjj1103'

foreach ($svc in 'blob', 'file') {
    $h = "$acct.$svc.core.windows.net"
    try {
        $r = Resolve-DnsName $h -ErrorAction Stop
        $chain = ($r | Where-Object { $_.Type -eq 'CNAME' } | ForEach-Object { $_.NameHost }) -join ' -> '
        $ip = ($r | Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }) -join ','
        "DNS  $svc : A=$ip | cname chain=[$chain]"
    } catch { "DNS  $svc : FAILED $($_.Exception.Message)" }
}

$t = Test-NetConnection "$acct.blob.core.windows.net" -Port 443 -WarningAction SilentlyContinue
"TCP  443 blob: $($t.TcpTestSucceeded)"
$t = Test-NetConnection "$acct.file.core.windows.net" -Port 445 -WarningAction SilentlyContinue
"TCP  445 file: $($t.TcpTestSucceeded)"

$tok = $null
try {
    $tok = (Invoke-RestMethod -Headers @{ Metadata = 'true' } -TimeoutSec 10 `
        -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/').access_token
    'MI   token: acquired (not printed)'
} catch { "MI   token: FAILED $($_.Exception.Message)" }

if ($tok) {
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Uri "https://$acct.blob.core.windows.net/tiers/hot.txt" `
            -Headers @{ Authorization = "Bearer $tok"; 'x-ms-version' = '2023-11-03' }
        "HTTP MI read tiers/hot.txt: $($resp.StatusCode) content=[$($resp.Content.Trim())]"
    } catch {
        $code = $null
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        if ($code) { "HTTP MI read tiers/hot.txt: $code (service reached, request refused)" }
        else { "HTTP MI read tiers/hot.txt: NO RESPONSE ($($_.Exception.Message))" }
    }
}
