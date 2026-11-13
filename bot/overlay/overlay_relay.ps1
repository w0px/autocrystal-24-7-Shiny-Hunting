param(
    # Local port: the bot posts its messages here, and OBS loads the
    # overlay page from here (Browser Source: http://127.0.0.1:5002/).
    # Must match OVERLAY_URL in overlay.lua.
    [int]$ListenPort = 5002,

    # Like the Discord relays: when set (the launcher passes "EmuHawk"), the
    # relay quits by itself once no process with this name runs any more.
    [string]$ExitWhenProcessGone = "",

    # Where to also write what this window shows. Rotated to "<name>.old"
    # past $MaxLogBytes.
    [string]$LogFile = "",
    [long]$MaxLogBytes = 1MB
)

# The overlay relay: a tiny local web server between the bot and OBS.
#   POST /         the bot: payload=<JSON> - {"say": "..."} adds a line
#                  to the text box, {"state": {...}} replaces the state
#                  (both can come in one post)
#   POST /layout   editor.html's Save: writes layout.json (see Handle-SaveLayout)
#   POST /vote     a chat poll or bet for the box over the game: {"vote": {...}}
#                  or {"vote": null} (see Handle-Vote) - the editor's Test
#                  buttons; YouTube chat later
#   GET  /         pokegear.html (the radio card), for OBS's Browser Source
#   GET  /messages ?since=<id> - the lines after that id, and the state
#   GET  /<file>   another page next to this script (pokegear.html?card=...,
#                  clouds.html), or /gfx/<file> - the game graphics
# Only reachable from this PC (127.0.0.1), like the Discord relays.

function Write-Log([string]$Message) {
    Write-Host $Message
    if (-not $LogFile -or -not $Message) { return }
    try {
        Add-Content -LiteralPath $LogFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $Message) -Encoding UTF8
        if ((Get-Item -LiteralPath $LogFile).Length -gt $MaxLogBytes) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
        }
    } catch {
        # A log problem must never take the relay down with it.
    }
}

Add-Type -AssemblyName System.Web

$KeepMessages = 300    # (50 until 2026-11-11: the log shows 8-15 hours - scene.html LOG_KEEP)
$messages = New-Object System.Collections.ArrayList
$nextId = 1
$state = @{}
$vote = $null

$ContentTypes = @{
    ".html" = "text/html; charset=utf-8"; ".css" = "text/css; charset=utf-8"; ".js" = "text/javascript; charset=utf-8"
    ".png" = "image/png"; ".gif" = "image/gif"; ".webp" = "image/webp"; ".ttf" = "font/ttf"; ".woff2" = "font/woff2"
    ".json" = "application/json"; ".pal" = "text/plain; charset=utf-8"; ".rle" = "application/octet-stream"
    ".txt" = "text/plain; charset=utf-8"
}

function Send-Response($context, [int]$status, [string]$contentType, [byte[]]$bytes) {
    $response = $context.Response
    $response.StatusCode = $status
    $response.ContentType = $contentType
    # The page polls; nothing it gets may be cached.
    $response.Headers.Add("Cache-Control", "no-store")
    $response.ContentLength64 = $bytes.Length
    try { $response.OutputStream.Write($bytes, 0, $bytes.Length) } catch {}
    try { $response.OutputStream.Close() } catch {}
}

function Send-Text($context, [int]$status, [string]$contentType, [string]$text) {
    Send-Response $context $status $contentType ([System.Text.Encoding]::UTF8.GetBytes($text))
}

function Add-Message([string]$text) {
    $text = $text.Trim()
    if (-not $text) { return }
    # time: when it came in (Unix seconds) - the overlay's chat shows it.
    [void]$messages.Add([pscustomobject]@{ id = $script:nextId; text = $text; time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() })
    $script:nextId++
    while ($messages.Count -gt $KeepMessages) { $messages.RemoveAt(0) }
    Write-Log "Says: $text"
}

