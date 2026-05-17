"""个人语料库管理

数据结构以「正确词」为主键，每个词条包含：
- correct: 正确词
- wrong_variants: 用户提交过的各种错误识别变体
- count: 综合热度（纠错提交 + LLM 输出命中）
"""

from __future__ import annotations

import json
from pathlib import Path


class Corpus:
    def __init__(self, path: str, enabled: bool = True):
        self._path = Path(path)
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self.enabled = enabled
        if not self._path.exists():
            self._save({"corrections": [], "domain_terms": []})
        self._data = json.loads(self._path.read_text(encoding="utf-8"))
        self._migrate_if_needed()

        self._blacklist_path = self._path.parent / "blacklist.json"
        if not self._blacklist_path.exists():
            self._save_blacklist([])
        self._blacklist: list[str] = json.loads(
            self._blacklist_path.read_text(encoding="utf-8")
        )

    def _migrate_if_needed(self):
        """从旧格式迁移：旧格式每条是 {wrong, correct, count}，新格式以 correct 为主键"""
        if not self._data["corrections"]:
            return
        first = self._data["corrections"][0]
        if "wrong_variants" in first:
            return

        old = self._data["corrections"]
        merged: dict[str, dict] = {}
        for entry in old:
            correct = entry["correct"]
            wrong = entry["wrong"]
            count = entry.get("count", 1)
            if correct in merged:
                if wrong not in merged[correct]["wrong_variants"]:
                    merged[correct]["wrong_variants"].append(wrong)
                merged[correct]["count"] += count
            else:
                merged[correct] = {
                    "correct": correct,
                    "wrong_variants": [wrong],
                    "count": count,
                }

        self._data["corrections"] = list(merged.values())
        self._save(self._data)

    def add_correction(self, wrong: str, correct: str) -> None:
        wrong = wrong.strip()
        correct = correct.strip()
        if not wrong or not correct:
            return

        for entry in self._data["corrections"]:
            if entry["correct"] == correct:
                if wrong not in entry["wrong_variants"]:
                    entry["wrong_variants"].append(wrong)
                entry["count"] += 1
                self._save(self._data)
                return

        self._data["corrections"].append({
            "correct": correct,
            "wrong_variants": [wrong],
            "count": 1,
        })
        self._save(self._data)

    def increment_from_output(self, text: str) -> None:
        """扫描 LLM 输出文本，命中词库正确词则 count+1"""
        changed = False
        for entry in self._data["corrections"]:
            if entry["correct"] in text:
                entry["count"] += 1
                changed = True
        if changed:
            self._save(self._data)

    def build_injection(self) -> str:
        """根据词库大小分层构建 prompt 注入内容"""
        if not self.enabled:
            return ""

        corrections = self._data["corrections"]
        domain_terms = self._data.get("domain_terms", [])

        if not corrections and not domain_terms:
            return ""

        sorted_entries = sorted(corrections, key=lambda e: e["count"], reverse=True)

        total = len(sorted_entries)
        if total > 1000:
            sorted_entries = sorted_entries[:1000]
            total = 1000

        lines = ["【个人语料库】"]
        lines.append("以下是用户的个人词库。请利用这些信息：")
        lines.append("1. 修正 ASR 转写中与「错误变体」相似的识别错误")
        lines.append("2. 从词库整体推断用户的关注领域和语言习惯，进行个性化转写")
        lines.append("")

        if total <= 100:
            lines.append("纠错词条（错误变体 → 正确词）:")
            for entry in sorted_entries:
                variants = ", ".join(f'"{v}"' for v in entry["wrong_variants"])
                lines.append(f'  {variants} → "{entry["correct"]}"')
        else:
            top = sorted_entries[:100]
            rest = sorted_entries[100:]

            lines.append("高频纠错词条（错误变体 → 正确词）:")
            for entry in top:
                variants = ", ".join(f'"{v}"' for v in entry["wrong_variants"])
                lines.append(f'  {variants} → "{entry["correct"]}"')

            lines.append("")
            lines.append("其他已知正确词:")
            rest_words = [entry["correct"] for entry in rest]
            lines.append(f"  {', '.join(rest_words)}")

        if domain_terms:
            lines.append("")
            lines.append(f"领域术语: {', '.join(domain_terms)}")

        return "\n".join(lines) + "\n"

    def add_terms(self, terms: list[str]) -> list[str]:
        """将自动发现的术语加入词库（无错误变体），返回实际新增的词列表"""
        added = []
        for term in terms:
            term = term.strip()
            if not term:
                continue
            if self.is_blacklisted(term):
                continue
            exists = False
            for entry in self._data["corrections"]:
                if entry["correct"] == term:
                    exists = True
                    break
            if not exists:
                self._data["corrections"].append({
                    "correct": term,
                    "wrong_variants": [],
                    "count": 1,
                })
                added.append(term)
        if added:
            self._save(self._data)
        return added

    def lookup(self, word: str) -> dict | None:
        """查找词库中的词条，返回 entry 或 None"""
        word = word.strip()
        for entry in self._data["corrections"]:
            if entry["correct"] == word:
                return entry
        return None

    def delete_term(self, word: str) -> bool:
        """从词库中删除词条并加入黑名单"""
        word = word.strip()
        original_len = len(self._data["corrections"])
        self._data["corrections"] = [
            e for e in self._data["corrections"] if e["correct"] != word
        ]
        found = len(self._data["corrections"]) < original_len
        if found:
            self._save(self._data)
        self.add_to_blacklist(word)
        return found

    def add_term_manual(self, word: str) -> bool:
        """手动将一个词加入词库（无错误变体）"""
        word = word.strip()
        if not word:
            return False
        if self.is_blacklisted(word):
            return False
        for entry in self._data["corrections"]:
            if entry["correct"] == word:
                return False
        self._data["corrections"].append({
            "correct": word,
            "wrong_variants": [],
            "count": 1,
        })
        self._save(self._data)
        return True

    # ── 黑名单管理 ──

    def is_blacklisted(self, word: str) -> bool:
        return word.strip() in self._blacklist

    def add_to_blacklist(self, word: str) -> None:
        word = word.strip()
        if word and word not in self._blacklist:
            self._blacklist.append(word)
            self._save_blacklist(self._blacklist)

    def remove_from_blacklist(self, word: str) -> None:
        word = word.strip()
        if word in self._blacklist:
            self._blacklist.remove(word)
            self._save_blacklist(self._blacklist)

    def _save_blacklist(self, data: list) -> None:
        self._blacklist_path.write_text(
            json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    def _save(self, data: dict) -> None:
        self._path.write_text(
            json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8"
        )
