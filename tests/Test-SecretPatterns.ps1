# Tests for scripts/secret-patterns.ps1 (Find-SecretPattern). Secret-looking values are assembled from fragments so this file
# never contains a real-looking secret. Positive cases prove each class is caught; negative cases prove normal prose is not.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\secret-patterns.ps1')
$script:pass = 0; $script:fail = 0
function Check($n, $c) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "FAIL: $n" } }
function Hit($n, $line) { Check "caught: $n" ($null -ne (Find-SecretPattern $line)) }
function Miss($n, $line) { Check "not flagged: $n" ($null -eq (Find-SecretPattern $line)) }
$a36 = 'A1b2C3d4' * 5   # 40 alnum chars

# ---- token shapes (same classes as the brain and demo pre-commit hooks) ----
Hit 'aws access key' ('id AKIA' + ('Q' * 16))
Hit 'aws temp key ASIA' ('id ASIA' + ('Q' * 16))
Hit 'github token' ('x gh' + 'p_' + $a36)
Hit 'github pat' ('github' + '_pat_' + $a36)
Hit 'openai style sk-' ('key sk' + '-' + $a36)
Hit 'stripe sk_live' ('k sk' + '_live_' + 'abcdefghij12')
Hit 'stripe sk_test' ('k sk' + '_test_' + 'abcdefghij12')
Hit 'slack token' ('t xo' + 'xb-' + '1234567890-abcdef')
Hit 'google api key' ('k AI' + 'za' + ('B' * 35))
Hit 'huggingface hf_' ('t h' + 'f_' + $a36)
Hit 'npm token' ('t np' + 'm_' + $a36)
Hit 'gitlab pat' ('t gl' + 'pat-' + 'abcdefghij1234567890')
Hit 'google oauth ya29' ('t ya' + '29.' + 'abcdefghij1234567890')
Hit 'sendgrid SG.' ('t S' + 'G.' + ('a' * 22) + '.' + ('b' * 22))
Hit 'private key header' ('-----BEGIN RSA PRIV' + 'ATE KEY-----')
Hit 'private key header plain' ('-----BEGIN PRIV' + 'ATE KEY-----')
Hit 'jwt' ('t ey' + 'J' + ('a' * 20) + '.' + ('b' * 20) + '.' + ('c' * 12))
Hit 'azure AccountKey' ('Account' + 'Key=' + ('abcd1234' * 4) + '==')
Hit 'sas sig query' ('https://x.blob.core.windows.net/c?sv=1&s' + 'ig=' + ('Ab1%2B' * 6))
Hit 'bearer header' ('Authorization: Bea' + 'rer ' + ('abcdEFGH1234' * 3))
Hit 'basic auth in url' ('http' + '://admin:' + 'hunter22' + '@db.internal/x')

# ---- assignments ----
Hit 'password with $ inside value' ('pass' + 'word=Ab$' + 'cdefghijklmnop')
Hit 'DB_PASSWORD short value' ('DB_PASS' + 'WORD=abc123')
Hit 'password connection string' ('Pass' + 'word=P@ss;Server=x')
Hit 'server first then Password' ('Server=x;User Id=u;Pass' + 'word=hunter2;')
Hit 'api key assignment' ('api_' + 'key = "Zx9Qw8Er7Ty6Ui5O"')
Hit 'apikey no separator' ('api' + 'key: Zx9Qw8Er7Ty6')
Hit 'client secret' ('client_' + 'secret=Zx9Qw8Er7Ty6')
Hit 'access token with suffix' ('access_' + 'token=Zx9Qw8Er7Ty6')
Hit 'credential assignment' ('credential' + ': Zx9Qw8Er7Ty6')
Hit 'connection string name' ('connection_' + 'string=Zx9Qw8Er7Ty6')
Hit 'sharedaccesskey' ('SharedAccess' + 'Key=Zx9Qw8Er7Ty6')
Hit 'private key assignment' ('private_' + 'key=Zx9Qw8Er7Ty6')
Hit 'secret assignment 8 chars' ('sec' + 'ret=Zx9Qw8Er')
Hit 'real value even if line says todo' ('pass' + 'word=Zx9Qw8Er7Ty6 # todo example none')
Hit 'json style' ('"pass' + 'word": "Zx9Qw8Er7Ty6"')

# ---- normal prose / code must NOT be flagged ----
Miss 'tokens colon number' 'tokens: 1234567890123'
Miss 'tokens colon prose' 'Context window tokens: unlimited for this plan'
Miss 'tokens approx' 'Every session pre-loads about 14k chars (~3.5k tokens) of state'
Miss 'tokens budget line' 'Max tokens: 8000 chars, roughly 2000 tokens.'
Miss 'token word in prose' 'The next token is predicted from the previous tokens.'
Miss 'task- word is not sk-' 'See task-management-and-workflow-automation-pipeline for details'
Miss 'risk- word is not sk-' 'a risk-assessment-framework-for-agent-permissions-and-more'
Miss 'credentials prose' '- Credentials: Microsoft Cloud Solution Provider (M365 and Azure), SOC 2 Type II audits.'
Miss 'code reference value' 'api_key = settings.GEMINI_API_KEY if settings.GEMINI_API_KEY != "x" else None'
Miss 'code call argument' 'client = genai.Client(api_key=api_key) if api_key else None'
Miss 'token prose with colon' 'token: a unit of text the model reads'
Miss 'password policy prose' 'The password policy requires rotation every 90 days.'
Miss 'password env reference' 'password = $env:DB_PASSWORD'
Miss 'token subexpression' 'token = $(Get-Token)'
Miss 'placeholder value' ('api_' + 'key=<your key here>')
Miss 'your_ placeholder' ('pass' + 'word=your_password_here')
Miss 'example placeholder' ('sec' + 'ret=example-value-123')
Miss 'secret none' 'secret: none'
Miss 'getenv' ('api_' + 'key = os.getenv("X")')
Miss 'environ' ('api_' + 'key = os.environ["X"]')
Miss 'short bearer word' 'Bearer token is required for auth'
Miss 'ssh git url' 'git@github.com:user/repo.git'
Miss 'url with port' 'http://localhost:8080/path'
Miss 'url user only' 'ssh://git@example.org/repo'
Miss 'sig short' 'use ?sig=abc to sign'
Miss 'hf_ inside a word' ('amount CH' + 'f_' + 'abcdefghijklmnopqrstuvwxyz0123456789')
Miss 'npm_ inside a word' ('the xn' + 'pm_' + 'abcdefghijklmnopqrstuvwxyz0123456789')
Miss 'npm_ env name' 'set NPM_CONFIG_LOGLEVEL=warn'
Miss 'access key id prose' 'access_key_id: see vault'
Miss 'plain sentence' 'Run the tests, then commit. Nothing here is sensitive.'
Miss 'empty line' ''
Miss 'markdown heading' '## Approvals'

Write-Host "SecretPatterns tests: $pass passed, $fail failed"
exit ([int]($fail -gt 0))
