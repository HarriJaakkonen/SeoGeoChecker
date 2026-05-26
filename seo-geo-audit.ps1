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
    [switch]$AsJson
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
