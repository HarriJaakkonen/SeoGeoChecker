param(
    [string]$StartUrl = "",
    [int]$MaxPages = 200,
    [int]$MaxDepth = 3,
    [int]$TimeoutSec = 20,
    [int]$MaxRedirects = 8,
    [string]$SitemapUrl,
    [switch]$RenderedChecks,
    [string]$BrowserPath,
    [int]$RenderedSampleSize = 20,
    [switch]$AsJson,
    [switch]$AsHtml,
    [string]$HtmlReportPath = ""
)

$ErrorActionPreference = "Stop"

try {
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
}
catch {
    # Assembly is already loaded in some PowerShell hosts.
}

function Normalize-Url {
    param([string]$Url)
    try {
        $uri = [System.Uri]$Url
    }
    catch {
        return $null
    }

    if (-not $uri.IsAbsoluteUri) { return $null }

    $builder = [System.UriBuilder]::new($uri)
    $builder.Fragment = ""

    $path = $builder.Path
    if ($path -match '/index\.(html?|xhtml)$') {
        $path = $path -replace '/index\.(html?|xhtml)$', '/'
        $builder.Path = $path
    }

    if ($path.Length -gt 1 -and $path.EndsWith('/')) {
        $builder.Path = $path.TrimEnd('/')
    }

    return $builder.Uri.AbsoluteUri
}

function Resolve-Url {
    param(
        [string]$BaseUrl,
        [string]$Href
    )

    if ([string]::IsNullOrWhiteSpace($Href)) { return $null }

    $h = $Href.Trim()
    if ($h.StartsWith('#')) { return $null }
    if ($h -match '^(mailto:|tel:|javascript:|data:)') { return $null }
    if ($h -match '\$\{|\{\{|\}\}|%7B|%7D') { return $null }

    try {
        $base = [System.Uri]$BaseUrl
        $resolved = [System.Uri]::new($base, $h)
        return Normalize-Url -Url $resolved.AbsoluteUri
    }
    catch {
        return $null
    }
}

function Extract-TagContent {
    param(
        [string]$Html,
        [string]$Pattern
    )

    $m = [regex]::Match($Html, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return "" }

    return ($m.Groups[1].Value -replace '\s+', ' ').Trim()
}

function Get-RawSignals {
    param([string]$Html)

    return [ordered]@{
        title         = Extract-TagContent -Html $Html -Pattern '<title[^>]*>([\s\S]*?)</title>'
        description   = Extract-TagContent -Html $Html -Pattern '<meta[^>]*name=["'']description["''][^>]*content=["'']([\s\S]*?)["'']'
        canonical     = Extract-TagContent -Html $Html -Pattern '<link[^>]*rel=["'']canonical["''][^>]*href=["'']([\s\S]*?)["'']'
        robots        = Extract-TagContent -Html $Html -Pattern '<meta[^>]*name=["'']robots["''][^>]*content=["'']([\s\S]*?)["'']'
        ogTitle       = Extract-TagContent -Html $Html -Pattern '<meta[^>]*property=["'']og:title["''][^>]*content=["'']([\s\S]*?)["'']'
        ogDescription = Extract-TagContent -Html $Html -Pattern '<meta[^>]*property=["'']og:description["''][^>]*content=["'']([\s\S]*?)["'']'
        ogUrl         = Extract-TagContent -Html $Html -Pattern '<meta[^>]*property=["'']og:url["''][^>]*content=["'']([\s\S]*?)["'']'
        ogImage       = Extract-TagContent -Html $Html -Pattern '<meta[^>]*property=["'']og:image["''][^>]*content=["'']([\s\S]*?)["'']'
        twitterCard   = Extract-TagContent -Html $Html -Pattern '<meta[^>]*name=["'']twitter:card["''][^>]*content=["'']([\s\S]*?)["'']'
        hasJsonLd     = [regex]::IsMatch($Html, '<script\s+type=["'']application/ld\+json["''][^>]*>[\s\S]*?</script>', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
}

function Extract-Links {
    param(
        [string]$Html,
        [string]$BaseUrl,
        [string]$TargetHost
    )

    $links = New-Object System.Collections.Generic.List[string]
    $matches = [regex]::Matches($Html, '<a[^>]*href=["'']([^"'']+)["'']', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    foreach ($m in $matches) {
        $candidate = Resolve-Url -BaseUrl $BaseUrl -Href $m.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        try {
            $u = [System.Uri]$candidate
            if ($u.Host -ne $TargetHost) { continue }
            if ($u.Scheme -notin @('http', 'https')) { continue }
            $links.Add($candidate)
        }
        catch {
            continue
        }
    }

    return $links | Sort-Object -Unique
}

function Invoke-HttpWithRedirects {
    param(
        [string]$Url,
        [int]$TimeoutSec,
        [int]$MaxRedirects
    )

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false

    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.TimeSpan]::FromSeconds($TimeoutSec)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("Cloudpartner-SEO-GEO-Audit/1.0")

    $current = $Url
    $chain = New-Object System.Collections.Generic.List[object]
    $content = ""
    $statusCode = 0
    $finalUrl = $Url
    $headers = @{}
    $error = $null

    try {
        for ($i = 0; $i -le $MaxRedirects; $i++) {
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $current)
            $response = $client.SendAsync($request).GetAwaiter().GetResult()
            $statusCode = [int]$response.StatusCode

            $location = $null
            if ($response.Headers.Location) {
                $location = Resolve-Url -BaseUrl $current -Href $response.Headers.Location.OriginalString
            }

            $chain.Add([pscustomobject]@{
                    url        = $current
                    statusCode = $statusCode
                    location   = $location
                })

            if ($statusCode -ge 300 -and $statusCode -lt 400 -and $location) {
                $current = $location
                continue
            }

            $finalUrl = $current
            foreach ($h in $response.Headers.GetEnumerator()) {
                $headers[$h.Key] = ($h.Value -join ', ')
            }
            foreach ($h in $response.Content.Headers.GetEnumerator()) {
                $headers[$h.Key] = ($h.Value -join ', ')
            }

            $contentType = ""
            if ($headers.ContainsKey("Content-Type")) { $contentType = $headers["Content-Type"] }
            if ($contentType -match 'text/html|application/xhtml\+xml') {
                $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }

            break
        }
    }
    catch {
        $error = $_.Exception.Message
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }

    return [pscustomobject]@{
        requestedUrl  = $Url
        finalUrl      = $finalUrl
        statusCode    = $statusCode
        redirectChain = $chain
        redirectCount = [Math]::Max(0, $chain.Count - 1)
        headers       = $headers
        content       = $content
        error         = $error
    }
}

function Find-BrowserForRendering {
    param([string]$BrowserPath)

    if (-not [string]::IsNullOrWhiteSpace($BrowserPath) -and (Test-Path $BrowserPath)) {
        return (Resolve-Path $BrowserPath).Path
    }

    $candidates = @(
        "msedge",
        "chrome",
        "google-chrome",
        "chromium",
        "chromium-browser"
    )

    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }

    return $null
}

