"""LLM 后处理模块

三档润色 + 个人语料库注入。
支持多 provider 切换 (OpenAI 兼容接口)。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Literal

import httpx


Tier = Literal[1, 2, 3]
TIER_PROMPT_FILES = {
    1: "tier1_clean.txt",
    2: "tier2_refine.txt",
    3: "tier3_rewrite.txt",
}


class LLMProcessor:
    def __init__(self, config: dict, provider_name: str = None):
        llm_cfg = config["llm"]

        if provider_name is None:
            provider_name = llm_cfg.get("default_provider", "")

        providers = llm_cfg.get("providers", {})
        if provider_name in providers:
            p = providers[provider_name]
            self.base_url = p["base_url"].rstrip("/")
            self.api_key = p.get("api_key", "")
            self.model = p["model"]
            self.max_tokens = p.get("max_tokens", 2048)
            self.temperature = p.get("temperature", 0.3)
        else:
            self.base_url = llm_cfg.get("base_url", "").rstrip("/")
            self.api_key = llm_cfg.get("api_key", "")
            self.model = llm_cfg.get("model", "")
            self.max_tokens = llm_cfg.get("max_tokens", 2048)
            self.temperature = llm_cfg.get("temperature", 0.3)

        self.provider_name = provider_name

        prompts_dir = Path(__file__).parent.parent / "prompts"
        self._prompts: dict[int, str] = {}
        for tier, filename in TIER_PROMPT_FILES.items():
            self._prompts[tier] = (prompts_dir / filename).read_text(encoding="utf-8")

        corpus_path = Path(__file__).parent.parent / config["corpus"]["path"]
        self._corpus_path = corpus_path

    def process(self, raw_text: str, tier: Tier) -> str:
        corpus_injection = self._build_corpus_injection()
        prompt_template = self._prompts[tier]
        prompt = prompt_template.replace("{raw_text}", raw_text).replace(
            "{corpus_injection}", corpus_injection
        )

        response = httpx.post(
            f"{self.base_url}/chat/completions",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": self.model,
                "messages": [{"role": "user", "content": prompt}],
                "max_tokens": self.max_tokens,
                "temperature": self.temperature,
            },
            timeout=120.0,
        )
        response.raise_for_status()
        return response.json()["choices"][0]["message"]["content"].strip()

    def _build_corpus_injection(self) -> str:
        if not self._corpus_path.exists():
            return ""

        corpus = json.loads(self._corpus_path.read_text(encoding="utf-8"))
        corrections = corpus.get("corrections", [])
        domain_terms = corpus.get("domain_terms", [])

        if not corrections and not domain_terms:
            return ""

        lines = ["【个人语料库 - 请据此修正转写内容】"]
        if corrections:
            lines.append("已知识别错误:")
            for c in corrections:
                lines.append(f'  "{c["wrong"]}" → "{c["correct"]}"')
        if domain_terms:
            lines.append(f"领域术语: {', '.join(domain_terms)}")

        return "\n".join(lines) + "\n"
