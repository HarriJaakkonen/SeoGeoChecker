#!/usr/bin/env python3
"""
Safe repository scanner and fixer for common SEO metadata issues.

Default mode is read-only (dry run).
Use --apply to write changes.
"""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import urljoin


TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)
DESC_RE = re.compile(
    r"<meta[^>]*name=[\"']description[\"'][^>]*content=[\"'](.*?)[\"'][^>]*>",
    re.IGNORECASE | re.DOTALL,
)
CANON_RE = re.compile(
    r"<link[^>]*rel=[\"']canonical[\"'][^>]*href=[\"'](.*?)[\"'][^>]*>",
    re.IGNORECASE | re.DOTALL,
)
HEAD_OPEN_RE = re.compile(r"<head[^>]*>", re.IGNORECASE)
HEAD_CLOSE_RE = re.compile(r"</head>", re.IGNORECASE)


@dataclass
class FileIssue:
    path: str
    missing_canonical: bool
    non_absolute_canonical: bool
    canonical_value: str
    title: str
    description: str


@dataclass
class ScanSummary:
    files_scanned: int
    html_files: int
    missing_canonical: int
    non_absolute_canonical: int
    duplicate_titles: int
    duplicate_descriptions: int


@dataclass
class FixChange:
    path: str
    actions: List[str]


@dataclass
class ScanResult:
    summary: ScanSummary
    files: List[FileIssue]
    duplicate_title_clusters: List[Dict[str, object]]
    duplicate_description_clusters: List[Dict[str, object]]
    planned_fixes: List[FixChange]


TEXT_EXTENSIONS = {".html", ".htm"}
IGNORE_DIRS = {".git", "node_modules", "dist", "build", "bin", "obj", ".next", ".nuxt", "coverage", "reports"}
IGNORE_FILE_PREFIXES = ("seo-geo-audit-report-",)


def iter_html_files(root: Path) -> List[Path]:
    files: List[Path] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part.lower() in IGNORE_DIRS for part in path.parts):
            continue
        if path.name.lower().startswith(IGNORE_FILE_PREFIXES):
            continue
        if path.suffix.lower() in TEXT_EXTENSIONS:
            files.append(path)
    return files


def normalized_page_url(base_url: str, root: Path, file_path: Path) -> str:
    rel = file_path.relative_to(root).as_posix()
    if rel.endswith("index.html") or rel.endswith("index.htm"):
        rel = rel.rsplit("/", 1)[0] if "/" in rel else ""
    elif rel.endswith(".html"):
        rel = rel[:-5]
    elif rel.endswith(".htm"):
        rel = rel[:-4]
    if rel and not rel.endswith("/"):
        rel = rel + "/"
    return urljoin(base_url.rstrip("/") + "/", rel)


def extract_first(pattern: re.Pattern[str], text: str) -> str:
    match = pattern.search(text)
    if not match:
        return ""
    return re.sub(r"\s+", " ", match.group(1)).strip()


def analyze_file(path: Path) -> FileIssue:
    raw = path.read_text(encoding="utf-8", errors="ignore")
    title = extract_first(TITLE_RE, raw)
    description = extract_first(DESC_RE, raw)
    canonical = extract_first(CANON_RE, raw)
    missing = canonical == ""
    non_absolute = canonical != "" and not canonical.lower().startswith(("http://", "https://"))
    return FileIssue(
        path=str(path),
        missing_canonical=missing,
        non_absolute_canonical=non_absolute,
        canonical_value=canonical,
        title=title,
        description=description,
    )


def find_duplicates(values: List[Tuple[str, str]]) -> List[Dict[str, object]]:
    clusters: Dict[str, List[str]] = {}
    for value, path in values:
        key = value.strip()
        if not key:
            continue
        clusters.setdefault(key, []).append(path)
    result: List[Dict[str, object]] = []
    for value, paths in clusters.items():
        if len(paths) > 1:
            result.append({"value": value, "count": len(paths), "paths": sorted(paths)})
    result.sort(key=lambda x: x["count"], reverse=True)
    return result


def make_canonical_tag(url: str) -> str:
    return f'<link rel="canonical" href="{url}">'