function Get-RenderedDom {
    param(
        [string]$Browser,
        [string]$Url,
        [int]$TimeoutSec
    )

    if (-not $Browser) {
        return [pscustomobject]@{ ok = $false; html = ""; error = "No headless browser found (msedge/chrome/chromium)." }
    }

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $args = @("--headless=new", "--disable-gpu", "--dump-dom", $Url)

        $p = Start-Process -FilePath $Browser -ArgumentList $args -NoNewWindow -RedirectStandardOutput $tempFile -PassThru
        if (-not $p.WaitForExit($TimeoutSec * 1000)) {
            try { $p.Kill() } catch {}
            return [pscustomobject]@{ ok = $false; html = ""; error = "Rendering timed out." }
        }

        $html = Get-Content -Path $tempFile -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($html)) {
            return [pscustomobject]@{ ok = $false; html = ""; error = "Rendered DOM was empty." }
        }

        return [pscustomobject]@{ ok = $true; html = $html; error = $null }
    }
    catch {
        return [pscustomobject]@{ ok = $false; html = ""; error = $_.Exception.Message }
    }
    finally {
        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Parse-SitemapUrls {
    param(
        [string]$SitemapUrl,
        [int]$TimeoutSec
    )

    $resp = Read-UrlSafe -Url $SitemapUrl -TimeoutSec $TimeoutSec
    if (-not $resp.ok) { return @() }

    try {
        [xml]$xml = $resp.content
    }
    catch {
        return @()
    }

    $urls = New-Object System.Collections.Generic.List[string]

    if ($xml.urlset.url) {
        foreach ($n in $xml.urlset.url) {
            if ($n.loc) {
                $normalized = Normalize-Url -Url ([string]$n.loc)
                if ($normalized) { $urls.Add($normalized) }
            }
        }
    }

    if ($xml.sitemapindex.sitemap) {
        foreach ($n in $xml.sitemapindex.sitemap) {
            if ($n.loc) {
                $nested = Parse-SitemapUrls -SitemapUrl ([string]$n.loc) -TimeoutSec $TimeoutSec
                foreach ($u in $nested) { $urls.Add($u) }
            }
        }
    }

    return $urls | Sort-Object -Unique
}

function Get-SitemapCandidates {
    param(
        [string]$StartUrl,
        [string]$SitemapUrl,
        [int]$TimeoutSec
    )

    $startUri = [System.Uri]$StartUrl
    $hostBase = "{0}://{1}" -f $startUri.Scheme, $startUri.Host
    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($SitemapUrl)) {
        $normalizedProvided = Normalize-Url -Url $SitemapUrl
        if ($normalizedProvided) { $candidates.Add($normalizedProvided) }
    }

    $robotsUrl = "$hostBase/robots.txt"
    $robots = Read-UrlSafe -Url $robotsUrl -TimeoutSec $TimeoutSec
    if ($robots.ok -and -not [string]::IsNullOrWhiteSpace($robots.content)) {
        $matches = [regex]::Matches($robots.content, '(?im)^\s*Sitemap:\s*(\S+)\s*$')
        foreach ($m in $matches) {
            $candidate = Resolve-Url -BaseUrl $robotsUrl -Href $m.Groups[1].Value
            if ($candidate) { $candidates.Add($candidate) }
        }
    }

    @(
        "$hostBase/sitemap.xml",
        "$hostBase/sitemap_index.xml",
        "$hostBase/sitemap-index.xml",
        "$hostBase/posts/sitemap.xml"
    ) | ForEach-Object {
        $normalized = Normalize-Url -Url $_
        if ($normalized) { $candidates.Add($normalized) }
    }

    return $candidates | Sort-Object -Unique
}

# Reuse url-safe reader from counter script behavior
function Read-UrlSafe {
    param(
        [string]$Url,
        [int]$TimeoutSec = 20
    )

    try {
        $response = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        return [pscustomobject]@{
            ok         = $true
            content    = [string]$response.Content
            statusCode = if ($response.StatusCode) { [int]$response.StatusCode } else { 200 }
            error      = $null
        }
    }
    catch {
        return [pscustomobject]@{
            ok         = $false
            content    = $null
            statusCode = 0
            error      = $_.Exception.Message
        }
    }
}

function New-RemediationItem {
    param(
        [string]$Id,
        [string]$Title,
        [string]$Severity,
        [int]$Count,
        [string]$Why,
        [string[]]$Steps,
        [object[]]$Examples
    )

    return [pscustomobject]@{
        id       = $Id
        title    = $Title
        severity = $Severity
        count    = $Count
        why      = $Why
        steps    = $Steps
        examples = $Examples
    }
}

