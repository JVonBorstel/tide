#requires -Version 7
<#
Tests for kitchen/ats.ps1 (ATS parser: Greenhouse, Lever, Ashby, unknown sites).
Offline only: parses saved fixture JSON files, zero network.
#>
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$atsScript = Join-Path $repo 'kitchen\ats.ps1'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('kitchen-test-ats-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null

$pass = 0; $fail = 0
function Check([string]$name, [bool]$cond, [string]$detail = '') {
    if ($cond) {
        $script:pass++
    } else {
        $script:fail++
        Write-Host "FAIL: $name $detail" -ForegroundColor Red
    }
}

try {
    # 1. Fixture: Greenhouse sample
    $ghSample = Join-Path $tmp 'greenhouse-sample.json'
    Set-Content -LiteralPath $ghSample -Encoding utf8 -Value @'
{
  "id": 4123456,
  "title": "Senior Backend Engineer",
  "company_name": "Acme Software",
  "content": "<p>About the role:</p><p>We are seeking an engineer to build distributed systems.</p><ul><li>Design APIs &amp; microservices</li><li>Optimize databases &gt; 10TB</li></ul><br/><p>Benefits include 401(k) &amp; healthcare.</p>",
  "questions": [
    {
      "id": 101,
      "name": "full_name",
      "label": "Full Name",
      "required": true,
      "type": "input_text",
      "values": []
    },
    {
      "id": 102,
      "name": "resume",
      "label": "Resume/CV",
      "required": true,
      "type": "attachment",
      "values": []
    },
    {
      "id": 103,
      "name": "work_auth",
      "label": "Are you authorized to work in the US?",
      "required": true,
      "type": "select",
      "values": [
        { "label": "Yes", "value": "yes" },
        { "label": "No", "value": "no" }
      ]
    }
  ]
}
'@

    # 2. Fixture: Lever sample
    $leverSample = Join-Path $tmp 'lever-sample.json'
    Set-Content -LiteralPath $leverSample -Encoding utf8 -Value @'
{
  "id": "lever-job-789",
  "text": "Staff Infrastructure Engineer",
  "company": "LeverCorp",
  "descriptionPlain": "We are looking for a Staff Engineer to lead cloud infrastructure.\nManage Kubernetes clusters across multiple clouds.",
  "additionalPlain": "Compensation: $180,000 - $220,000.",
  "customQuestions": [
    {
      "id": "q1",
      "text": "Years of experience with Kubernetes",
      "required": true,
      "type": "dropdown",
      "options": [
        { "text": "1-3 years" },
        { "text": "3-5 years" },
        { "text": "5+ years" }
      ]
    },
    {
      "id": "q2",
      "text": "GitHub Profile or Portfolio URL",
      "required": false,
      "type": "text"
    }
  ]
}
'@

    # 3. Fixture: Ashby sample
    $ashbySample = Join-Path $tmp 'ashby-sample.json'
    Set-Content -LiteralPath $ashbySample -Encoding utf8 -Value @'
{
  "jobs": [
    {
      "id": "ashby-job-555",
      "title": "Principal AI Researcher",
      "companyName": "AshbyAI",
      "jobUrl": "https://jobs.ashbyhq.com/ashbyai/ashby-job-555",
      "descriptionPlain": "Join our AI research team working on next-generation agent architectures.",
      "applicationQuestions": [
        {
          "id": "ashby-q1",
          "title": "Link to your Google Scholar or arXiv profile",
          "isRequired": false,
          "type": "Text"
        },
        {
          "id": "ashby-q2",
          "title": "Highest degree completed",
          "isRequired": true,
          "type": "ValueSelect",
          "options": [
            { "label": "Bachelors" },
            { "label": "Masters" },
            { "label": "PhD" }
          ]
        }
      ]
    }
  ]
}
'@

    # Test 1: Parse Greenhouse sample
    $gh = & $atsScript -FromFile $ghSample
    Check 'Greenhouse: parsed successfully' ($gh.ok -eq $true)
    Check 'Greenhouse: title extracted' ($gh.title -eq 'Senior Backend Engineer')
    Check 'Greenhouse: company extracted' ($gh.company -eq 'Acme Software')
    Check 'Greenhouse: description plain text converted' ($gh.description -match 'About the role:' -and $gh.description -match '- Design APIs & microservices')
    Check 'Greenhouse: html entities &amp; and &gt; decoded' ($gh.description -match 'Design APIs & microservices' -and $gh.description -match 'Optimize databases > 10TB')
    Check 'Greenhouse: questions count' (@($gh.questions).Count -eq 3)
    Check 'Greenhouse: question[0] fields' ($gh.questions[0].label -eq 'Full Name' -and $gh.questions[0].name -eq 'full_name' -and $gh.questions[0].field_name -eq 'full_name' -and $gh.questions[0].required -eq $true -and $gh.questions[0].type -eq 'input_text')
    Check 'Greenhouse: question[2] options' ($gh.questions[2].options -contains 'Yes' -and $gh.questions[2].options -contains 'No')

    # Test 1b: Greenhouse via URL and -FromFile with -Json switch
    $ghJsonRaw = & $atsScript -Url 'https://boards.greenhouse.io/acme/jobs/4123456' -FromFile $ghSample -Json
    $ghJson = $ghJsonRaw | ConvertFrom-Json
    Check 'Greenhouse: -Json output valid and ok' ($ghJson.ok -eq $true -and $ghJson.title -eq 'Senior Backend Engineer' -and @($ghJson.questions).Count -eq 3)

    # Test 2: Parse Lever sample
    $lv = & $atsScript -FromFile $leverSample
    Check 'Lever: parsed successfully' ($lv.ok -eq $true)
    Check 'Lever: title extracted' ($lv.title -eq 'Staff Infrastructure Engineer')
    Check 'Lever: company extracted' ($lv.company -eq 'LeverCorp')
    Check 'Lever: description combined' ($lv.description -match 'Manage Kubernetes clusters' -and $lv.description -match 'Compensation: \$180,000')
    Check 'Lever: questions count' (@($lv.questions).Count -eq 2)
    Check 'Lever: custom question[0] options' ($lv.questions[0].label -eq 'Years of experience with Kubernetes' -and $lv.questions[0].required -eq $true -and $lv.questions[0].options -contains '5+ years')
    Check 'Lever: custom question[1] optional' ($lv.questions[1].required -eq $false -and $lv.questions[1].type -eq 'text')

    # Test 3: Parse Ashby sample
    $ash = & $atsScript -FromFile $ashbySample
    Check 'Ashby: parsed successfully' ($ash.ok -eq $true)
    Check 'Ashby: title extracted' ($ash.title -eq 'Principal AI Researcher')
    Check 'Ashby: company extracted' ($ash.company -eq 'AshbyAI')
    Check 'Ashby: description extracted' ($ash.description -match 'next-generation agent architectures')
    Check 'Ashby: questions count' (@($ash.questions).Count -eq 2)
    Check 'Ashby: question[0] optional text' ($ash.questions[0].label -eq 'Link to your Google Scholar or arXiv profile' -and $ash.questions[0].required -eq $false)
    Check 'Ashby: question[1] required with options' ($ash.questions[1].label -eq 'Highest degree completed' -and $ash.questions[1].required -eq $true -and $ash.questions[1].options -contains 'PhD')

    # Test 3b: an Ashby job id that is not on the board is an error, never another job on the same board
    $ashMulti = Join-Path $tmp 'ashby-multi.json'
    Set-Content -LiteralPath $ashMulti -Encoding utf8 -Value '{"jobs":[{"id":"11111111-aaaa","title":"Some Other Job","companyName":"Acme","descriptionPlain":"x"},{"id":"33333333-cccc","title":"Third Job","companyName":"Acme","descriptionPlain":"y"}]}'
    $gone = & $atsScript -Url 'https://jobs.ashbyhq.com/acme/22222222-bbbb' -FromFile $ashMulti
    Check 'Ashby: job id not on the board is refused (no stand-in job)' ($gone.ok -eq $false -and $gone.error -match 'no longer on the company board')
    $hit = & $atsScript -Url 'https://jobs.ashbyhq.com/acme/33333333-cccc/application' -FromFile $ashMulti
    Check 'Ashby: the named job is the one returned' ($hit.ok -eq $true -and $hit.title -eq 'Third Job')
    $board = & $atsScript -Url 'https://jobs.ashbyhq.com/acme' -FromFile $ashMulti
    Check 'Ashby: a board link with several jobs is refused' ($board.ok -eq $false)

    # Test 3c: Greenhouse sends content HTML-escaped: decoded before tags are stripped; emoji and hex entities decode
    $ghEsc = Join-Path $tmp 'gh-escaped.json'
    Set-Content -LiteralPath $ghEsc -Encoding utf8 -Value '{"title":"Dev","company_name":"G","content":"&lt;p&gt;Ship it now &amp;#128640; caf&amp;#xE9;&lt;/p&gt;&lt;script&gt;steal()&lt;/script&gt;&lt;ul&gt;&lt;li&gt;Python&lt;/li&gt;&lt;/ul&gt;","questions":[{"name":"q","label":"Why?","required":false,"type":"text"}]}'
    $ge = & $atsScript -FromFile $ghEsc
    Check 'Greenhouse: escaped HTML is stripped to text (no tags, no script text)' ($ge.ok -eq $true -and $ge.description -notmatch '<|steal' -and $ge.description -match 'Ship it now' -and $ge.description -match '- Python')
    Check 'Greenhouse: emoji and hex entities decode instead of crashing' ($ge.description -match ([char]::ConvertFromUtf32(128640)) -and $ge.description -match 'café')

    # Test 4: Unknown and unsupported sites
    $unk1 = & $atsScript -Url 'https://example.com/jobs/12345'
    Check 'Unknown site: example.com not supported' ($unk1.ok -eq $false -and $unk1.error -eq 'not supported')

    $unk2 = & $atsScript -Url 'https://mycompany.workday.com/en-US/job/Engineer_JR123'
    Check 'Unknown site: workday not supported' ($unk2.ok -eq $false -and $unk2.error -eq 'not supported')

    $unk3 = & $atsScript -Url 'https://linkedin.com/jobs/view/123456789'
    Check 'Unknown site: linkedin not supported' ($unk3.ok -eq $false -and $unk3.error -eq 'not supported')

    # Test 5: Invalid / non-HTTP URLs
    $inv1 = & $atsScript -Url 'javascript:alert(1)'
    Check 'Invalid URL: javascript refused' ($inv1.ok -eq $false -and $inv1.error -in 'invalid url', 'not supported')

    $inv2 = & $atsScript -Url 'file:///C:/passwords.txt'
    Check 'Invalid URL: file protocol refused' ($inv2.ok -eq $false -and $inv2.error -in 'invalid url', 'not supported')

} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Ats tests: $($script:pass) passed, $($script:fail) failed"
exit ([int]($script:fail -gt 0))