function Handle-Post($context) {
    $reader = New-Object System.IO.StreamReader($context.Request.InputStream, [System.Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close()
    # Answer first: comm.httpPost holds the emulator until it gets one.
    Send-Text $context 200 "text/plain" "ok"

    # BizHawk's comm.httpPost sends "payload=<urlencoded JSON>".
    if ($body -match '^payload=(.*)$') { $json = [System.Web.HttpUtility]::UrlDecode($Matches[1]) } else { $json = $body }
    try { $data = $json | ConvertFrom-Json } catch { Write-Log "Ignoring a malformed post: $json"; return }
    if ($data.say) { Add-Message ([string]$data.say) }
    if ($data.state) {
        $script:state = @{}
        foreach ($p in $data.state.PSObject.Properties) { $script:state[$p.Name] = $p.Value }
    }
}

# The layout editor's Save (editor.html): the whole layout as JSON, written
# to layout.json next to this script - the only file this relay ever
# writes. The page must send an X-Autocrystal header: another website
# can't add one to a request to here without asking first (CORS), and this
# relay never says yes, so only the editor served from here can save.
$MaxLayoutBytes = 64KB
function Handle-SaveLayout($context) {
    if ($context.Request.Headers["X-Autocrystal"] -ne "editor") {
        Send-Text $context 403 "text/plain" "not allowed"
        return
    }
    $reader = New-Object System.IO.StreamReader($context.Request.InputStream, [System.Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close()
    if ($body.Length -gt $MaxLayoutBytes) { Send-Text $context 413 "text/plain" "too big"; return }
    try { $data = $body | ConvertFrom-Json } catch { Send-Text $context 400 "text/plain" "not JSON"; return }
    if (-not $data.panels) { Send-Text $context 400 "text/plain" "no panels"; return }
    [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot "layout.json"), $body, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "Layout saved ($(@($data.panels).Count) panels)."
    Send-Text $context 200 "text/plain" "saved"
}

# A chat poll or bet (scene.html draws it over the game - what's in it is
# described there). Kept apart from the bot's state, which every post of the
# bot replaces. Like the layout's Save it needs an X-Autocrystal header, so
# no website open in a browser on this PC can put text on the stream.
$MaxVoteBytes = 16KB
function Handle-Vote($context) {
    if (-not $context.Request.Headers["X-Autocrystal"]) {
        Send-Text $context 403 "text/plain" "not allowed"
        return
    }
    $reader = New-Object System.IO.StreamReader($context.Request.InputStream, [System.Text.Encoding]::UTF8)
    $body = $reader.ReadToEnd()
    $reader.Close()
    if ($body.Length -gt $MaxVoteBytes) { Send-Text $context 413 "text/plain" "too big"; return }
    try { $data = $body | ConvertFrom-Json } catch { Send-Text $context 400 "text/plain" "not JSON"; return }
    if (-not $data -or -not ($data.PSObject.Properties.Name -contains "vote")) { Send-Text $context 400 "text/plain" "no vote"; return }
    $script:vote = $data.vote
    if ($data.vote) { Write-Log "Vote: $($data.vote.kind) - $($data.vote.question)" } else { Write-Log "Vote: off" }
    # ("vote", not "ok": an older relay answers any post with "ok" - the editor tells them apart)
    Send-Text $context 200 "text/plain" "vote"
}

function Handle-Messages($context) {
    $since = 0
    [void][int]::TryParse($context.Request.QueryString["since"], [ref]$since)
    $newer = @($messages | Where-Object { $_.id -gt $since })
    $reply = [ordered]@{
        latest = $script:nextId - 1
        messages = $newer
        state = $script:state
        vote = $script:vote
    }
    Send-Text $context 200 "application/json; charset=utf-8" (ConvertTo-Json $reply -Depth 5 -Compress)
}

function Handle-File($context, [string]$path) {
    if ($path -eq "/" -or $path -eq "") { $path = "/pokegear.html" }
    # Only files next to this script or in its gfx folder, of the kinds
    # above: plain names, no "..", nothing else on the PC.
    $parts = @($path.TrimStart("/").Split("/"))
    $okPath = ($parts.Count -eq 1 -or ($parts.Count -eq 2 -and $parts[0] -eq "gfx")) -and
        -not ($parts | Where-Object { $_ -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]*$' })
    $file = if ($okPath) { Join-Path $PSScriptRoot ($parts -join "\") } else { "" }
    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if (-not $okPath -or -not $ContentTypes.ContainsKey($ext) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Send-Text $context 404 "text/plain" "not found"
        return
    }
    Send-Response $context 200 $ContentTypes[$ext] ([System.IO.File]::ReadAllBytes($file))
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$ListenPort/")
try {
    $listener.Start()
} catch {
    Write-Log "Couldn't listen on port $ListenPort - is another overlay relay already running? ($_)"
    exit 1
}
Write-Log "Overlay relay running. In OBS, add a Browser Source with the URL http://127.0.0.1:$ListenPort/"

function Wait-ForRequest {
    $pending = $listener.BeginGetContext($null, $null)
    while (-not $pending.AsyncWaitHandle.WaitOne(2000)) {
        if ($ExitWhenProcessGone -and -not (Get-Process -Name $ExitWhenProcessGone -ErrorAction SilentlyContinue)) {
            $script:exitReason = "$ExitWhenProcessGone has closed"
            return $null
        }
    }
    return $listener.EndGetContext($pending)
}

while ($listener.IsListening) {
    $context = Wait-ForRequest
    if (-not $context) {
        Write-Log "Stopping the overlay relay - $exitReason."
        $listener.Stop()
        break
    }
    try {
        $path = $context.Request.Url.AbsolutePath
        if ($context.Request.HttpMethod -eq "POST" -and $path -eq "/layout") { Handle-SaveLayout $context }
        elseif ($context.Request.HttpMethod -eq "POST" -and $path -eq "/vote") { Handle-Vote $context }
        elseif ($context.Request.HttpMethod -eq "POST") { Handle-Post $context }
        elseif ($path -eq "/messages") { Handle-Messages $context }
        else { Handle-File $context $path }
    } catch {
        Write-Log "Request failed: $_"
        try { Send-Text $context 500 "text/plain" "error" } catch {}
    }
}
