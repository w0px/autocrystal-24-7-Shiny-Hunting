param([int]$Port = 5012)
# Sends a few lines to a running overlay relay the way the bot does
# (comm.httpPost's "payload=<urlencoded JSON>"), for trying the page in OBS.
Add-Type -AssemblyName System.Web
$lines = @(
    "Hello! I'm hunting for shiny Pokemon, all by myself.",
    "Sentret shows up during the day on Route 29. Hunting there until 18:00.",
    "Joey wants a rematch! 4 Poke Balls left, so I'm heading to Route 30.",
    "A phone call... pressing through it, then walking on."
)
foreach ($line in $lines) {
    $json = @{ say = $line } | ConvertTo-Json -Compress
    $body = "payload=" + [System.Web.HttpUtility]::UrlEncode($json)
    $reply = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/" -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
    Write-Host "$($reply.Content): $line"
    Start-Sleep -Seconds 4
}
