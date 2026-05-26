# SEO/GEO Audit Tool

This README documents the PowerShell checker:
- seo-geo-audit.ps1

The tool performs a crawl-based SEO/GEO audit without paid APIs.

## What it checks

- Crawl reachability within a host
- HTTP errors (4xx/5xx)
- Redirect chains longer than one hop
- Missing canonical tags
- Non-absolute canonical URLs
- Duplicate title clusters
- Duplicate description clusters
- Noindex traps
- Sitemap discovery and sitemap orphan URLs
- Optional rendered-vs-raw metadata differences

## Parameters

- StartUrl (required): Root URL to start crawling from
- MaxPages (default: 200): Maximum number of pages to crawl
- MaxDepth (default: 3): Crawl depth from StartUrl
- TimeoutSec (default: 20): Request/render timeout in seconds
- MaxRedirects (default: 8): Max redirect hops per URL
- SitemapUrl (optional): Explicit sitemap URL override
- RenderedChecks (switch): Enable headless rendered-vs-raw comparison
- BrowserPath (optional): Explicit browser executable path for rendered checks
- RenderedSampleSize (default: 20): Number of crawled pages to compare rendered vs raw
- AsJson (switch): Output full report as JSON
- AsHtml (switch): Output visual HTML report
- HtmlReportPath (optional): Path for HTML report output

## Basic usage

Run from repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\seo-geo-audit.ps1 -StartUrl https://example.com/ -MaxPages 200 -MaxDepth 3
```

JSON output:

```powershell
powershell -ExecutionPolicy Bypass -File .\seo-geo-audit.ps1 -StartUrl https://example.com/ -MaxPages 200 -MaxDepth 3 -AsJson
```

HTML report output:

```powershell
powershell -ExecutionPolicy Bypass -File .\seo-geo-audit.ps1 -StartUrl https://example.com/ -AsHtml
```

HTML report with explicit path:

```powershell
powershell -ExecutionPolicy Bypass -File .\seo-geo-audit.ps1 -StartUrl https://example.com/ -AsHtml -HtmlReportPath .\reports\seo-report.html
```

## HTML report contents

The generated HTML report includes:

- Visual score and summary counters
- Quality checks table (pass/fail)
- Prioritized action plan with remediation steps
- Command-style header theme for SEO/GEO report output
- Top quick links for:
   - https://learn.cloudpartner.fi
   - https://intro.cloudpartner.fi

Rendered-vs-raw checks:

```powershell
powershell -ExecutionPolicy Bypass -File .\seo-geo-audit.ps1 -StartUrl https://example.com/ -RenderedChecks -RenderedSampleSize 20
```

Rendered checks with explicit Edge path:

```powershell
powershell -ExecutionPolicy Bypass -File .\seo-geo-audit.ps1 -StartUrl https://example.com/ -RenderedChecks -BrowserPath "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
```

## How scoring works

The script uses 10 pass/fail checks:

1. crawled_pages
2. no_http_errors
3. no_long_redirect_chains
4. no_missing_canonical
5. no_non_absolute_canonical
6. no_duplicate_titles
7. no_duplicate_descriptions
8. no_noindex_traps
9. no_sitemap_orphans
10. rendered_parity_ok (only fails when RenderedChecks is enabled and diffs are found)

Final score is:

- passed checks / 10
- reported as percentage and ratio, for example 90% (9/10)

## Sitemap discovery behavior

If SitemapUrl is not provided, candidates are assembled from:

- robots.txt Sitemap directives
- /sitemap.xml
- /sitemap_index.xml
- /sitemap-index.xml
- /posts/sitemap.xml

The script parses URL sets and sitemap indexes recursively.

## URL normalization behavior

To reduce false duplicates, the script normalizes:

- URL fragments removed
- trailing slash trimmed (except root)
- /index.html, /index.htm, /index.xhtml normalized to root-equivalent path

## Current placeholder-link filter

The crawler ignores obvious template placeholders in href values, such as:

- ${...}
- {{...}}
- encoded braces %7B / %7D

This prevents false 404 findings from template artifacts.

## Typical workflow

1. Run audit with AsJson.
2. Fix in this order:
   - HTTP errors
   - canonical issues
   - duplicate title/description clusters
   - unintended noindex
   - sitemap orphans
3. Re-run and compare score.
4. Optionally run RenderedChecks for JS-rendered metadata parity.

## Troubleshooting

### Error: StartUrl is required
Provide StartUrl explicitly:

```powershell
-StartUrl https://example.com/
```

### Rendered checks warning: no browser found
Install Edge/Chrome/Chromium or pass BrowserPath.

### Sitemap URLs = 0
Possible causes:
- No sitemap published
- robots.txt missing Sitemap directives
- sitemap endpoint blocked/unreachable
- non-XML sitemap format not currently parsed by this tool

### Score includes utility pages
If utility pages are crawled (for example menu/index aliases), either:
- add canonical metadata to those pages
- or add an exclusion strategy in future script updates

## Suggested next improvements

- Add path exclusion parameter (for utility endpoints)
- Add sitemap .gz and text sitemap support
- Add report export path parameter
- Add change-baseline comparison mode for CI

## Python scanner/fixer for client repos

The repository includes a safe Python scanner/fixer script:

- repo_issue_scanner_fixer.py

What it does:

- Scans HTML files for missing canonical tags
- Scans for non-absolute canonical URLs
- Detects duplicate title clusters
- Detects duplicate description clusters
- Can apply safe canonical fixes (opt-in)

Safety behavior:

- Default is dry-run (no file writes)
- Writes changes only when `--apply` is provided
- Automatic fixes are intentionally limited to canonical tag issues
- Ignores common generated/output folders by default (for example `reports`, `dist`, `build`, `node_modules`)

Dry-run scan with JSON report:

```powershell
python .\repo_issue_scanner_fixer.py --repo . --base-url https://example.com --output-json .\reports\repo-issues.json
```

Apply safe canonical fixes:

```powershell
python .\repo_issue_scanner_fixer.py --repo . --base-url https://example.com --apply --output-json .\reports\repo-issues-after-fix.json
```
