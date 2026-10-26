# Shared secret-shape patterns (dot-source this). Used by memory-check, handoff, approvals.
# Find-SecretPattern returns the NAME of the first matching pattern in a line of text, or $null. Never returns the value.
# Token shapes mirror the classes in gemini-brain\scripts\hooks\pre-commit and demo-project\scripts\hooks\pre-commit, anchored
# (case-sensitive, not preceded by a letter or digit) so words like "task-..." are not read as "sk-...". Assignments: the placeholder
# filter looks at the VALUE only, so an "example"/"todo" elsewhere on the line cannot hide a real value. Keep tests/Test-SecretPatterns.ps1 in step.
$script:NB = '(?<![A-Za-z0-9])'
$script:SecretShapes = @(
    @('aws-access-key', 'A(?:KIA|SIA)[0-9A-Z]{16}'),
    @('github-token', "$($script:NB)gh[pousr]_[A-Za-z0-9]{30,}"), @('github-pat', 'github_pat_[A-Za-z0-9_]{30,}'),
    @('openai-style-key', "$($script:NB)sk-[A-Za-z0-9_-]{24,}"), @('stripe-key', "$($script:NB)sk_(?:live|test)_[A-Za-z0-9]{10,}"),
    @('slack-token', 'xox[baprs]-[A-Za-z0-9-]{10,}'), @('google-api-key', 'AIza[0-9A-Za-z_-]{35}'),
    @('huggingface-token', "$($script:NB)hf_[A-Za-z0-9]{30,}"), @('npm-token', "$($script:NB)npm_[A-Za-z0-9]{30,}"),
    @('gitlab-token', "$($script:NB)glpat-[A-Za-z0-9_-]{20,}"), @('google-oauth-token', "$($script:NB)ya29\.[A-Za-z0-9_-]{20,}"),
    @('sendgrid-key', "$($script:NB)SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"),
    @('private-key-header', '-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----'), @('jwt', 'eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}'),
    @('azure-storage-key', '(?i:AccountKey)=[A-Za-z0-9+/=]{20,}'), @('sas-signature', '[?&]sig=[A-Za-z0-9%+/=]{20,}'),
    @('bearer-token', '\b[Bb]earer\s+[A-Za-z0-9._~+/=-]{20,}'), @('url-credentials', '://[^/\s:@]+:[^@\s/]{3,}@')
)
# Value: first char is not whitespace/quote/$/{/< (so $env:X, ${X}, $(..), <your key> are skipped), no ';' ',' or ')' inside.
$script:SecretValue = '(?<v>[^\s"''#;,<{$%)][^\s"''#;,<{%)]{N,})'
$script:DigitLead = '(?=[^\s"'']*\d)'   # prose-prone names (token, credential) only count when the value contains a digit
function script:Make-AssignRe([string]$Names, [int]$MinLen, [string]$Lead = '') {
    "(?i)(?:$Names)[\w.-]*[`"']?\s*[:=]\s*[`"']?$Lead" + $script:SecretValue.Replace('{N,}', "{$($MinLen - 1),}")
}
$script:SecretAssignRes = @(
    (Make-AssignRe 'password|passwd|pwd|secret|api[_-]?key|client[_-]?secret|access[_-]?key|account[_-]?key|private[_-]?key|connection[_-]?string|sharedaccesskey' 8),
    (Make-AssignRe 'password|passwd' 6),   # DB_PASSWORD=abc123
    # "Credentials: Microsoft Cloud ..." is prose, so credential needs a digit in the value
    (Make-AssignRe 'credentials?' 8 $script:DigitLead),
    # "token" is anchored: "tokens:" / "token budget" are prose; only token=, token:, token_x= / access_token= forms count, and the value needs a digit
    ("(?i)token(?:[_.-][\w.-]*)?[`"']?\s*[:=]\s*[`"']?" + $script:DigitLead + $script:SecretValue.Replace('{N,}', '{7,}')),
    # connection strings: Password=P@ss;Server=x   and   Server=x;User Id=u;Password=hunter2;
    '(?i)\b(?:password|pwd)=(?<v>[^;\s"'']{3,});\s*\w[\w ]*=',
    '(?i)\w[\w ]*=[^;]*;\s*(?:password|pwd)=(?<v>[^;\s"'']{3,})'
)
$script:SecretPlaceholder = '(?i)(example|changeme|your[_-]?|placeholder|dummy|redacted|xxxx|environ|getenv|process\.env|secrets\.|\bnull\b|\bnone\b|\btodo\b|\btbd\b|\*\*\*)'
# a code reference such as settings.GEMINI_API_KEY or my_var (letters, '.', '_' only, with at least one '.' or '_') is not a literal secret
$script:SecretCodeRef = '^(?=[A-Za-z_.]*[._])[A-Za-z_][A-Za-z_.]*$'
function Find-SecretPattern([string]$Line) {
    foreach ($s in $script:SecretShapes) { if ($Line -cmatch $s[1]) { return $s[0] } }
    foreach ($re in $script:SecretAssignRes) {
        foreach ($m in [regex]::Matches($Line, $re)) {
            $v = $m.Groups['v'].Value
            if ($v -notmatch $script:SecretPlaceholder -and $v -notmatch $script:SecretCodeRef) { return 'secret-assignment' }
        }
    }
    return $null
}
