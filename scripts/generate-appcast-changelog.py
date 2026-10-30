#!/usr/bin/env python3
"""Generate release notes from git commits (subject + body → list items).

Used by:
  - scripts/bump-version-patch.sh
  - scripts/githooks/pre-commit
  - .github/workflows/release.yml

Usage:
  python3 scripts/generate-appcast-changelog.py [--since TAG] [--format html|markdown] [--limit N]
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from html import escape
from pathlib import Path
from typing import Iterable, List, Optional, Tuple

# 手写更新日志目录：Docs/release-notes/<version>.md
# 手写稿优先于 commit 抓取（分组清晰、面向用户可读），CI 与本地 bump 都走这里。
DEFAULT_RELEASE_NOTES_DIR = Path(__file__).resolve().parents[1] / "Docs" / "release-notes"


# Version-bump / meta commits that shouldn't appear in user-facing notes.
SKIP_SUBJECT_RE = re.compile(
    r"^(?:"
    r"(?:feat|chore)\s*:\s*更新版本至\b"
    r"|chore\s*:\s*bump version\b"
    r"|chore\s*:\s*update appcast\b"
    r"|githooks?\s*:"
    r")",
    re.IGNORECASE,
)

# Trailers / noise in commit bodies.
SKIP_BODY_LINE_RE = re.compile(
    r"^(?:"
    r"co-authored-by:"
    r"|signed-off-by:"
    r"|made-with:"
    r"|change-id:"
    r"|reviewed-by:"
    r"|#\s*----+"
    r"|---+$"
    r")",
    re.IGNORECASE,
)

# Leading list / section markers in body lines.
BODY_MARKER_RE = re.compile(
    r"^\s*(?:"
    r"[-*•]\s+"
    r"|\d+[\.、)]\s+"
    r"|[①-⑳]\s*"
    r"|⚙️\s*"
    r")+"
)


def run_git(args: List[str]) -> str:
    result = subprocess.run(
        ["git", *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return ""
    return result.stdout


def resolve_since(explicit: Optional[str]) -> str:
    if explicit:
        return explicit
    # Prefer parent of HEAD so the range is previous-tag..HEAD (matches CI).
    tag = run_git(["describe", "--tags", "--abbrev=0", "HEAD^"]).strip()
    if tag:
        return tag
    return run_git(["describe", "--tags", "--abbrev=0", "HEAD"]).strip()


def fetch_commits(since: str, limit: int) -> List[Tuple[str, str, str]]:
    """Return list of (short_hash, subject, body)."""
    range_spec = f"{since}..HEAD" if since else "HEAD"
    # Record separator = \x1e, field separator = \x1f
    pretty = "%h%x1f%s%x1f%b%x1e"
    raw = run_git(
        [
            "log",
            range_spec,
            f"--pretty=format:{pretty}",
            "--no-merges",
            f"-n{limit}",
        ]
    )
    commits: List[Tuple[str, str, str]] = []
    for record in raw.split("\x1e"):
        record = record.strip("\n")
        if not record.strip():
            continue
        parts = record.split("\x1f", 2)
        if len(parts) < 2:
            continue
        short = parts[0].strip()
        subject = parts[1].strip()
        body = parts[2] if len(parts) > 2 else ""
        commits.append((short, subject, body))
    return commits


def body_lines(body: str) -> List[str]:
    lines: List[str] = []
    for raw in body.splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        if SKIP_BODY_LINE_RE.match(line.strip()):
            continue
        cleaned = BODY_MARKER_RE.sub("", line).strip()
        if not cleaned:
            continue
        # Drop ultra-short decorative lines
        if cleaned in {"⚙️", "•", "-", "*"}:
            continue
        lines.append(cleaned)
    return lines


def should_skip_subject(subject: str) -> bool:
    return bool(SKIP_SUBJECT_RE.match(subject.strip()))


def collect_entries(commits: Iterable[Tuple[str, str, str]]) -> List[Tuple[str, List[str]]]:
    """Each entry: (title, detail_lines). Title already includes hash suffix when useful."""
    entries: List[Tuple[str, List[str]]] = []
    for short, subject, body in commits:
        if not subject or should_skip_subject(subject):
            continue
        details = body_lines(body)
        # Keep hash only on the title row for traceability
        title = f"{subject} ({short})" if short else subject
        entries.append((title, details))
    return entries


def to_markdown(entries: List[Tuple[str, List[str]]]) -> str:
    if not entries:
        return "- Initial release"
    out: List[str] = []
    for title, details in entries:
        out.append(f"- {title}")
        for d in details:
            out.append(f"  - {d}")
    return "\n".join(out)


def to_html(entries: List[Tuple[str, List[str]]], version: Optional[str] = None) -> str:
    if not entries:
        body = "<p>Initial release</p>"
    else:
        items: List[str] = []
        for title, details in entries:
            title_html = escape(title)
            if details:
                nested = "".join(f"<li>{escape(d)}</li>" for d in details)
                items.append(
                    f"<li><strong>{title_html}</strong><ul>{nested}</ul></li>"
                )
            else:
                items.append(f"<li>{title_html}</li>")
        body = f"<ul>{''.join(items)}</ul>"

    if version:
        return f"<h3>WaifuX {escape(version)}</h3>{body}"
    return body


def load_handwritten_notes(version: str, notes_dir: Path) -> Optional[str]:
    """返回 VERSION 的手写更新日志正文；没有就用 None 让调用方回退 commit 抓取。"""
    if not version:
        return None
    candidate = notes_dir / f"{version.strip()}.md"
    if not candidate.is_file():
        return None
    text = candidate.read_text(encoding="utf-8").strip()
    return text or None


def notes_to_markdown(notes: str) -> str:
    """手写稿 → markdown 输出：去掉顶部的 `# 标题`（Release 正文自带「更新内容」）。"""
    body = "\n".join(line for line in notes.splitlines() if not line.lstrip().startswith("# "))
    return body.strip()


def notes_to_html(notes: str, version: Optional[str] = None) -> str:
    """把手写 markdown 更新日志渲染成 appcast 用的 HTML。

    `## 新增功能` → <h4>，`- ✨ feat(...): …` → <li>；开头的 `# 标题` 丢弃，
    因为外层已经输出 <h3>WaifuX VERSION</h3>。generate-appcast.py 复用本函数，
    避免两处渲染逻辑漂移。
    """
    chunks: List[str] = []
    list_open = False
    for raw in notes.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("## "):
            if list_open:
                chunks.append("</ul>")
                list_open = False
            chunks.append(f"<h4>{escape(line[3:].strip())}</h4>")
            continue
        if line.startswith("# "):
            continue
        if line.startswith("- "):
            if not list_open:
                chunks.append("<ul>")
                list_open = True
            chunks.append(f"<li>{escape(line[2:].strip())}</li>")
    if list_open:
        chunks.append("</ul>")

    if not chunks:
        return f"<p>WaifuX {escape(version)}</p>" if version else "<p>Initial release</p>"

    body = "".join(chunks)
    if version:
        return f"<h3>WaifuX {escape(version)}</h3>{body}"
    return body


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--since", default="", help="Git ref for lower bound (exclusive)")
    parser.add_argument(
        "--format",
        choices=("html", "markdown", "md"),
        default="markdown",
        help="Output format",
    )
    parser.add_argument("--limit", type=int, default=30, help="Max commits to include")
    parser.add_argument(
        "--version",
        default="",
        help="When format=html, wrap with <h3>WaifuX VERSION</h3>",
    )
    parser.add_argument(
        "--items-only",
        action="store_true",
        help="With format=html, emit only <li>…</li> rows (no outer ul/h3)",
    )
    parser.add_argument(
        "--release-notes-dir",
        type=Path,
        default=DEFAULT_RELEASE_NOTES_DIR,
        help="手写更新日志目录（默认 Docs/release-notes）",
    )
    args = parser.parse_args()

    fmt = "markdown" if args.format == "md" else args.format

    # 手写稿优先：存在 Docs/release-notes/<version>.md 就直接输出它。
    handwritten = load_handwritten_notes(args.version, args.release_notes_dir)
    if handwritten is not None:
        print(
            f"using hand-written notes: {args.release_notes_dir / (args.version.strip() + '.md')}",
            file=sys.stderr,
        )
        sys.stdout.write(
            notes_to_markdown(handwritten)
            if fmt == "markdown"
            else notes_to_html(handwritten, args.version or None)
        )
        if sys.stdout.isatty():
            sys.stdout.write("\n")
        return 0

    since = resolve_since(args.since or None)
    commits = fetch_commits(since, args.limit)
    entries = collect_entries(commits)

    if fmt == "markdown":
        sys.stdout.write(to_markdown(entries))
    else:
        if args.items_only:
            # Flat <li> stream for callers that already wrap <ul>
            chunks: List[str] = []
            for title, details in entries:
                title_html = escape(title)
                if details:
                    nested = "".join(f"<li>{escape(d)}</li>" for d in details)
                    chunks.append(
                        f"<li><strong>{title_html}</strong><ul>{nested}</ul></li>"
                    )
                else:
                    chunks.append(f"<li>{title_html}</li>")
            if not chunks:
                chunks.append("<li>Initial release</li>")
            sys.stdout.write("\n".join(chunks))
        else:
            sys.stdout.write(to_html(entries, args.version or None))
    if sys.stdout.isatty():
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
