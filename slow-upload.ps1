<#
.SYNOPSIS
    Reproduces BadHttpRequestException: MinRequestBodyDataRate against the
    UploadContent endpoint by uploading a request body slower than Kestrel's
    default minimum data rate (240 bytes/sec, 5 second grace period).

.DESCRIPTION
    Opens a raw TCP connection to the running Functions host, sends HTTP request
    headers with a Content-Length, then trickles the body a few bytes at a time
    with sleeps in between. Because the average rate stays below 240 B/s for more
    than 5 seconds, the worker's Kestrel aborts the request with:

        Reading the request body timed out due to data arriving too slowly.
        See MinRequestBodyDataRate.

.EXAMPLE
    # 1. Start the app in another terminal:
    #      func start   (or: dotnet run)
    # 2. Then run:
    #      ./slow-upload.ps1
#>

param(
    [string]$FunctionHost = "localhost",
    [int]$Port = 8080,
    [string]$Path = "/api/UploadContent",
    # Total number of body bytes we claim to send via Content-Length.
    [int]$ContentLength = 2000,
    # Bytes sent per chunk.
    [int]$ChunkSize = 8,
    # Delay between chunks (seconds). 8 bytes / 3s ~= 2.6 B/s, well under 240 B/s.
    [double]$DelaySeconds = 3
)

$ErrorActionPreference = "Stop"

Write-Host "Connecting to $FunctionHost`:$Port ..." -ForegroundColor Cyan
$client = [System.Net.Sockets.TcpClient]::new()
$client.Connect($FunctionHost, $Port)
$stream = $client.GetStream()

function Send-Bytes([byte[]]$bytes) {
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

# Send request line + headers.
$headers =
    "POST $Path HTTP/1.1`r`n" +
    "Host: $FunctionHost`:$Port`r`n" +
    "Content-Type: application/octet-stream`r`n" +
    "Content-Length: $ContentLength`r`n" +
    "Connection: close`r`n" +
    "`r`n"

Send-Bytes ([System.Text.Encoding]::ASCII.GetBytes($headers))
Write-Host "Headers sent. Content-Length=$ContentLength. Now trickling body..." -ForegroundColor Yellow

$sent = 0
$chunk = [byte[]]::new($ChunkSize)
for ($i = 0; $i -lt $ChunkSize; $i++) { $chunk[$i] = 65 } # 'A'

try {
    while ($sent -lt $ContentLength) {
        $remaining = $ContentLength - $sent
        $toSend = [Math]::Min($ChunkSize, $remaining)
        $stream.Write($chunk, 0, $toSend)
        $stream.Flush()
        $sent += $toSend

        $rate = [Math]::Round($toSend / $DelaySeconds, 2)
        Write-Host ("Sent {0}/{1} bytes (~{2} B/s)" -f $sent, $ContentLength, $rate)
        Start-Sleep -Seconds $DelaySeconds
    }

    Write-Host "Finished sending body. Reading response..." -ForegroundColor Cyan
}
catch {
    Write-Host "Send loop aborted (server likely closed the connection): $_" -ForegroundColor Red
}

# Read whatever the server sends back (may be a 400/500 or a reset).
try {
    $reader = [System.IO.StreamReader]::new($stream)
    $response = $reader.ReadToEnd()
    Write-Host "`n--- Server response ---" -ForegroundColor Green
    Write-Host $response
}
catch {
    Write-Host "Could not read response: $_" -ForegroundColor Red
}
finally {
    $stream.Dispose()
    $client.Dispose()
}
