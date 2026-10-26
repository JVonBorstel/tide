# Owns the "is this model address on this PC?" rule: only http://localhost, 127.0.0.1 or [::1] with a port (same rule as stations/lead-pitch.ps1).
# Dot-sourced by kitchen/cooks/local.ps1 (and meant for the privacy judge in kitchen/sous-chef.ps1); tested by tests/Test-Outbound.ps1.
# Private orders must never leave the machine, so a LAN, tailnet or internet address for Ollama is refused, never "tried".
function Test-LoopbackUrl([string]$Url) {
    [string]$Url -match '^http://(127\.0\.0\.1|localhost|\[::1\]):\d+/?$'
}
function Get-LoopbackRefusal([string]$Url, [string]$Name = 'KITCHEN_OLLAMA_URL') {
    "$Name is '$Url', which is not this PC. Private work only goes to a model on this machine: use http://127.0.0.1:<port>, http://localhost:<port> or http://[::1]:<port> (or 'off')."
}
