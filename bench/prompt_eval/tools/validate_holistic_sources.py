#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import re
from typing import Any
from urllib.parse import urlparse


URL_RE = re.compile(r"https?://[^\s)]+")

PROVIDER_DOMAIN_MAP = {
    "openai": {"platform.openai.com", "developers.openai.com", "openai.com"},
    "anthropic": {"docs.anthropic.com", "anthropic.com", "www.anthropic.com"},
    "google": {"ai.google.dev", "cloud.google.com", "docs.cloud.google.com", "developers.google.com"},
    "promptfoo": {"promptfoo.dev", "www.promptfoo.dev"},
}
NON_PROVIDER_RESEARCH_DOMAINS = {"aclanthology.org", "arxiv.org"}


def normalize_host(url: str) -> str:
    host = (urlparse(url).hostname or "").lower().strip()
    if host.startswith("www."):
        host = host[4:]
    return host


def parse_urls(markdown_text: str) -> list[str]:
    found = [m.group(0).rstrip(".,;") for m in URL_RE.finditer(markdown_text)]
    # preserve order but dedupe
    return list(dict.fromkeys(found))


def provider_coverage(urls: list[str]) -> dict[str, list[str]]:
    hits: dict[str, list[str]] = {k: [] for k in PROVIDER_DOMAIN_MAP}
    for url in urls:
        host = normalize_host(url)
        for provider, domains in PROVIDER_DOMAIN_MAP.items():
            if host in domains:
                hits[provider].append(url)
    return hits


def recent_non_provider_count(urls: list[str], min_date: dt.date) -> tuple[int, int]:
    min_year = min_date.year
    count = 0
    borderline_acl_year_only = 0
    for url in urls:
        host = normalize_host(url)
        if host not in NON_PROVIDER_RESEARCH_DOMAINS:
            continue
        if host == "aclanthology.org":
            match = re.search(r"/(20\d{2})[./-]", url)
            if match:
                year = int(match.group(1))
                if year > min_year:
                    count += 1
                elif year == min_year:
                    # ACL URLs are often year-only (no month/day in URL). Treat as borderline
                    # rather than guaranteed recent against a month-level cutoff.
                    borderline_acl_year_only += 1
        elif host == "arxiv.org":
            # arXiv YYMM identifier for modern submissions, e.g. 2512.12345
            match = re.search(r"/abs/(\d{2})(\d{2})\.\d+", url)
            if match:
                year = 2000 + int(match.group(1))
                month = int(match.group(2))
                try:
                    submitted = dt.date(year, month, 1)
                except ValueError:
                    continue
                if submitted >= dt.date(min_date.year, min_date.month, 1):
                    count += 1
    return count, borderline_acl_year_only


def validate(manifest: dict[str, Any], doc_path: pathlib.Path) -> dict[str, Any]:
    source_policy = manifest.get("source_policy") or {}
    required_providers = source_policy.get("required_provider_coverage") or []
    min_total_sources = int(source_policy.get("minimum_total_sources") or 0)
    min_recent_non_provider = int(source_policy.get("minimum_recent_non_provider_sources") or 0)
    min_recent_source_date = dt.date.fromisoformat(source_policy.get("minimum_recent_source_date"))

    text = doc_path.read_text(encoding="utf-8")
    urls = parse_urls(text)
    coverage = provider_coverage(urls)
    missing_providers = [p for p in required_providers if not coverage.get(p)]
    recent_non_provider, borderline_acl_year_only = recent_non_provider_count(urls, min_recent_source_date)

    errors: list[str] = []
    if len(urls) < min_total_sources:
        errors.append(
            f"source count below minimum: found={len(urls)} required>={min_total_sources}"
        )
    if missing_providers:
        errors.append("missing provider coverage: " + ", ".join(missing_providers))
    if recent_non_provider < min_recent_non_provider:
        errors.append(
            "recent non-provider sources below minimum: "
            f"found={recent_non_provider} required>={min_recent_non_provider}"
        )

    return {
        "ok": not errors,
        "doc_path": str(doc_path),
        "source_count": len(urls),
        "required_provider_coverage": required_providers,
        "provider_hits": {k: len(v) for k, v in coverage.items()},
        "recent_non_provider_sources": recent_non_provider,
        "borderline_acl_year_only_sources": borderline_acl_year_only,
        "minimum_recent_source_date": min_recent_source_date.isoformat(),
        "errors": errors,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Validate holistic source coverage policy.")
    ap.add_argument("--manifest", default="bench/prompt_eval/config/gate_manifest.v1.json")
    ap.add_argument("--doc", default="")
    args = ap.parse_args()

    manifest_path = pathlib.Path(args.manifest).resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    source_policy = manifest.get("source_policy") or {}
    artifact_rel = args.doc.strip() or source_policy.get("research_artifact_path", "")
    if not artifact_rel:
        print(json.dumps({
            "ok": False,
            "manifest": str(manifest_path),
            "errors": ["missing source_policy.research_artifact_path and --doc override"],
        }, indent=2, ensure_ascii=False))
        return 2

    repo_root = pathlib.Path(__file__).resolve().parents[3]
    doc_path = pathlib.Path(artifact_rel)
    if not doc_path.is_absolute():
        doc_path = (repo_root / doc_path).resolve()

    if not doc_path.exists():
        print(json.dumps({
            "ok": False,
            "manifest": str(manifest_path),
            "doc_path": str(doc_path),
            "errors": [f"research artifact missing: {doc_path}"],
        }, indent=2, ensure_ascii=False))
        return 2

    try:
        out = validate(manifest, doc_path)
    except Exception as exc:
        print(json.dumps({
            "ok": False,
            "manifest": str(manifest_path),
            "doc_path": str(doc_path),
            "errors": [f"validation_exception: {exc}"],
        }, indent=2, ensure_ascii=False))
        return 2

    out["manifest"] = str(manifest_path)
    print(json.dumps(out, indent=2, ensure_ascii=False))
    return 0 if out["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