function Get-RemediationPlan {
    param([pscustomobject]$Report)

    $plan = New-Object System.Collections.Generic.List[object]

    if ($Report.summary.httpErrors -gt 0) {
        $examples = @($Report.details.httpErrors | Select-Object -First 10 -ExpandProperty finalUrl)
        $plan.Add((New-RemediationItem -Id "http-errors" -Title "Fix HTTP errors (4xx/5xx)" -Severity "High" -Count $Report.summary.httpErrors `
                    -Why "Broken URLs waste crawl budget and hurt index quality and user trust." `
                    -Steps @(
                    "Correct internal links that point to error pages.",
                    "Restore removed pages or 301 redirect them to the best equivalent page.",
                    "If content is intentionally removed, return 410 and remove internal links and sitemap entries.",
                    "Re-run the audit and verify HTTP errors are zero."
                ) -Examples $examples))
    }

    if ($Report.summary.missingCanonical -gt 0) {
        $examples = @($Report.details.missingCanonical | Select-Object -First 10 -ExpandProperty finalUrl)
        $plan.Add((New-RemediationItem -Id "missing-canonical" -Title "Add canonical tags" -Severity "High" -Count $Report.summary.missingCanonical `
                    -Why "Without canonical tags, duplicate or near-duplicate pages can split ranking signals." `
                    -Steps @(
                    'Add one rel="canonical" tag in the head on each indexable page.',
                    "Use an absolute URL that points to the preferred indexable version.",
                    "Ensure only one canonical tag exists per page.",
                    "Validate canonical destinations return 200 and are not noindex."
                ) -Examples $examples))
    }

    if ($Report.summary.nonAbsoluteCanonical -gt 0) {
        $examples = @($Report.details.nonAbsoluteCanonical | Select-Object -First 10 -ExpandProperty finalUrl)
        $plan.Add((New-RemediationItem -Id "non-absolute-canonical" -Title "Convert canonical URLs to absolute" -Severity "Medium" -Count $Report.summary.nonAbsoluteCanonical `
                    -Why "Relative canonical URLs can be interpreted inconsistently across environments and crawlers." `
                    -Steps @(
                    "Change canonical href values from relative paths to full https URLs.",
                    "Standardize trailing slash and index path behavior.",
                    "Verify generated canonical URLs match production hostname."
                ) -Examples $examples))
    }

    if ($Report.summary.duplicateTitles -gt 0) {
        $examples = @($Report.details.duplicateTitles | Select-Object -First 5)
        $plan.Add((New-RemediationItem -Id "duplicate-titles" -Title "Resolve duplicate title clusters" -Severity "Medium" -Count $Report.summary.duplicateTitles `
                    -Why "Duplicate titles reduce relevance signaling and make SERP snippets less useful." `
                    -Steps @(
                    "Make each title unique and aligned to the page intent.",
                    "Keep primary intent terms near the start.",
                    "Templatize titles with route-specific context where needed."
                ) -Examples $examples))
    }

    if ($Report.summary.duplicateDescriptions -gt 0) {
        $examples = @($Report.details.duplicateDescriptions | Select-Object -First 5)
        $plan.Add((New-RemediationItem -Id "duplicate-descriptions" -Title "Resolve duplicate meta descriptions" -Severity "Low" -Count $Report.summary.duplicateDescriptions `
                    -Why "Repeated descriptions reduce snippet usefulness and weaken click-through opportunity." `
                    -Steps @(
                    "Write unique descriptions for key landing pages.",
                    "Use dynamic metadata templates for large content sets.",
                    "Keep descriptions concise and intent-matched."
                ) -Examples $examples))
    }

    if ($Report.summary.noindexPages -gt 0) {
        $examples = @($Report.details.noindexPages | Select-Object -First 10 -ExpandProperty finalUrl)
        $plan.Add((New-RemediationItem -Id "noindex-pages" -Title "Review noindex pages" -Severity "Medium" -Count $Report.summary.noindexPages `
                    -Why "Accidental noindex on important pages can remove them from search results." `
                    -Steps @(
                    "Confirm whether each noindex page is intentional.",
                    "Remove noindex from pages that should rank.",
                    "Ensure canonical and noindex do not conflict on key pages."
                ) -Examples $examples))
    }

    if ($Report.summary.redirectChains -gt 0) {
        $examples = @($Report.details.redirectChains | Select-Object -First 10 -ExpandProperty finalUrl)
        $plan.Add((New-RemediationItem -Id "redirect-chains" -Title "Collapse long redirect chains" -Severity "Low" -Count $Report.summary.redirectChains `
                    -Why "Multiple redirect hops slow crawl and user requests and can dilute signals." `
                    -Steps @(
                    "Update internal links to point directly to final destination URLs.",
                    "Replace multi-hop redirects with single-hop redirects.",
                    "Keep redirect mappings documented and tested in deployment checks."
                ) -Examples $examples))
    }

    if ($Report.summary.sitemapOrphans -gt 0) {
        $examples = @($Report.details.sitemapOrphans | Select-Object -First 10)
        $plan.Add((New-RemediationItem -Id "sitemap-orphans" -Title "Fix sitemap orphan URLs" -Severity "Medium" -Count $Report.summary.sitemapOrphans `
                    -Why "Sitemap URLs that are not reachable from crawl paths often indicate stale or disconnected content." `
                    -Steps @(
                    "Remove stale URLs from sitemap files.",
                    "Add internal links for URLs that should remain indexed.",
                    "Ensure sitemap entries return 200 and contain canonical, indexable content."
                ) -Examples $examples))
    }

    if ($Report.summary.renderedDiffPages -gt 0) {
        $examples = @($Report.details.rendered.diffs | Select-Object -First 10 -ExpandProperty url)
        $plan.Add((New-RemediationItem -Id "rendered-diffs" -Title "Align rendered and raw metadata" -Severity "Low" -Count $Report.summary.renderedDiffPages `
                    -Why "Mismatch between server and rendered metadata can confuse crawlers and social preview parsers." `
                    -Steps @(
                    "Prefer server-rendered metadata for critical tags when possible.",
                    "If metadata is client-generated, ensure deterministic output before crawler snapshot.",
                    "Validate title, description, canonical, OG, and Twitter values in both views."
                ) -Examples $examples))
    }

    return $plan
}

