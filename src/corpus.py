"""个人语料库管理"""

from __future__ import annotations

import json
from pathlib import Path


class Corpus:
    def __init__(self, path: str):
        self._path = Path(path)
        self._path.parent.mkdir(parents=True, exist_ok=True)
        if not self._path.exists():
            self._save({"corrections": [], "domain_terms": []})
        self._data = json.loads(self._path.read_text(encoding="utf-8"))

    def add_correction(self, wrong: str, correct: str) -> None:
        wrong = wrong.strip()
        correct = correct.strip()
        if not wrong or not correct:
            return

        for entry in self._data["corrections"]:
            if entry["wrong"] == wrong:
                entry["correct"] = correct
                entry["count"] = entry.get("count", 1) + 1
                self._save(self._data)
                return

        self._data["corrections"].append({"wrong": wrong, "correct": correct, "count": 1})
        self._save(self._data)

    def apply_corrections(self, text: str) -> str:
        for entry in self._data["corrections"]:
            text = text.replace(entry["wrong"], entry["correct"])
        return text

    def _save(self, data: dict) -> None:
        self._path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
