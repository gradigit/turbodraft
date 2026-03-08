#!/usr/bin/env python3
from __future__ import annotations

import json
import pathlib
from typing import Any

DEFAULT_PROVIDER_CONTRACT = "bench/prompt_eval/config/providers.v1.json"

_REQUIRED_PROVIDER_ROLES = ("drafting", "judge_primary", "judge_shadow")
_REQUIRED_PROVIDER_FIELDS = ("runner", "model", "reasoning_effort")


class ProviderContractError(RuntimeError):
    pass


def _assert_str(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ProviderContractError(f"provider contract field '{field}' must be a non-empty string")
    return value.strip()


def load_provider_contract(repo: pathlib.Path, contract_path: str = DEFAULT_PROVIDER_CONTRACT) -> dict[str, Any]:
    path = (repo / contract_path).resolve()
    if not path.exists():
        raise ProviderContractError(f"provider contract missing: {path}")

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ProviderContractError(f"provider contract JSON parse failed: {path}: {exc}") from exc

    if not isinstance(data, dict):
        raise ProviderContractError("provider contract root must be an object")
    version = _assert_str(data.get("version"), "version")
    if version != "v1":
        raise ProviderContractError(f"provider contract version must be 'v1' (got {version!r})")

    providers = data.get("providers")
    if not isinstance(providers, dict):
        raise ProviderContractError("provider contract 'providers' must be an object")

    normalized: dict[str, dict[str, str]] = {}
    for role, item in providers.items():
        if not isinstance(role, str) or not role.strip():
            raise ProviderContractError("provider contract role keys must be non-empty strings")
        if not isinstance(item, dict):
            raise ProviderContractError(f"provider contract role must be object: {role}")
        normalized_item: dict[str, str] = {}
        for field in _REQUIRED_PROVIDER_FIELDS:
            normalized_item[field] = _assert_str(item.get(field), f"providers.{role}.{field}").lower()
        # Preserve exact model IDs (case-sensitive) while normalizing runner/reasoning effort.
        normalized_item["model"] = _assert_str(item.get("model"), f"providers.{role}.model")
        normalized[role] = normalized_item

    for role in _REQUIRED_PROVIDER_ROLES:
        if role not in normalized:
            raise ProviderContractError(f"provider contract missing role: {role}")

    return {
        "path": str(path),
        "version": version,
        "providers": normalized,
    }


__all__ = [
    "DEFAULT_PROVIDER_CONTRACT",
    "ProviderContractError",
    "load_provider_contract",
]
