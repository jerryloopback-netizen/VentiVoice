"""LLM 后处理模块

三档润色 + 个人语料库注入。
支持多 provider 切换 (OpenAI 兼容接口)。
"""

from __future__ import annotations

from pathlib import Path
from typing import Literal

import httpx

from corpus import Corpus


Tier = Literal[1, 2, 3]
TIER_PROMPT_FILES = {
    1: "tier1_clean.txt",
    2: "tier2_refine.txt",
    3: "tier3_rewrite.txt",
}


class LLMProcessor:
    def __init__(self, config: dict, provider_name: str = None, corpus: Corpus = None):
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
        self._corpus = corpus

        prompts_dir = Path(__file__).parent.parent / "prompts"
        self._prompts: dict[int, str] = {}
        for tier, filename in TIER_PROMPT_FILES.items():
            self._prompts[tier] = (prompts_dir / filename).read_text(encoding="utf-8")

    def process(self, raw_text: str, tier: Tier) -> str:
        corpus_injection = self._corpus.build_injection() if self._corpus else ""
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

    def discover_terms(self, text: str) -> list[str]:
        """第三层：从转写结果中提取值得加入词库的专有名词，返回0-2个词"""
        existing_terms = set()
        if self._corpus:
            for entry in self._corpus._data.get("corrections", []):
                existing_terms.add(entry["correct"])

        existing_list = ", ".join(sorted(existing_terms)[:50]) if existing_terms else "（空）"

        prompt = (
            "你是一个词库管理助手。分析下面的转写文本，提取其中出现的【专业领域词汇】。\n\n"
            "值得加入词库的词包括：\n"
            "- 游戏角色名、道具名、技能名\n"
            "- 学术术语、学科专有名词\n"
            "- 技术名词、编程术语、框架名\n"
            "- 英文缩写（如 API、GPU、LSTM）\n"
            "- 人名、地名、品牌名等特殊名词\n"
            "- 音乐、电子、体育等领域的专有名词\n\n"
            "绝对不要加入的词：\n"
            "- 日常用词：内容、总结、输出、分析、结果、处理、方法、问题、情况、进行、"
            "完成、实现、使用、操作、选择、功能、系统、模式、数据、信息\n"
            "- 常见动词和名词\n"
            "- 已存在于词库中的词\n\n"
            f"当前词库已有: {existing_list}\n\n"
            "规则：\n"
            "- 最多输出 2 个词，大部分文本可能不包含值得收录的词，此时输出 0 个\n"
            "- 要非常谨慎，只有确实是专业/特殊领域的词才收录\n"
            "- 每个词单独一行，不要编号、不要解释、不要其他任何文字\n"
            "- 如果没有值得收录的词，只输出一个字: 无\n\n"
            f"转写文本：\n{text}"
        )

        try:
            response = httpx.post(
                f"{self.base_url}/chat/completions",
                headers={
                    "Authorization": f"Bearer {self.api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": self.model,
                    "messages": [{"role": "user", "content": prompt}],
                    "max_tokens": 64,
                    "temperature": 0.1,
                },
                timeout=30.0,
            )
            response.raise_for_status()
            raw = response.json()["choices"][0]["message"]["content"].strip()

            if raw == "无" or not raw:
                return []

            terms = [line.strip() for line in raw.splitlines() if line.strip()]
            terms = [t for t in terms if t != "无" and t not in existing_terms]
            return terms[:2]
        except Exception:
            return []