def apply_fix_to_file(path: Path, base_url: str, root: Path, dry_run: bool) -> List[str]:
    actions: List[str] = []
    content = path.read_text(encoding="utf-8", errors="ignore")
    original = content

    canonical_match = CANON_RE.search(content)
    page_url = normalized_page_url(base_url, root, path)

    if canonical_match is None:
        head_close = HEAD_CLOSE_RE.search(content)
        if head_close:
            insertion = "  " + make_canonical_tag(page_url) + "\n"
            content = content[: head_close.start()] + insertion + content[head_close.start() :]
            actions.append(f"add canonical -> {page_url}")
        else:
            actions.append("skip add canonical (missing </head>)")
    else:
        current_href = canonical_match.group(1).strip()
        if not current_href.lower().startswith(("http://", "https://")):
            fixed = urljoin(base_url.rstrip("/") + "/", current_href.lstrip("/"))
            replacement = canonical_match.group(0).replace(current_href, fixed)
            content = content[: canonical_match.start()] + replacement + content[canonical_match.end() :]
            actions.append(f"canonical relative->absolute ({current_href} -> {fixed})")

    if content != original and not dry_run:
        path.write_text(content, encoding="utf-8", newline="\n")

    return actions


def scan_repo(root: Path, base_url: str, apply: bool) -> ScanResult:
    html_files = iter_html_files(root)
    file_issues: List[FileIssue] = []

    for file_path in html_files:
        file_issues.append(analyze_file(file_path))

    duplicate_titles = find_duplicates([(f.title, f.path) for f in file_issues])
    duplicate_descriptions = find_duplicates([(f.description, f.path) for f in file_issues])

    planned_fixes: List[FixChange] = []
    for issue in file_issues:
        if not (issue.missing_canonical or issue.non_absolute_canonical):
            continue
        path_obj = Path(issue.path)
        actions = apply_fix_to_file(path_obj, base_url, root, dry_run=not apply)
        if actions:
            planned_fixes.append(FixChange(path=issue.path, actions=actions))

    summary = ScanSummary(
        files_scanned=len(list(root.rglob("*"))),
        html_files=len(html_files),
        missing_canonical=sum(1 for x in file_issues if x.missing_canonical),
        non_absolute_canonical=sum(1 for x in file_issues if x.non_absolute_canonical),
        duplicate_titles=len(duplicate_titles),
        duplicate_descriptions=len(duplicate_descriptions),
    )

    return ScanResult(
        summary=summary,
        files=file_issues,
        duplicate_title_clusters=duplicate_titles,
        duplicate_description_clusters=duplicate_descriptions,
        planned_fixes=planned_fixes,
    )


def print_human_report(result: ScanResult, apply: bool) -> None:
    mode = "APPLY" if apply else "DRY RUN"
    print(f"Repo Issue Scanner/Fixer ({mode})")
    print("=" * 40)
    print(f"HTML files: {result.summary.html_files}")
    print(f"Missing canonical: {result.summary.missing_canonical}")
    print(f"Non-absolute canonical: {result.summary.non_absolute_canonical}")
    print(f"Duplicate title clusters: {result.summary.duplicate_titles}")
    print(f"Duplicate description clusters: {result.summary.duplicate_descriptions}")
    print()

    if result.planned_fixes:
        print("Planned/Applied canonical fixes:")
        for change in result.planned_fixes:
            print(f"- {change.path}")
            for action in change.actions:
                print(f"  - {action}")
    else:
        print("No automatic canonical fixes needed.")


def main() -> int:
    parser = argparse.ArgumentParser(description="Scan and safely fix common SEO metadata issues in repos.")
    parser.add_argument("--repo", default=".", help="Repository path to scan.")
    parser.add_argument("--base-url", required=True, help="Base site URL used to build absolute canonical URLs.")
    parser.add_argument("--apply", action="store_true", help="Write fixes to files. Default is dry-run scan only.")
    parser.add_argument("--output-json", default="", help="Optional path to write detailed JSON output.")
    args = parser.parse_args()

    root = Path(args.repo).resolve()
    if not root.exists() or not root.is_dir():
        print(f"Invalid --repo path: {root}")
        return 2

    result = scan_repo(root=root, base_url=args.base_url, apply=args.apply)
    print_human_report(result, apply=args.apply)

    if args.output_json:
        out_path = Path(args.output_json).resolve()
        out_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "summary": asdict(result.summary),
            "files": [asdict(x) for x in result.files],
            "duplicate_title_clusters": result.duplicate_title_clusters,
            "duplicate_description_clusters": result.duplicate_description_clusters,
            "planned_fixes": [asdict(x) for x in result.planned_fixes],
        }
        out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"\nJSON report written: {out_path}")

    if not args.apply:
        print("\nDry-run mode: no file changes were written. Add --apply to write safe canonical fixes.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