function Resolve-ReportPath {
    param([string]$HtmlReportPath)

    if (-not [string]::IsNullOrWhiteSpace($HtmlReportPath)) {
        if ([System.IO.Path]::IsPathRooted($HtmlReportPath)) {
            return $HtmlReportPath
        }
        return (Join-Path -Path (Get-Location).Path -ChildPath $HtmlReportPath)
    }

    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    return (Join-Path -Path (Get-Location).Path -ChildPath ("seo-geo-audit-report-{0}.html" -f $stamp))
}

function Convert-ReportToHtml {
    param(
        [pscustomobject]$Report,
        [object[]]$RemediationPlan
    )

    $enc = [System.Net.WebUtility]::HtmlEncode

    $checkRows = foreach ($k in $Report.score.checks.Keys) {
        $ok = [bool]$Report.score.checks[$k]
        $state = if ($ok) { "PASS" } else { "FAIL" }
        $rowClass = if ($ok) { "pass" } else { "fail" }
        "<tr class='$rowClass'><td>$($enc.Invoke($k))</td><td>$state</td></tr>"
    }

    $summaryCards = @(
        @{ label = "HTTP Errors"; value = $Report.summary.httpErrors },
        @{ label = "Missing Canonical"; value = $Report.summary.missingCanonical },
        @{ label = "Duplicate Titles"; value = $Report.summary.duplicateTitles },
        @{ label = "Sitemap Orphans"; value = $Report.summary.sitemapOrphans },
        @{ label = "Rendered Diffs"; value = $Report.summary.renderedDiffPages }
    ) | ForEach-Object {
        "<div class='stat-card'><div class='stat-value'>$($_.value)</div><div class='stat-label'>$($enc.Invoke($_.label))</div></div>"
    }

    $remediationBlocks = foreach ($item in $RemediationPlan) {
        $severityClass = $item.severity.ToLower()
        $steps = ($item.steps | ForEach-Object { "<li>$($enc.Invoke($_))</li>" }) -join ""

        $exampleHtml = ""
        if ($item.examples -and $item.examples.Count -gt 0) {
            $exampleHtml = "<div class='examples'><h4>Examples</h4><ul>"
            foreach ($ex in $item.examples) {
                if ($null -eq $ex) { continue }
                if ($ex -is [string]) {
                    $exampleHtml += "<li><code>$($enc.Invoke($ex))</code></li>"
                }
                elseif ($ex.PSObject.Properties.Name -contains "value") {
                    $exampleHtml += "<li><strong>$($enc.Invoke([string]$ex.value))</strong> ($($ex.count))</li>"
                }
                else {
                    $exampleHtml += "<li><code>$($enc.Invoke(([string]$ex)) )</code></li>"
                }
            }
            $exampleHtml += "</ul></div>"
        }

        @"
<section class='remediation'>
    <div class='remediation-head'>
        <h3>$($enc.Invoke($item.title))</h3>
        <span class='badge $severityClass'>$($enc.Invoke($item.severity))</span>
    </div>
    <p><strong>Affected:</strong> $($item.count)</p>
    <p>$($enc.Invoke($item.why))</p>
    <h4>How to fix</h4>
    <ol>$steps</ol>
    $exampleHtml
</section>
"@
    }

    $completionPercent = [math]::Max(0, [math]::Min(100, [double]$Report.score.value))

    return @"
<!DOCTYPE html>
<html lang='en'>
<head>
    <meta charset='utf-8' />
    <meta name='viewport' content='width=device-width, initial-scale=1' />
    <title>SEO/GEO Audit Report</title>
    <style>
        :root {
            --bg: #031316;
            --bg-2: #041b1f;
            --panel: #04181b;
            --panel-2: #072126;
            --line: #0b4e57;
            --line-soft: #0a3940;
            --ink: #b9f3f4;
            --muted: #66b7bd;
            --brand: #08d2d3;
            --brand-2: #cfd03d;
            --ok: #40f0a4;
            --warn: #ffd166;
            --bad: #ff6c7f;
            --cmd: #00e5df;
            --code: #86f3ff;
        }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            color: var(--ink);
            font-family: "Cascadia Code", "Consolas", monospace;
            background: radial-gradient(circle at 16% -14%, #0a3e45 0%, transparent 26%), var(--bg);
        }
        body::before {
            content: "";
            position: fixed;
            inset: 0;
            pointer-events: none;
            opacity: 0.16;
            background: repeating-linear-gradient(0deg, transparent, transparent 24px, rgba(108, 248, 255, 0.08) 25px);
        }
        .shell {
            position: relative;
            z-index: 1;
            max-width: 1280px;
            margin: 0 auto;
            border-left: 1px solid var(--line-soft);
            border-right: 1px solid var(--line-soft);
            min-height: 100vh;
        }
        .top-strip {
            display: flex;
            justify-content: flex-end;
            align-items: center;
            gap: 10px;
            padding: 10px 16px;
            background: #010a0d;
            border-bottom: 1px solid var(--line);
            flex-wrap: wrap;
        }
        .top-links {
            display: flex;
            gap: 16px;
            color: #8ad7dc;
            font-size: 12px;
            flex-wrap: wrap;
        }
        .link {
            color: inherit;
            text-decoration: none;
            border: 1px solid var(--line);
            padding: 6px 10px;
            background: linear-gradient(90deg, #07363d, #0d2a42);
            text-transform: lowercase;
            display: inline-block;
        }
        .link:hover {
            color: #d0ffff;
            border-color: var(--brand);
        }
        .mid-strip {
            padding: 8px 16px;
            border-bottom: 1px solid var(--line-soft);
            color: #7dc9cf;
            font-size: 12px;
        }
        .mid-strip span { margin-right: 14px; }
        .wrap {
            padding: 26px 20px 20px 20px;
        }
        .hero {
            display: block;
            background: linear-gradient(180deg, #021a1d, #021418);
            border: 1px solid var(--line-soft);
            padding: 26px;
            min-height: 0;
        }
        .terminal-line {
            color: var(--cmd);
            font-size: 13px;
            margin-bottom: 10px;
        }
        .hero h1 {
            margin: 0;
            font-size: clamp(2rem, 4.2vw, 3.25rem);
            line-height: 1.05;
            color: var(--brand);
        }
        .hero h1 .uri {
            display: block;
            color: #b8d9d7;
            font-size: clamp(1.6rem, 3.4vw, 2.8rem);
            margin-top: 2px;
        }
        .hero h1 .host {
            color: var(--brand-2);
            word-break: break-word;
        }
        .meta {
            color: #76bbc0;
            font-size: 12px;
            margin-top: 8px;
        }
        .summary {
            color: #8ac6ca;
            max-width: 680px;
            line-height: 1.6;
            font-size: 14px;
            margin-top: 16px;
        }
        .prompt {
            margin-top: 14px;
            background: #000d10;
            border: 1px solid #0b5962;
            border-radius: 0;
            padding: 10px 12px;
            font-size: 12px;
            color: var(--code);
        }
        .prompt .ps {
            color: var(--cmd);
            font-weight: 700;
        }
        .cta-row {
            display: flex;
            gap: 10px;
            margin-top: 12px;
            flex-wrap: wrap;
        }
        .btn {
            border: 1px solid var(--line);
            background: #03333a;
            color: #a4f5f8;
            padding: 9px 12px;
            font-size: 12px;
        }
        .btn.alt {
            background: transparent;
            border-color: #1b6d75;
        }
        .score {
            margin-top: 14px;
            background: #001014;
            border: 1px solid #0b5962;
            border-radius: 0;
            overflow: hidden;
        }
        .score-label {
            padding: 10px 14px;
            color: #a5edf0;
            font-size: 13px;
            font-weight: 700;
        }
        .score-bar { height: 9px; background: #001216; }
        .score-fill {
            height: 100%;
            width: $completionPercent%;
            background: linear-gradient(90deg, #0de8df, #b7d331);
            box-shadow: 0 0 14px rgba(13, 232, 223, 0.5);
        }
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(155px, 1fr));
            gap: 10px;
            margin-top: 14px;
        }
        .stat-card {
            background: linear-gradient(180deg, #032126, #04171b);
            border: 1px solid #0e5961;
            border-radius: 0;
            padding: 12px;
        }
        .stat-value {
            font-size: 24px;
            font-weight: 800;
            color: #c2f9fb;
        }
        .stat-label {
            margin-top: 2px;
            color: #6fc0c7;
            font-size: 11px;
            letter-spacing: 0.4px;
            text-transform: uppercase;
        }
        .command-divider {
            border-top: 1px solid var(--line-soft);
            margin: 0 20px;
            padding: 14px 0;
            color: var(--cmd);
            font-size: 12px;
        }
        .section {
            background: linear-gradient(180deg, var(--panel), var(--panel-2));
            border: 1px solid var(--line-soft);
            border-radius: 0;
            padding: 16px;
            margin: 0 20px 14px 20px;
            box-shadow: none;
        }
        .section h2 {
            margin: 0 0 10px 0;
            color: var(--brand);
            font-size: 1rem;
            text-transform: uppercase;
            letter-spacing: 0.8px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            border: 1px solid #0d4c54;
            border-radius: 0;
            overflow: hidden;
            font-size: 13px;
        }
        thead { background: #06282d; }
        th, td {
            padding: 9px 10px;
            border-bottom: 1px solid #0d3d45;
            text-align: left;
        }
        th { color: #92d5d9; font-weight: 700; }
        tr.pass td:last-child { color: var(--ok); font-weight: 700; }
        tr.fail td:last-child { color: var(--bad); font-weight: 800; }
        tr:hover { background: rgba(13, 210, 211, 0.08); }
        .remediation {
            border: 1px solid #0d4f58;
            border-left: 4px solid var(--brand);
            border-radius: 0;
            padding: 14px;
            margin-bottom: 10px;
            background: rgba(4, 27, 31, 0.8);
        }
        .remediation-head {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 8px;
            flex-wrap: wrap;
        }
        .remediation h3 {
            margin: 0;
            font-size: 0.98rem;
            color: #d8e8ff;
        }
        .remediation p, .remediation li {
            color: #9cc8cb;
            font-size: 13px;
            line-height: 1.5;
        }
        .badge {
            font-size: 11px;
            font-weight: 800;
            border-radius: 999px;
            padding: 3px 9px;
            border: 1px solid transparent;
            text-transform: uppercase;
            letter-spacing: 0.4px;
        }
        .badge.high { background: rgba(255, 108, 127, 0.16); border-color: rgba(255, 108, 127, 0.45); color: var(--bad); }
        .badge.medium { background: rgba(255, 209, 102, 0.14); border-color: rgba(255, 209, 102, 0.5); color: var(--warn); }
        .badge.low { background: rgba(64, 240, 164, 0.14); border-color: rgba(64, 240, 164, 0.5); color: var(--ok); }
        code {
            background: #03171a;
            border: 1px solid #0a5860;
            border-radius: 0;
            padding: 1px 5px;
            color: var(--code);
            font-size: 12px;
        }
        .examples h4 {
            color: #85d4da;
            margin: 10px 0 6px 0;
            font-size: 0.9rem;
        }
        .examples ul {
            margin: 0;
            padding-left: 18px;
        }
        @media (max-width: 900px) {
            .top-links {
                gap: 10px;
            }
        }
        @media (max-width: 720px) {
            .wrap { padding: 14px 14px 10px 14px; }
            .hero { padding: 14px; }
            .section { margin: 0 14px 12px 14px; }
            .command-divider { margin: 0 14px; }
            th, td, .remediation p, .remediation li { font-size: 12px; }
        }
    </style>
</head>
<body>
    <main class='shell'>
        <div class='top-strip'>
            <div class='top-links'>
                <a class='link' href='https://learn.cloudpartner.fi' target='_blank' rel='noopener noreferrer'>cloudpartner</a>
                <a class='link' href='https://intro.cloudpartner.fi' target='_blank' rel='noopener noreferrer'>intro</a>
            </div>
        </div>

        <div class='mid-strip'>
            <span>seo</span><span>geo</span><span>technical audit</span><span>canonical</span><span>metadata</span>
        </div>

        <div class='wrap'>
            <section class='hero'>
                <div>
                    <div class='terminal-line'>PS AuditUser:~/SEO&gt; Get-LatestFindings</div>
                    <div class='terminal-line'># seo geo audit report · host profile · $($Report.crawl.pagesCrawled) crawled pages</div>
                    <h1>Invoke-SEOGeoReport
                        <span class='uri'>-TargetHost <span class='host'>"$($enc.Invoke($Report.host))"</span></span>
                    </h1>
                    <div class='summary'>Focused technical SEO/GEO diagnostics for canonicalization, crawl reachability, metadata duplication, noindex traps, and sitemap consistency.</div>
                    <div class='meta'>Start URL: $($enc.Invoke($Report.startUrl)) | Generated: $($enc.Invoke($Report.timestamp))</div>

                    <div class='stats-grid'>
                        $($summaryCards -join "`n")
                    </div>

                    <div class='cta-row'>
                        <button class='btn'>./latest-findings</button>
                        <button class='btn alt'>./visit-remediation</button>
                    </div>

                    <div class='prompt'><span class='ps'>PS SEO:\></span> Invoke-SEOGeoReport -StartUrl "$($enc.Invoke($Report.startUrl))" -AsHtml</div>

                    <div class='score'>
                        <div class='score-label'>Score: $($Report.score.value)% ($($Report.score.passed)/$($Report.score.total))</div>
                        <div class='score-bar'><div class='score-fill'></div></div>
                    </div>
                </div>
            </section>
        </div>

        <div class='command-divider'>PS AuditUser:~/Reports&gt; Get-ActionPlan | Sort-Object Severity</div>

        <section class='section'>
            <h2>// Quality Checks</h2>
            <table>
                <thead><tr><th>Check</th><th>Status</th></tr></thead>
                <tbody>
                    $($checkRows -join "`n")
                </tbody>
            </table>
        </section>

        <section class='section'>
            <h2>// Action Plan</h2>
            <p>Fix issues from high severity to low severity. Re-run the audit after each round and track score improvements.</p>
            $($remediationBlocks -join "`n")
        </section>
    </main>
</body>
</html>
"@
}

if ([string]::IsNullOrWhiteSpace($StartUrl)) {
    throw "StartUrl is required. Example: .\seo-geo-audit.ps1 -StartUrl https://example.com -MaxPages 200 -MaxDepth 3"
}

$start = Normalize-Url -Url $StartUrl
if (-not $start) {
    throw "Invalid StartUrl: $StartUrl"
}

$targetHost = ([System.Uri]$start).Host
$sitemapCandidates = Get-SitemapCandidates -StartUrl $start -SitemapUrl $SitemapUrl -TimeoutSec $TimeoutSec

$queue = New-Object System.Collections.Generic.Queue[object]
$queue.Enqueue([pscustomobject]@{ url = $start; depth = 0; parent = $null })

$visited = New-Object 'System.Collections.Generic.HashSet[string]'
$inlinks = @{}
$pages = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]

while ($queue.Count -gt 0 -and $pages.Count -lt $MaxPages) {
    $item = $queue.Dequeue()
    $url = $item.url
    $depth = $item.depth

    if ($visited.Contains($url)) { continue }
    $null = $visited.Add($url)

    $result = Invoke-HttpWithRedirects -Url $url -TimeoutSec $TimeoutSec -MaxRedirects $MaxRedirects
    if ($result.error) {
        $errors.Add([pscustomobject]@{ url = $url; error = $result.error })
        continue
    }

    $signals = [ordered]@{}
    $links = @()
    $xRobots = ""
    if ($result.headers.ContainsKey("X-Robots-Tag")) { $xRobots = $result.headers["X-Robots-Tag"] }

    if (-not [string]::IsNullOrWhiteSpace($result.content)) {
        $signals = Get-RawSignals -Html $result.content
        $links = Extract-Links -Html $result.content -BaseUrl $result.finalUrl -TargetHost $targetHost
    }

    foreach ($lnk in $links) {
        if (-not $inlinks.ContainsKey($lnk)) { $inlinks[$lnk] = 0 }
        $inlinks[$lnk] += 1

        if ($depth + 1 -le $MaxDepth -and -not $visited.Contains($lnk)) {
            $queue.Enqueue([pscustomobject]@{ url = $lnk; depth = $depth + 1; parent = $url })
        }
    }

    $robotsCombined = (($signals.robots + "," + $xRobots).ToLower())
    $isNoindex = $robotsCombined -match 'noindex'

    $pages.Add([pscustomobject]@{
            url           = $url
            finalUrl      = $result.finalUrl
            statusCode    = $result.statusCode
            redirectCount = $result.redirectCount
            redirectChain = $result.redirectChain
            depth         = $depth
            title         = $signals.title
            description   = $signals.description
            canonical     = $signals.canonical
            robots        = $signals.robots
            xRobotsTag    = $xRobots
            ogTitle       = $signals.ogTitle
            ogDescription = $signals.ogDescription
            ogUrl         = $signals.ogUrl
            ogImage       = $signals.ogImage
            twitterCard   = $signals.twitterCard
            hasJsonLd     = $signals.hasJsonLd
            noindex       = $isNoindex
            outlinkCount  = $links.Count
        })
}

# Diagnostics
$httpErrors = @($pages | Where-Object { $_.statusCode -ge 400 })
$redirectChains = @($pages | Where-Object { $_.redirectCount -gt 1 })
$missingCanonical = @($pages | Where-Object { [string]::IsNullOrWhiteSpace($_.canonical) })
$nonAbsoluteCanonical = @($pages | Where-Object { -not [string]::IsNullOrWhiteSpace($_.canonical) -and $_.canonical -notmatch '^https?://' })
$noindexPages = @($pages | Where-Object { $_.noindex -eq $true })

$dupeTitles = $pages |
Group-Object -Property title |
Where-Object { $_.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($_.Name) } |
ForEach-Object {
    [pscustomobject]@{
        value = $_.Name
        count = $_.Count
        urls  = $_.Group.url
    }
}

$dupeDescriptions = $pages |
Group-Object -Property description |
Where-Object { $_.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($_.Name) } |
ForEach-Object {
    [pscustomobject]@{
        value = $_.Name
        count = $_.Count
        urls  = $_.Group.url
    }
}

$orphanFromSitemap = @()
$sitemapUrls = @()
foreach ($candidate in $sitemapCandidates) {
    $parsed = Parse-SitemapUrls -SitemapUrl $candidate -TimeoutSec $TimeoutSec
    if ($parsed.Count -gt 0) {
        $sitemapUrls = ($sitemapUrls + $parsed) | Sort-Object -Unique
    }
}
if ($sitemapUrls.Count -gt 0) {
    $crawledSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in $pages) { $null = $crawledSet.Add((Normalize-Url -Url $p.finalUrl)) }

    $orphanFromSitemap = $sitemapUrls | Where-Object { -not $crawledSet.Contains($_) }
}

# Rendered-vs-raw checks
$renderedDiffs = @()
$renderInfo = [pscustomobject]@{ enabled = [bool]$RenderedChecks; browser = $null; sampled = 0; failed = 0 }
if ($RenderedChecks) {
    $browser = Find-BrowserForRendering -BrowserPath $BrowserPath
    $renderInfo.browser = $browser

    $sample = $pages | Select-Object -First $RenderedSampleSize
    $renderInfo.sampled = $sample.Count

    foreach ($p in $sample) {
        $r = Get-RenderedDom -Browser $browser -Url $p.finalUrl -TimeoutSec $TimeoutSec
        if (-not $r.ok) {
            $renderInfo.failed += 1
            continue
        }

        $rawSignals = [ordered]@{
            title         = $p.title
            description   = $p.description
            canonical     = $p.canonical
            ogTitle       = $p.ogTitle
            ogDescription = $p.ogDescription
            ogUrl         = $p.ogUrl
            ogImage       = $p.ogImage
            twitterCard   = $p.twitterCard
        }
        $renderedSignals = Get-RawSignals -Html $r.html

        $keys = @('title', 'description', 'canonical', 'ogTitle', 'ogDescription', 'ogUrl', 'ogImage', 'twitterCard')
        $delta = [ordered]@{}
        foreach ($k in $keys) {
            $rawVal = ([string]$rawSignals[$k]).Trim()
            $renVal = ([string]$renderedSignals[$k]).Trim()
            if ($rawVal -ne $renVal) {
                $delta[$k] = [pscustomobject]@{ raw = $rawVal; rendered = $renVal }
            }
        }

        if ($delta.Count -gt 0) {
            $renderedDiffs += [pscustomobject]@{
                url   = $p.finalUrl
                diffs = $delta
            }
        }
    }
}

# Score (quality score)
$checks = [ordered]@{
    crawled_pages             = ($pages.Count -gt 0)
    no_http_errors            = ($httpErrors.Count -eq 0)
    no_long_redirect_chains   = ($redirectChains.Count -eq 0)
    no_missing_canonical      = ($missingCanonical.Count -eq 0)
    no_non_absolute_canonical = ($nonAbsoluteCanonical.Count -eq 0)
    no_duplicate_titles       = ($dupeTitles.Count -eq 0)
    no_duplicate_descriptions = ($dupeDescriptions.Count -eq 0)
    no_noindex_traps          = ($noindexPages.Count -eq 0)
    no_sitemap_orphans        = ($orphanFromSitemap.Count -eq 0)
    rendered_parity_ok        = (($RenderedChecks -eq $false) -or ($renderedDiffs.Count -eq 0))
}

$totalChecks = $checks.Count
$passedChecks = @($checks.Values | Where-Object { $_ -eq $true }).Count
$score = if ($totalChecks -eq 0) { 0 } else { [math]::Round(($passedChecks / $totalChecks) * 100, 1) }

$report = [pscustomobject]@{
    timestamp = (Get-Date).ToString('s')
    startUrl  = $start
    host      = $targetHost
    crawl     = [pscustomobject]@{
        pagesCrawled = $pages.Count
        maxPages     = $MaxPages
        maxDepth     = $MaxDepth
        errors       = $errors.Count
    }
    score     = [pscustomobject]@{
        value  = $score
        passed = $passedChecks
        total  = $totalChecks
        checks = $checks
    }
    summary   = [pscustomobject]@{
        httpErrors            = $httpErrors.Count
        redirectChains        = $redirectChains.Count
        missingCanonical      = $missingCanonical.Count
        nonAbsoluteCanonical  = $nonAbsoluteCanonical.Count
        duplicateTitles       = $dupeTitles.Count
        duplicateDescriptions = $dupeDescriptions.Count
        noindexPages          = $noindexPages.Count
        sitemapUrls           = $sitemapUrls.Count
        sitemapOrphans        = $orphanFromSitemap.Count
        renderedDiffPages     = $renderedDiffs.Count
        sitemapCandidates     = $sitemapCandidates.Count
    }
    details   = [pscustomobject]@{
        httpErrors            = $httpErrors
        redirectChains        = $redirectChains
        missingCanonical      = $missingCanonical
        nonAbsoluteCanonical  = $nonAbsoluteCanonical
        duplicateTitles       = $dupeTitles
        duplicateDescriptions = $dupeDescriptions
        noindexPages          = $noindexPages
        sitemapOrphans        = $orphanFromSitemap
        sitemapCandidates     = $sitemapCandidates
        rendered              = [pscustomobject]@{
            info  = $renderInfo
            diffs = $renderedDiffs
        }
    }
}

$remediationPlan = Get-RemediationPlan -Report $report
$report | Add-Member -NotePropertyName remediationPlan -NotePropertyValue $remediationPlan

$htmlOutputPath = $null
if ($AsHtml -or -not [string]::IsNullOrWhiteSpace($HtmlReportPath)) {
    $htmlOutputPath = Resolve-ReportPath -HtmlReportPath $HtmlReportPath
    $htmlDir = Split-Path -Parent $htmlOutputPath
    if (-not [string]::IsNullOrWhiteSpace($htmlDir) -and -not (Test-Path -LiteralPath $htmlDir)) {
        New-Item -Path $htmlDir -ItemType Directory -Force | Out-Null
    }

    $html = Convert-ReportToHtml -Report $report -RemediationPlan $remediationPlan
    Set-Content -Path $htmlOutputPath -Value $html -Encoding UTF8

    $report | Add-Member -NotePropertyName outputs -NotePropertyValue ([pscustomobject]@{ htmlReportPath = $htmlOutputPath }) -Force
}

if ($AsJson) {
    $report | ConvertTo-Json -Depth 12
    exit 0
}

Write-Host ""
Write-Host "SEO/GEO Audit" -ForegroundColor Cyan
Write-Host "Start URL: $($report.startUrl)"
Write-Host "Host: $($report.host)"
Write-Host ""
Write-Host ("Score: {0}% ({1}/{2})" -f $report.score.value, $report.score.passed, $report.score.total) -ForegroundColor Green
Write-Host ""
Write-Host ("Crawled pages: {0}" -f $report.crawl.pagesCrawled)
Write-Host ("HTTP errors: {0}" -f $report.summary.httpErrors)
Write-Host ("Redirect chains (>1): {0}" -f $report.summary.redirectChains)
Write-Host ("Missing canonical: {0}" -f $report.summary.missingCanonical)
Write-Host ("Non-absolute canonical: {0}" -f $report.summary.nonAbsoluteCanonical)
Write-Host ("Duplicate titles: {0}" -f $report.summary.duplicateTitles)
Write-Host ("Duplicate descriptions: {0}" -f $report.summary.duplicateDescriptions)
Write-Host ("Noindex pages: {0}" -f $report.summary.noindexPages)
Write-Host ("Sitemap candidates: {0}" -f $report.summary.sitemapCandidates)
Write-Host ("Sitemap URLs: {0}" -f $report.summary.sitemapUrls)
Write-Host ("Sitemap orphans: {0}" -f $report.summary.sitemapOrphans)
Write-Host ("Rendered-vs-raw diff pages: {0}" -f $report.summary.renderedDiffPages)
Write-Host ""

if ($htmlOutputPath) {
    Write-Host ("HTML report: {0}" -f $htmlOutputPath) -ForegroundColor Cyan
    Write-Host ""
}

if ($remediationPlan.Count -gt 0) {
    Write-Host "Priority action plan:" -ForegroundColor Yellow
    foreach ($item in $remediationPlan) {
        Write-Host ("  [{0}] {1} ({2})" -f $item.severity, $item.title, $item.count)
    }
    Write-Host ""
}

if ($report.summary.httpErrors -gt 0) {
    Write-Host "Top HTTP errors:" -ForegroundColor Yellow
    $report.details.httpErrors | Select-Object -First 10 | ForEach-Object {
        Write-Host ("  {0} -> {1}" -f $_.finalUrl, $_.statusCode)
    }
    Write-Host ""
}

if ($report.summary.sitemapOrphans -gt 0) {
    Write-Host "Top sitemap orphans:" -ForegroundColor Yellow
    $report.details.sitemapOrphans | Select-Object -First 10 | ForEach-Object {
        Write-Host ("  {0}" -f $_)
    }
    Write-Host ""
}

if ($RenderedChecks -and $renderInfo.browser) {
    Write-Host ("Rendered checks used browser: {0}" -f $renderInfo.browser)
}
elseif ($RenderedChecks -and -not $renderInfo.browser) {
    Write-Host "Rendered checks requested, but no supported browser was found (msedge/chrome/chromium)." -ForegroundColor Yellow
}
