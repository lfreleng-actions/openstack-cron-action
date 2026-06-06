# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
"""Summarise a zizmor SARIF report for the GitHub Actions step summary.

Default mode (no arguments): read the SARIF file at ``$ZIZMOR_SARIF``
and write a human-readable markdown summary to ``$GITHUB_STEP_SUMMARY``.
Also emit a compact listing to stdout and
``::warning``/``::error``/``::notice`` workflow commands for the top
findings so they surface as inline PR annotations.

Helper mode (``--regen-workflow``): regenerate the base64-encoded copy
of this script that lives in ``.github/workflows/zizmor.yaml`` under
``env.ZIZMOR_SUMMARY_B64``. The workflow file embeds the parser as
base64 because it is invoked as a required workflow against repos that
do not contain this script. After editing this file, run::

    python3 .github/scripts/zizmor_summary.py --regen-workflow

then commit both files together.
"""
import argparse
import base64
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path
from posixpath import basename
from urllib.parse import quote

# Marker used by --regen-workflow to locate the embedded base64 block.
_B64_MARKER = "ZIZMOR_SUMMARY_B64: |"
_B64_INDENT = " " * 12

LEVEL_LABEL = {
    "error": "\u26d4 High",
    "warning": "\u26a0\ufe0f Medium",
    "note": "\U0001f4dd Low",
    "none": "\u2139\ufe0f Info",
}
LEVEL_ORDER = ["error", "warning", "note", "none"]
WARN_CMD = {
    "error": "error", "warning": "warning",
    "note": "notice", "none": "notice",
}


def strip_rule_prefix(rid: str) -> str:
    """Drop the ``zizmor/`` prefix from a rule id for tighter tables."""
    if rid.startswith("zizmor/"):
        return rid[len("zizmor/"):]
    return rid


def _escape_wf_data(value: object) -> str:
    """Escape the message body of a GitHub workflow command.

    Per GitHub's workflow-command rules, ``%``, ``CR`` and ``LF`` must
    be percent-encoded in the data (post-``::``) portion.
    """
    return (
        str(value)
        .replace("%", "%25")
        .replace("\r", "%0D")
        .replace("\n", "%0A")
    )


def _escape_wf_property(value: object) -> str:
    """Escape a property value of a GitHub workflow command.

    Properties live in the comma-separated ``key=value`` list before
    ``::``. In addition to the data-escapes, ``,`` and ``:`` must be
    encoded so they cannot terminate the property list or the command
    prefix.
    """
    return (
        _escape_wf_data(value)
        .replace(":", "%3A")
        .replace(",", "%2C")
    )


def _render_link(file: str, line, repo: str, sha: str, server: str) -> str:
    """Render a path:line link with the basename as visible text."""
    if not file:
        return ""
    short = basename(file) or file
    label = short + (f":{line}" if line else "")
    if not repo or not sha:
        return f"`{label}`"
    anchor = f"#L{line}" if line else ""
    url = f"{server}/{repo}/blob/{sha}/{quote(file)}{anchor}"
    return f"[`{label}`]({url})"


def _load_findings(sarif_path: Path):
    """Parse SARIF and return (findings, level_counts, rule_counts)."""
    with sarif_path.open() as fh:
        data = json.load(fh)

    findings = []
    rule_meta = {}
    for run in data.get("runs", []):
        tool = run.get("tool", {}).get("driver", {})
        for rule in tool.get("rules", []):
            rule_meta[rule.get("id", "")] = rule
        for result in run.get("results", []):
            rid = result.get("ruleId", "?")
            level = (
                result.get("level")
                or rule_meta.get(rid, {})
                    .get("defaultConfiguration", {})
                    .get("level", "warning")
            )
            msg = (result.get("message") or {}).get("text", "").strip()
            loc = (result.get("locations") or [{}])[0]
            ploc = loc.get("physicalLocation", {})
            artifact = ploc.get("artifactLocation", {}).get("uri", "")
            region = ploc.get("region", {}) or {}
            line = region.get("startLine")
            endline = region.get("endLine") or line
            findings.append({
                "rule": rid,
                "level": level,
                "msg": msg,
                "file": artifact,
                "line": line,
                "endline": endline,
            })

    def sort_key(f):
        try:
            idx = LEVEL_ORDER.index(f["level"])
        except ValueError:
            idx = 99
        return (idx, f["rule"], f["file"], f["line"] or 0)

    findings.sort(key=sort_key)
    level_counts = Counter(f["level"] for f in findings)
    rule_counts = Counter(f["rule"] for f in findings)
    return findings, level_counts, rule_counts


