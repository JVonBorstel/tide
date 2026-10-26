#requires -Version 7
<#
.SYNOPSIS
  kitchen/ats.ps1 - Fetches or parses job postings and application questions from public ATS APIs
  (Greenhouse, Lever, Ashby). No new dependencies.
.PARAMETER Url
  Job posting URL or API URL.
.PARAMETER FromFile
  Path to saved JSON fixture (for offline testing or caching).
.PARAMETER Json
  Switch to output JSON string instead of hashtable/object.
#>
[CmdletBinding()]
param(
    [string]$Url,
    [string]$FromFile,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function ConvertFrom-Html([string]$html) {
    if ([string]::IsNullOrWhiteSpace($html)) { return '' }
    # Greenhouse sends its content HTML-escaped (&lt;p&gt;...), so decode first, then strip tags, then decode the text once more.
    # WebUtility handles named, decimal, hex and emoji (astral) entities; a hand-made [char][int] cast threw on &#128640;.
    $text = [System.Net.WebUtility]::HtmlDecode($html)
    $text = $text -replace '(?i)<br\s*/?>', "`n"
    $text = $text -replace '(?i)</(?:p|div|li|h[1-6]|tr)>', "`n"
    $text = $text -replace '(?i)<li[^>]*>', "- "
    $text = $text -replace '(?is)<(script|style)\b[^>]*>.*?</\1\s*>', ''
    $text = $text -replace '<[^>]+>', ''
    $text = [System.Net.WebUtility]::HtmlDecode($text)
    $text = $text -replace ' ', ' '
    $text = $text -replace '\r', ''
    $text = $text -replace '[ \t]+', ' '
    $text = $text -replace '(?m)^[ \t]+', ''
    $text = $text -replace '(?m)[ \t]+$', ''
    $text = $text -replace '\n{3,}', "`n`n"
    return $text.Trim()
}

function Emit-Result($result) {
    if ($Json) {
        $result | ConvertTo-Json -Depth 6 -Compress
    } else {
        $result
    }
}

# Environment variable fixture override (for testing without live network)
if (-not $FromFile) {
    if ($env:PASS_ATS_FIXTURE -and (Test-Path -LiteralPath $env:PASS_ATS_FIXTURE)) {
        $FromFile = $env:PASS_ATS_FIXTURE
    } elseif ($env:ATS_FIXTURE -and (Test-Path -LiteralPath $env:ATS_FIXTURE)) {
        $FromFile = $env:ATS_FIXTURE
    } elseif ($env:BRAIN_KITCHEN) {
        $defaultFixture = Join-Path $env:BRAIN_KITCHEN 'ats-fixture.json'
        if (Test-Path -LiteralPath $defaultFixture) {
            $FromFile = $defaultFixture
        }
    }
}

# Determine ATS from Url if provided
$ats = $null
$company = ''
$jobId = ''
$apiUrl = ''

if ($Url) {
    if ($Url -notmatch '^https?://' -and -not $FromFile) {
        return (Emit-Result @{ ok = $false; error = 'invalid url' })
    }
    if ($Url -match '(?i)greenhouse\.io') {
        $ats = 'greenhouse'
        if ($Url -match '(?i)greenhouse\.io/(?:v1/boards/)?([^/?#]+)/jobs/(\d+)') {
            $company = $Matches[1]
            $jobId = $Matches[2]
        } elseif ($Url -match '(?i)[?&]for=([^&#]+).*?[?&]token=(\d+)' -or $Url -match '(?i)[?&]token=(\d+).*?[?&]for=([^&#]+)') {
            if ($Url -match '(?i)[?&]for=([^&#]+)') { $company = $Matches[1] }
            if ($Url -match '(?i)[?&]token=(\d+)') { $jobId = $Matches[1] }
        }
        if ($company -and $jobId) {
            $apiUrl = "https://boards-api.greenhouse.io/v1/boards/$company/jobs/${jobId}?questions=true"
        }
    } elseif ($Url -match '(?i)lever\.co') {
        $ats = 'lever'
        if ($Url -match '(?i)lever\.co/(?:v0/postings/)?([^/?#]+)/([a-f0-9\-]+|[^/?#]+)') {
            $company = $Matches[1]
            $jobId = $Matches[2]
            $apiUrl = "https://api.lever.co/v0/postings/$company/${jobId}?mode=json"
        }
    } elseif ($Url -match '(?i)ashbyhq\.com') {
        $ats = 'ashby'
        if ($Url -match '(?i)ashbyhq\.com/(?:posting-api/job-board/)?([^/?#]+)(?:/([a-f0-9\-]+|[^/?#]+))?') {
            $company = $Matches[1]
            $jobId = $Matches[2]
            $apiUrl = "https://api.ashbyhq.com/posting-api/job-board/$company"
        }
    } else {
        # Unknown site
        return (Emit-Result @{ ok = $false; error = 'not supported' })
    }
}

# Load JSON payload (from file or network)
$doc = $null
if ($FromFile) {
    if (-not (Test-Path -LiteralPath $FromFile)) {
        return (Emit-Result @{ ok = $false; error = "file not found: $FromFile" })
    }
    try {
        $raw = Get-Content -LiteralPath $FromFile -Raw -Encoding utf8
        $doc = $raw | ConvertFrom-Json
    } catch {
        return (Emit-Result @{ ok = $false; error = "invalid json in fixture: $($_.Exception.Message)" })
    }
} elseif ($apiUrl) {
    try {
        $doc = Invoke-RestMethod -Uri $apiUrl -Method Get -TimeoutSec 15 -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
    } catch {
        return (Emit-Result @{ ok = $false; error = "failed to fetch posting: $($_.Exception.Message)" })
    }
} else {
    return (Emit-Result @{ ok = $false; error = 'not supported' })
}

if ($null -eq $doc) {
    return (Emit-Result @{ ok = $false; error = 'empty response' })
}

# Auto-detect ATS if not set via URL
if (-not $ats) {
    if ($doc.questions -and ($doc.content -or $doc.company_name -or $doc.board)) {
        $ats = 'greenhouse'
    } elseif ($doc.customQuestions -or $doc.descriptionPlain -or $doc.lists -or ($doc.data -and $doc.data.descriptionPlain)) {
        $ats = 'lever'
    } elseif ($doc.jobs -or $doc.applicationQuestions -or $doc.jobUrl) {
        $ats = 'ashby'
    } elseif ($doc.questions -and $doc.title) {
        $ats = 'greenhouse'
    } else {
        return (Emit-Result @{ ok = $false; error = 'not supported' })
    }
}

$title = ''
$extractedCompany = $company
$description = ''
$questions = [System.Collections.Generic.List[object]]::new()

if ($ats -eq 'greenhouse') {
    $title = if ($doc.title) { [string]$doc.title } else { '' }
    if ($doc.company_name) {
        $extractedCompany = [string]$doc.company_name
    } elseif (-not $extractedCompany -and $doc.board) {
        $extractedCompany = [string]$doc.board
    }
    $description = if ($doc.content) { ConvertFrom-Html ([string]$doc.content) } else { '' }

    if ($doc.questions) {
        foreach ($q in $doc.questions) {
            $label = if ($q.label) { [string]$q.label } elseif ($q.name) { [string]$q.name } else { '' }
            $name = if ($q.name) { [string]$q.name } elseif ($q.id) { [string]$q.id } else { '' }
            $req = [bool]$q.required
            $type = if ($q.type) { [string]$q.type } else { 'text' }
            $opts = [System.Collections.Generic.List[string]]::new()
            if ($q.values) {
                foreach ($v in $q.values) {
                    if ($null -ne $v) {
                        if ($v.label) { $opts.Add([string]$v.label) }
                        elseif ($v.value) { $opts.Add([string]$v.value) }
                        else { $opts.Add([string]$v) }
                    }
                }
            } elseif ($q.answer_options) {
                foreach ($v in $q.answer_options) {
                    if ($null -ne $v) {
                        if ($v.label) { $opts.Add([string]$v.label) }
                        elseif ($v.value) { $opts.Add([string]$v.value) }
                        else { $opts.Add([string]$v) }
                    }
                }
            }
            $questions.Add([ordered]@{
                label      = $label
                name       = $name
                field_name = $name
                required   = $req
                type       = $type
                options    = [string[]]$opts.ToArray()
            })
        }
    }
} elseif ($ats -eq 'lever') {
    $obj = if ($doc.data) { $doc.data } else { $doc }
    $title = if ($obj.text) { [string]$obj.text } elseif ($obj.title) { [string]$obj.title } else { '' }
    if ($obj.company) {
        $extractedCompany = [string]$obj.company
    } elseif (-not $extractedCompany -and $obj.categories -and $obj.categories.team) {
        $extractedCompany = [string]$obj.categories.team
    }

    $descParts = [System.Collections.Generic.List[string]]::new()
    if ($obj.descriptionPlain) {
        $descParts.Add([string]$obj.descriptionPlain.Trim())
    } elseif ($obj.description) {
        $descParts.Add((ConvertFrom-Html ([string]$obj.description)))
    }
    if ($obj.lists) {
        foreach ($lst in $obj.lists) {
            if ($lst.text) { $descParts.Add([string]$lst.text) }
            if ($lst.content) { $descParts.Add((ConvertFrom-Html ([string]$lst.content))) }
        }
    }
    if ($obj.additionalPlain) {
        $descParts.Add([string]$obj.additionalPlain.Trim())
    } elseif ($obj.additional) {
        $descParts.Add((ConvertFrom-Html ([string]$obj.additional)))
    }
    $description = ($descParts -join "`n`n").Trim()

    $qList = if ($obj.customQuestions) { $obj.customQuestions } elseif ($obj.questions) { $obj.questions } else { @() }
    foreach ($q in $qList) {
        $label = if ($q.text) { [string]$q.text } elseif ($q.label) { [string]$q.label } elseif ($q.name) { [string]$q.name } else { '' }
        $name = if ($q.id) { [string]$q.id } elseif ($q.name) { [string]$q.name } else { '' }
        $req = [bool]$q.required
        $type = if ($q.type) { [string]$q.type } else { 'text' }
        $opts = [System.Collections.Generic.List[string]]::new()
        if ($q.options) {
            foreach ($o in $q.options) {
                if ($null -ne $o) {
                    if ($o.text) { $opts.Add([string]$o.text) }
                    elseif ($o.label) { $opts.Add([string]$o.label) }
                    elseif ($o.value) { $opts.Add([string]$o.value) }
                    else { $opts.Add([string]$o) }
                }
            }
        } elseif ($q.values) {
            foreach ($o in $q.values) {
                if ($null -ne $o) {
                    if ($o.label) { $opts.Add([string]$o.label) }
                    elseif ($o.text) { $opts.Add([string]$o.text) }
                    else { $opts.Add([string]$o) }
                }
            }
        }
        $questions.Add([ordered]@{
            label      = $label
            name       = $name
            field_name = $name
            required   = $req
            type       = $type
            options    = [string[]]$opts.ToArray()
        })
    }
} elseif ($ats -eq 'ashby') {
    $job = $null
    if ($doc.jobs -is [System.Collections.IEnumerable] -and -not ($doc.jobs -is [string])) {
        if ($jobId) {
            $job = $doc.jobs | Where-Object { $_.id -eq $jobId -or ($_.jobUrl -and $_.jobUrl -like "*$jobId*") } | Select-Object -First 1
            # never stand in another job: Pack would tailor the resume and answers for the wrong role
            if (-not $job) { return (Emit-Result @{ ok = $false; error = 'that job is no longer on the company board' }) }
        } elseif (@($doc.jobs).Count -eq 1) {
            $job = @($doc.jobs)[0]   # a link to the board itself is only unambiguous when the board holds one job
        } elseif (@($doc.jobs).Count -gt 1) {
            return (Emit-Result @{ ok = $false; error = 'the link names no job and the board has several; use the job''s own link' })
        }
    } else {
        $job = $doc
    }

    if (-not $job) {
        return (Emit-Result @{ ok = $false; error = 'job not found in ashby payload' })
    }

    $title = if ($job.title) { [string]$job.title } else { '' }
    if ($job.companyName) {
        $extractedCompany = [string]$job.companyName
    }

    if ($job.descriptionPlain) {
        $description = [string]$job.descriptionPlain.Trim()
    } elseif ($job.descriptionHtml) {
        $description = ConvertFrom-Html ([string]$job.descriptionHtml)
    }

    $qList = if ($job.questions) { $job.questions } elseif ($job.applicationQuestions) { $job.applicationQuestions } elseif ($job.customQuestions) { $job.customQuestions } else { @() }
    foreach ($q in $qList) {
        $label = if ($q.title) { [string]$q.title } elseif ($q.label) { [string]$q.label } elseif ($q.name) { [string]$q.name } else { '' }
        $name = if ($q.id) { [string]$q.id } elseif ($q.name) { [string]$q.name } else { '' }
        $req = [bool]($q.isRequired -eq $true -or $q.required -eq $true -or ($null -ne $q.isNullable -and $q.isNullable -eq $false))
        $type = if ($q.type) { [string]$q.type } else { 'text' }
        $opts = [System.Collections.Generic.List[string]]::new()
        if ($q.options) {
            foreach ($o in $q.options) {
                if ($null -ne $o) {
                    if ($o.label) { $opts.Add([string]$o.label) }
                    elseif ($o.title) { $opts.Add([string]$o.title) }
                    elseif ($o.value) { $opts.Add([string]$o.value) }
                    else { $opts.Add([string]$o) }
                }
            }
        } elseif ($q.values) {
            foreach ($o in $q.values) {
                if ($null -ne $o) {
                    if ($o.label) { $opts.Add([string]$o.label) }
                    else { $opts.Add([string]$o) }
                }
            }
        }
        $questions.Add([ordered]@{
            label      = $label
            name       = $name
            field_name = $name
            required   = $req
            type       = $type
            options    = [string[]]$opts.ToArray()
        })
    }
}

$result = [ordered]@{
    ok          = $true
    title       = $title
    company     = $extractedCompany
    description = $description
    questions   = [object[]]$questions.ToArray()
}

return (Emit-Result $result)