def summarise() -> int:
    """Read SARIF and write summary; return process exit code."""
    sarif_path = Path(os.environ["ZIZMOR_SARIF"])
    top_n = int(os.environ.get("ZIZMOR_TOP_N", "10"))
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    sha = os.environ.get("GITHUB_SHA", "")
    persona = os.environ.get("ZIZMOR_PERSONA", "regular")
    min_severity = os.environ.get("ZIZMOR_MIN_SEVERITY", "medium")

    findings, level_counts, rule_counts = _load_findings(sarif_path)
    total = sum(level_counts.values())
    short_sha = sha[:7] if sha else "?"

    out = ["# \U0001f308 Zizmor Scan", ""]
    if total == 0:
        out.append(f"No findings at or above `{min_severity}` \u2705")
    else:
        out.append(
            f"{total} finding(s) at or above `{min_severity}` \u26a0\ufe0f"
        )
    out.extend([
        "",
        f"`{repo}@{short_sha}`",
        f"persona: `{persona}`",
        f"min-severity: `{min_severity}`",
        "",
    ])

    if total > 0:
        out.append("## Counts by severity")
        out.append("")
        out.append("| Severity | Count |")
        out.append("| --- | ---: |")
        for lvl in LEVEL_ORDER:
            if lvl in level_counts:
                out.append(
                    f"| {LEVEL_LABEL.get(lvl, lvl)} | {level_counts[lvl]} |"
                )
        out.append("")
        out.append("## Counts by rule")
        out.append("")
        out.append("| Rule | Count |")
        out.append("| --- | ---: |")
        for rid, n in rule_counts.most_common():
            out.append(f"| `{strip_rule_prefix(rid)}` | {n} |")
        out.append("")
        shown = findings[:top_n]
        extra = total - len(shown)
        heading = f"## Top {len(shown)} findings"
        if extra > 0:
            heading += f" (of {total}; {extra} more in SARIF)"
        out.append(heading)
        out.append("")
        out.append("| Severity | Rule | Location | Message |")
        out.append("| --- | --- | --- | --- |")
        for f in shown:
            label = LEVEL_LABEL.get(f["level"], f["level"])
            msg = f["msg"].replace("|", "\\|").replace("\n", " ")
            if len(msg) > 200:
                msg = msg[:197] + "..."
            rule_short = strip_rule_prefix(f["rule"])
            loc = _render_link(f["file"], f["line"], repo, sha, server)
            out.append(
                f"| {label} | `{rule_short}` | {loc} | {msg} |"
            )

    summary = "\n".join(out) + "\n"
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as fh:
            fh.write(summary)

    print("::group::zizmor summary")
    by_level = {LEVEL_LABEL.get(k, k): v for k, v in level_counts.items()}
    print(
        f"Total: {total}  by-level: {by_level}  rules: {len(rule_counts)}"
    )
    for f in findings[:top_n]:
        label = LEVEL_LABEL.get(f["level"], f["level"])
        loc_str = f["file"] + (f":{f['line']}" if f["line"] else "")
        rule_short = strip_rule_prefix(f["rule"])
        print(f"  {label}  {rule_short:<28}  {loc_str}")
    print("::endgroup::")

    # Workflow commands keep the full rule id in the title since
    # GitHub shows them out of context (e.g. in PR file annotations).
    # Property values are escaped per GitHub's workflow-command rules
    # so ``,`` and ``:`` in titles or paths cannot break the format.
    for f in findings[:top_n]:
        cmd = WARN_CMD.get(f["level"], "warning")
        parts = []
        if f["file"]:
            parts.append(f"file={_escape_wf_property(f['file'])}")
        if f["line"]:
            parts.append(f"line={f['line']}")
        if f["endline"] and f["endline"] != f["line"]:
            parts.append(f"endLine={f['endline']}")
        title = f"zizmor: {f['rule']}"
        parts.append(f"title={_escape_wf_property(title)}")
        msg = f["msg"].replace("\n", " ").strip() or f["rule"]
        print(f"::{cmd} {','.join(parts)}::{_escape_wf_data(msg)}")

    return 0


def regen_workflow(
    workflow_path: Path | None = None,
    script_path: Path | None = None,
) -> int:
    """Replace the embedded base64 block in the workflow file in place.

    Returns 0 if the workflow already matched (no write needed) or was
    rewritten, and a non-zero code on hard errors (missing files,
    missing marker block).
    """
    here = Path(__file__).resolve()
    repo_root = here.parent.parent.parent
    if script_path is None:
        script_path = here
    if workflow_path is None:
        workflow_path = repo_root / ".github" / "workflows" / "zizmor.yaml"

    if not script_path.is_file():
        print(f"error: script not found: {script_path}", file=sys.stderr)
        return 2
    if not workflow_path.is_file():
        print(
            f"error: workflow not found: {workflow_path}", file=sys.stderr
        )
        return 2

    source = script_path.read_bytes()
    b64 = base64.b64encode(source).decode("ascii")
    chunks = [b64[i:i + 76] for i in range(0, len(b64), 76)]
    block = "\n".join(_B64_INDENT + c for c in chunks) + "\n"

    workflow = workflow_path.read_text()
    pattern = re.compile(
        re.escape(_B64_MARKER)
        + r"\n(?:"
        + re.escape(_B64_INDENT)
        + r"[A-Za-z0-9+/=]+\n)+",
        re.MULTILINE,
    )
    m = pattern.search(workflow)
    if m is None:
        print(
            "error: could not find ZIZMOR_SUMMARY_B64 block in "
            f"{workflow_path}",
            file=sys.stderr,
        )
        return 2

    replacement = _B64_MARKER + "\n" + block
    new_workflow = workflow[: m.start()] + replacement + workflow[m.end():]
    if new_workflow == workflow:
        print(f"unchanged: {workflow_path}")
        return 0
    workflow_path.write_text(new_workflow)
    print(
        f"rewrote {workflow_path} "
        f"(embedded {len(source)} bytes, base64 {len(b64)} chars)"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Summarise a zizmor SARIF report. With no arguments, read "
            "$ZIZMOR_SARIF and write a markdown summary to "
            "$GITHUB_STEP_SUMMARY. With --regen-workflow, refresh the "
            "base64-encoded copy of this script embedded in "
            ".github/workflows/zizmor.yaml."
        )
    )
    parser.add_argument(
        "--regen-workflow",
        action="store_true",
        help=(
            "regenerate the embedded base64 in "
            ".github/workflows/zizmor.yaml from this script and exit"
        ),
    )
    args = parser.parse_args(argv)
    if args.regen_workflow:
        return regen_workflow()
    return summarise()


if __name__ == "__main__":
    sys.exit(main())
