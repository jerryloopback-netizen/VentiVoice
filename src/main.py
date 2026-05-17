"""VentiVoice 主程序

热键驱动的语音转写 + LLM 润色桌面工具。
- 全局热键 push-to-talk (按住录音，松开转写)
- 三档位热键绑定 (Ctrl+Alt+1/2/3)
- 悬浮窗显示结果
- 剪贴板输出
"""

from __future__ import annotations

import sys
import threading
import time
import tkinter as tk
from tkinter import ttk, scrolledtext
from pathlib import Path
from typing import Optional

import pyperclip
import pystray
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))

from config import load_config, save_config
from asr import build_engine, ASREngine
from llm import LLMProcessor, Tier
from recorder import Recorder
from corpus import Corpus


class VentiVoiceApp:
    def __init__(self):
        self.config = load_config()
        self.recorder = Recorder(
            sample_rate=self.config["recording"]["sample_rate"],
            device=self.config["recording"].get("device"),
        )
        _project_root = Path(__file__).parent.parent
        corpus_path = _project_root / self.config["corpus"]["path"]
        corpus_enabled = self.config["corpus"].get("enabled", True)
        self.corpus = Corpus(str(corpus_path), enabled=corpus_enabled)

        self._current_tier: Tier = self.config["ui"].get("default_tier", 1)

        # 记住上次选择的 ASR 和 LLM
        last_asr = self.config["ui"].get("last_asr_model")
        last_llm = self.config["ui"].get("last_llm_provider")
        self._current_model_name: str = last_asr or self.config["asr"]["default_model"]
        self._current_llm_provider: str = last_llm or self.config["llm"].get("default_provider", "")

        self._hotkey_mode: str = self.config["hotkeys"].get("mode", "push_to_talk")
        self._engine: Optional[ASREngine] = None
        self._llm: Optional[LLMProcessor] = None
        self._recording = False
        self._processing = False

        self._last_result_path = Path(__file__).parent.parent / "corpus" / "last_result.txt"
        self._prev_result: str = self._load_last_result()
        self._current_result: str = ""

        self._load_engine()
        self._try_load_llm()
        self._build_ui()
        self._bind_hotkeys()
        self._setup_tray()

    # ── 引擎管理 ──

    def _load_engine(self):
        try:
            self._engine = build_engine(self.config, self._current_model_name)
            self._set_status(f"ASR 就绪: {self._current_model_name}")
        except Exception as e:
            self._set_status(f"ASR 加载失败: {e}")

    def _try_load_llm(self):
        try:
            self._llm = LLMProcessor(self.config, self._current_llm_provider, corpus=self.corpus)
        except Exception:
            self._llm = None

    def _switch_model(self, model_name: str):
        if model_name == self._current_model_name and self._engine:
            return
        self._current_model_name = model_name
        self.config["ui"]["last_asr_model"] = model_name
        save_config(self.config)
        self._set_status(f"切换模型: {model_name}...")
        threading.Thread(target=self._load_engine, daemon=True).start()

    def _switch_llm_provider(self, provider_name: str):
        if provider_name == self._current_llm_provider and self._llm:
            return
        self._current_llm_provider = provider_name
        self.config["ui"]["last_llm_provider"] = provider_name
        save_config(self.config)
        self._set_status(f"切换 LLM: {provider_name}...")
        try:
            self._llm = LLMProcessor(self.config, provider_name, corpus=self.corpus)
            self._set_status(f"LLM 就绪: {provider_name}")
        except Exception as e:
            self._llm = None
            self._set_status(f"LLM 加载失败: {e}")

    # ── 录音 + 转写流程 ──

    def _start_recording(self, tier: Tier):
        if self._processing:
            return
        if self._hotkey_mode == "toggle" and self._recording:
            self._stop_recording()
            return
        if self._recording:
            return
        self._recording = True
        self._current_tier = tier
        self.recorder.start()
        self._set_status(f"录音中... (档位 {tier})")
        self._recording_indicator.itemconfig(self._rec_dot, fill="#ff4444")

    def _stop_recording(self):
        if not self._recording:
            return
        self._recording = False
        self._recording_indicator.itemconfig(self._rec_dot, fill="#333333")
        audio = self.recorder.stop()

        if len(audio) < 1600:  # < 0.1s
            self._set_status("录音太短，已忽略")
            return

        self._processing = True
        self._set_status("转写中...")
        threading.Thread(target=self._process_audio, args=(audio,), daemon=True).start()

    def _process_audio(self, audio):
        try:
            if not self._engine:
                self._set_status("ASR 引擎未加载")
                return

            sr = self.config["recording"]["sample_rate"]
            t0 = time.time()
            raw_text = self._engine.transcribe(audio, sr)
            asr_time = time.time() - t0

            if not raw_text.strip():
                self._set_status(f"未识别到语音 ({asr_time:.1f}s)")
                return

            self.root.after(0, self._show_result, raw_text, "ASR 原始")

            self._prev_result = self._current_result
            self.root.after(0, self._set_corpus_discover, "")

            if self._llm and self._current_tier:
                self._set_status(f"LLM 处理中 (档位 {self._current_tier})...")
                t1 = time.time()
                result = self._llm.process(raw_text, self._current_tier)
                llm_time = time.time() - t1
                self.corpus.increment_from_output(result)
                self._current_result = result
                self.root.after(0, self._show_result, result, f"档位{self._current_tier}")
                self._set_status(f"完成并已复制 (ASR {asr_time:.1f}s + LLM {llm_time:.1f}s)")

                if self.corpus.enabled:
                    threading.Thread(target=self._discover_terms, args=(result,), daemon=True).start()
            else:
                self._current_result = raw_text
                self._set_status(f"完成并已复制 (ASR {asr_time:.1f}s, 无 LLM)")

        except Exception as e:
            self._set_status(f"错误: {e}")
        finally:
            self._processing = False

    # ── UI ──

    def _build_ui(self):
        self.root = tk.Tk()
        self.root.title("VentiVoice")
        self.root.geometry("480x700")
        self.root.attributes("-topmost", self.config["ui"].get("always_on_top", True))
        self.root.configure(bg="#1e1e1e")

        _icon_path = Path(__file__).parent.parent / "logo.ico"
        if _icon_path.exists():
            self.root.iconbitmap(str(_icon_path))

        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

        style = ttk.Style()
        style.theme_use("clam")
        style.configure("Dark.TFrame", background="#1e1e1e")
        style.configure("Dark.TLabel", background="#1e1e1e", foreground="#cccccc", font=("Segoe UI", 9))
        style.configure("Dark.TButton", font=("Segoe UI", 9))
        style.configure("Dark.TRadiobutton", background="#1e1e1e", foreground="#cccccc", font=("Segoe UI", 9))
        style.configure("Dark.TLabelframe", background="#1e1e1e", foreground="#cccccc")
        style.configure("Dark.TLabelframe.Label", background="#1e1e1e", foreground="#cccccc", font=("Segoe UI", 9))

        main = ttk.Frame(self.root, style="Dark.TFrame", padding=8)
        main.pack(fill=tk.BOTH, expand=True)

        # 顶部: 模型选择 + 录音指示
        top = ttk.Frame(main, style="Dark.TFrame")
        top.pack(fill=tk.X, pady=(0, 6))

        ttk.Label(top, text="ASR 模型:", style="Dark.TLabel").pack(side=tk.LEFT)

        model_names = self._get_model_names()
        self._model_var = tk.StringVar(value=self._current_model_name)
        model_combo = ttk.Combobox(top, textvariable=self._model_var, values=model_names,
                                   state="readonly", width=20)
        model_combo.pack(side=tk.LEFT, padx=(4, 12))
        model_combo.bind("<<ComboboxSelected>>", lambda e: self._switch_model(self._model_var.get()))

        self._recording_indicator = tk.Canvas(top, width=16, height=16, bg="#1e1e1e", highlightthickness=0)
        self._recording_indicator.pack(side=tk.RIGHT)
        self._rec_dot = self._recording_indicator.create_oval(2, 2, 14, 14, fill="#333333", outline="#555555")

        # LLM provider 选择 + 管理
        llm_row = ttk.Frame(main, style="Dark.TFrame")
        llm_row.pack(fill=tk.X, pady=(0, 6))

        ttk.Label(llm_row, text="LLM:", style="Dark.TLabel").pack(side=tk.LEFT)

        llm_providers = list(self.config["llm"].get("providers", {}).keys())
        self._llm_choices = llm_providers + ["+ 新建"]
        self._llm_var = tk.StringVar(value=self._current_llm_provider)
        self._llm_combo = ttk.Combobox(llm_row, textvariable=self._llm_var, values=self._llm_choices,
                                 state="readonly", width=24)
        self._llm_combo.pack(side=tk.LEFT, padx=(4, 8))
        self._llm_combo.bind("<<ComboboxSelected>>", self._on_llm_combo_change)

        self._llm_settings_btn = ttk.Button(llm_row, text="设置", width=5,
                                            command=self._toggle_llm_panel)
        self._llm_settings_btn.pack(side=tk.LEFT, padx=(0, 4))

        self._llm_test_btn = ttk.Button(llm_row, text="测试连通", width=8,
                                        command=self._test_llm_connection)
        self._llm_test_btn.pack(side=tk.LEFT)

        self._corpus_btn = ttk.Button(llm_row, text="个人词库", width=8,
                                      command=self._toggle_corpus_panel)
        self._corpus_btn.pack(side=tk.LEFT, padx=(4, 0))

        # LLM 设置子面板 (默认隐藏)
        self._llm_panel = ttk.LabelFrame(main, text="LLM 配置编辑", style="Dark.TLabelframe", padding=4)
        self._llm_panel_visible = False

        lp_row1 = ttk.Frame(self._llm_panel, style="Dark.TFrame")
        lp_row1.pack(fill=tk.X, pady=2)
        ttk.Label(lp_row1, text="名称:", style="Dark.TLabel", width=10).pack(side=tk.LEFT)
        self._llm_name_entry = ttk.Entry(lp_row1, width=30)
        self._llm_name_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)

        lp_row2 = ttk.Frame(self._llm_panel, style="Dark.TFrame")
        lp_row2.pack(fill=tk.X, pady=2)
        ttk.Label(lp_row2, text="Base URL:", style="Dark.TLabel", width=10).pack(side=tk.LEFT)
        self._llm_url_entry = ttk.Entry(lp_row2, width=30)
        self._llm_url_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)

        lp_row3 = ttk.Frame(self._llm_panel, style="Dark.TFrame")
        lp_row3.pack(fill=tk.X, pady=2)
        ttk.Label(lp_row3, text="API Key:", style="Dark.TLabel", width=10).pack(side=tk.LEFT)
        self._llm_key_entry = ttk.Entry(lp_row3, width=30, show="*")
        self._llm_key_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)

        lp_row4 = ttk.Frame(self._llm_panel, style="Dark.TFrame")
        lp_row4.pack(fill=tk.X, pady=2)
        ttk.Label(lp_row4, text="模型:", style="Dark.TLabel", width=10).pack(side=tk.LEFT)
        self._llm_model_entry = ttk.Entry(lp_row4, width=30)
        self._llm_model_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)

        lp_btns = ttk.Frame(self._llm_panel, style="Dark.TFrame")
        lp_btns.pack(fill=tk.X, pady=(4, 0))
        ttk.Button(lp_btns, text="保存", command=self._save_llm_config).pack(side=tk.LEFT, padx=(0, 4))
        ttk.Button(lp_btns, text="删除此配置", command=self._delete_llm_config).pack(side=tk.LEFT, padx=(0, 4))
        ttk.Button(lp_btns, text="取消", command=self._toggle_llm_panel).pack(side=tk.LEFT)

        # 个人词库面板 (默认隐藏)
        self._corpus_panel = ttk.LabelFrame(main, text="个人词库", style="Dark.TLabelframe", padding=4)
        self._corpus_panel_visible = False

        cp_toggle_row = ttk.Frame(self._corpus_panel, style="Dark.TFrame")
        cp_toggle_row.pack(fill=tk.X, pady=2)
        self._corpus_enabled_var = tk.BooleanVar(value=self.config["corpus"].get("enabled", True))
        self._corpus_toggle_canvas = tk.Canvas(cp_toggle_row, width=16, height=16,
                                               bg="#1e1e1e", highlightthickness=0, cursor="hand2")
        self._corpus_toggle_canvas.pack(side=tk.LEFT)
        self._corpus_toggle_dot = self._corpus_toggle_canvas.create_oval(
            2, 2, 14, 14,
            fill="#4a9eff" if self._corpus_enabled_var.get() else "#555555",
            outline="#777777"
        )
        self._corpus_toggle_canvas.bind("<Button-1>", lambda e: self._on_corpus_toggle())
        ttk.Label(cp_toggle_row, text="个人词库", style="Dark.TLabel").pack(side=tk.LEFT, padx=(4, 0))
        self._corpus_mode_label_var = tk.StringVar(
            value="(开启个人词库)" if self._corpus_enabled_var.get() else "(旅客模式)"
        )
        ttk.Label(cp_toggle_row, textvariable=self._corpus_mode_label_var, style="Dark.TLabel",
                  font=("Segoe UI", 8)).pack(side=tk.LEFT, padx=(8, 0))

        # 词库详情容器（启用时才显示）
        self._corpus_detail_frame = ttk.Frame(self._corpus_panel, style="Dark.TFrame")

        cp_stats_row = ttk.Frame(self._corpus_detail_frame, style="Dark.TFrame")
        cp_stats_row.pack(fill=tk.X, pady=2)
        self._corpus_stats_var = tk.StringVar(value="")
        ttk.Label(cp_stats_row, textvariable=self._corpus_stats_var, style="Dark.TLabel",
                  wraplength=420, justify=tk.LEFT).pack(side=tk.LEFT, fill=tk.X, expand=True)

        cp_profile_row = ttk.Frame(self._corpus_detail_frame, style="Dark.TFrame")
        cp_profile_row.pack(fill=tk.BOTH, expand=True, pady=2)
        self._corpus_profile_text = scrolledtext.ScrolledText(
            cp_profile_row, wrap=tk.WORD, font=("Segoe UI", 9),
            bg="#2d2d2d", fg="#e0e0e0", relief=tk.FLAT, height=4, state=tk.DISABLED
        )
        self._corpus_profile_text.pack(fill=tk.BOTH, expand=True)

        # 搜索行
        cp_search_label = ttk.Label(self._corpus_detail_frame, text="检索词语或手动加入词库:",
                                    style="Dark.TLabel", font=("Segoe UI", 8))
        cp_search_label.pack(fill=tk.X, pady=(4, 0), anchor=tk.W)
        cp_search_row = ttk.Frame(self._corpus_detail_frame, style="Dark.TFrame")
        cp_search_row.pack(fill=tk.X, pady=(2, 2))
        self._corpus_search_entry = ttk.Entry(cp_search_row, width=20)
        self._corpus_search_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)
        ttk.Button(cp_search_row, text="检索", width=6,
                   command=self._corpus_search).pack(side=tk.LEFT, padx=(4, 0))

        # 搜索结果行
        cp_search_result_row = ttk.Frame(self._corpus_detail_frame, style="Dark.TFrame")
        cp_search_result_row.pack(fill=tk.X, pady=2)
        self._corpus_search_result_var = tk.StringVar(value="")
        ttk.Label(cp_search_result_row, textvariable=self._corpus_search_result_var,
                  style="Dark.TLabel", wraplength=400, justify=tk.LEFT).pack(side=tk.LEFT)
        self._corpus_search_action_btn = ttk.Button(cp_search_result_row, text="", width=8,
                                                    command=self._corpus_search_action)
        self._corpus_search_action_btn.pack(side=tk.LEFT, padx=(8, 0))
        self._corpus_search_action_btn.pack_forget()
        self._corpus_search_action_type = ""
        self._corpus_search_word = ""

        if self._corpus_enabled_var.get():
            self._corpus_detail_frame.pack(fill=tk.BOTH, expand=True)

        # 转写结果
        result_frame = ttk.LabelFrame(main, text="转写结果", style="Dark.TLabelframe", padding=4)
        result_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 6))

        self._result_text = scrolledtext.ScrolledText(
            result_frame, wrap=tk.WORD, font=("Segoe UI", 10),
            bg="#2d2d2d", fg="#e0e0e0", insertbackground="#ffffff",
            selectbackground="#264f78", relief=tk.FLAT, height=10
        )
        self._result_text.pack(fill=tk.BOTH, expand=True)

        # 按钮行
        btn_frame = ttk.Frame(main, style="Dark.TFrame")
        btn_frame.pack(fill=tk.X, pady=(0, 6))

        ttk.Button(btn_frame, text="上次结果", width=8, command=self._copy_last_result).pack(side=tk.RIGHT, padx=(4, 0))
        ttk.Button(btn_frame, text="清空", width=8, command=self._clear_result).pack(side=tk.RIGHT, padx=(4, 0))
        ttk.Button(btn_frame, text="热键设置", width=8, command=self._toggle_hotkey_panel).pack(side=tk.RIGHT, padx=(4, 0))
        ttk.Button(btn_frame, text="纠错", width=8, command=self._toggle_correct_panel).pack(side=tk.RIGHT)

        # 纠错面板 (默认隐藏)
        self._correct_panel = ttk.LabelFrame(main, text="纠错", style="Dark.TLabelframe", padding=4)
        self._correct_panel_visible = False

        row1 = ttk.Frame(self._correct_panel, style="Dark.TFrame")
        row1.pack(fill=tk.X, pady=2)
        ttk.Label(row1, text="错误词:", style="Dark.TLabel", width=8).pack(side=tk.LEFT)
        self._wrong_entry = ttk.Entry(row1, width=30)
        self._wrong_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)

        row2 = ttk.Frame(self._correct_panel, style="Dark.TFrame")
        row2.pack(fill=tk.X, pady=2)
        ttk.Label(row2, text="正确词:", style="Dark.TLabel", width=8).pack(side=tk.LEFT)
        self._correct_entry = ttk.Entry(row2, width=30)
        self._correct_entry.pack(side=tk.LEFT, fill=tk.X, expand=True)

        row3 = ttk.Frame(self._correct_panel, style="Dark.TFrame")
        row3.pack(fill=tk.X, pady=2)
        ttk.Button(row3, text="提交纠错", width=8, command=self._submit_correction).pack(side=tk.LEFT, padx=(0, 4))
        ttk.Button(row3, text="取消", width=8, command=self._clear_correction).pack(side=tk.LEFT)

        # 热键设置面板 (默认隐藏)
        self._hotkey_panel = ttk.LabelFrame(main, text="热键设置", style="Dark.TLabelframe", padding=4)
        self._hotkey_panel_visible = False

        mode_row = ttk.Frame(self._hotkey_panel, style="Dark.TFrame")
        mode_row.pack(fill=tk.X, pady=(0, 4))
        ttk.Label(mode_row, text="录音模式:", style="Dark.TLabel").pack(side=tk.LEFT)
        self._mode_var = tk.StringVar(value=self._hotkey_mode)
        ttk.Radiobutton(mode_row, text="按住录音", variable=self._mode_var,
                       value="push_to_talk", style="Dark.TRadiobutton",
                       command=self._on_mode_change).pack(side=tk.LEFT, padx=(8, 0))
        ttk.Radiobutton(mode_row, text="按一下开始/再按结束", variable=self._mode_var,
                       value="toggle", style="Dark.TRadiobutton",
                       command=self._on_mode_change).pack(side=tk.LEFT, padx=(8, 0))

        self._hotkey_labels: dict[int, tk.StringVar] = {}
        self._hotkey_listening: Optional[int] = None

        tier_names = {1: "Clean", 2: "Refine", 3: "Rewrite"}
        hotkeys_cfg = self.config["hotkeys"]
        tier_keys = {1: hotkeys_cfg["tier1"], 2: hotkeys_cfg["tier2"], 3: hotkeys_cfg["tier3"]}

        for tier in (1, 2, 3):
            row = ttk.Frame(self._hotkey_panel, style="Dark.TFrame")
            row.pack(fill=tk.X, pady=1)

            ttk.Label(row, text=f"档位 {tier} ({tier_names[tier]}):",
                     style="Dark.TLabel", width=18).pack(side=tk.LEFT)

            var = tk.StringVar(value=tier_keys[tier])
            self._hotkey_labels[tier] = var
            lbl = ttk.Label(row, textvariable=var, style="Dark.TLabel", width=20,
                           font=("Segoe UI", 9, "bold"))
            lbl.pack(side=tk.LEFT, padx=(4, 8))

            btn = ttk.Button(row, text="修改", width=6,
                           command=lambda t=tier: self._start_hotkey_listen(t))
            btn.pack(side=tk.LEFT)

        # 状态栏
        self._status_var = tk.StringVar(value="就绪")
        status_bar = ttk.Label(main, textvariable=self._status_var, style="Dark.TLabel",
                              font=("Segoe UI", 8))
        status_bar.pack(fill=tk.X, side=tk.BOTTOM)

        # 词库发现提示栏（第二行状态）
        self._corpus_discover_var = tk.StringVar(value="")
        self._corpus_discover_bar = ttk.Label(main, textvariable=self._corpus_discover_var,
                                              style="Dark.TLabel", font=("Segoe UI", 8))
        self._corpus_discover_bar.pack(fill=tk.X, side=tk.BOTTOM)

    def _get_model_names(self) -> list[str]:
        sherpa = self.config["asr"].get("sherpa_onnx", {}).get("models", {})
        return list(sherpa.keys())

    def _set_tier(self, tier: Tier):
        self._current_tier = tier

    def _set_status(self, text: str):
        try:
            self.root.after(0, lambda: self._status_var.set(text))
        except Exception:
            pass

    def _show_result(self, text: str, label: str):
        self._result_text.delete("1.0", tk.END)
        self._result_text.insert("1.0", text)
        pyperclip.copy(text)

    def _clear_result(self):
        self._result_text.delete("1.0", tk.END)

    def _copy_last_result(self):
        if self._prev_result:
            pyperclip.copy(self._prev_result)
            self._set_status("已复制上次转写结果")
        else:
            self._set_status("暂无上次结果")

    def _load_last_result(self) -> str:
        if self._last_result_path.exists():
            return self._last_result_path.read_text(encoding="utf-8").strip()
        return ""

    def _save_last_result(self, text: str):
        self._last_result_path.parent.mkdir(parents=True, exist_ok=True)
        self._last_result_path.write_text(text, encoding="utf-8")

    def _discover_terms(self, text: str):
        """第三层 LLM：从转写结果中自动发现专业术语并加入词库"""
        if not self._llm:
            return
        terms = self._llm.discover_terms(text)
        if terms:
            added = self.corpus.add_terms(terms)
            if added:
                msg = f"词库 + : {', '.join(added)}"
                self.root.after(0, self._set_corpus_discover, msg)

    def _set_corpus_discover(self, text: str):
        self._corpus_discover_var.set(text)

    def _toggle_correct_panel(self):
        if self._correct_panel_visible:
            self._correct_panel.pack_forget()
            self._correct_panel_visible = False
        else:
            self._correct_panel.pack(fill=tk.X, pady=(0, 6), side=tk.BOTTOM)
            self._correct_panel_visible = True

    def _toggle_hotkey_panel(self):
        if self._hotkey_panel_visible:
            self._hotkey_panel.pack_forget()
            self._hotkey_panel_visible = False
        else:
            self._hotkey_panel.pack(fill=tk.X, pady=(0, 6), side=tk.BOTTOM)
            self._hotkey_panel_visible = True

    def _submit_correction(self):
        wrong = self._wrong_entry.get().strip()
        correct = self._correct_entry.get().strip()
        if wrong and correct:
            self.corpus.add_correction(wrong, correct)
            current = self._result_text.get("1.0", tk.END)
            current = current.replace(wrong, correct).strip()
            self._result_text.delete("1.0", tk.END)
            self._result_text.insert("1.0", current)
            pyperclip.copy(current)
            self._clear_correction()
            self._set_status(f"已纠错: {wrong} -> {correct}")

    def _clear_correction(self):
        self._wrong_entry.delete(0, tk.END)
        self._correct_entry.delete(0, tk.END)

    # ── LLM 配置管理 ──

    def _on_llm_combo_change(self, event=None):
        selected = self._llm_var.get()
        if selected == "+ 新建":
            self._show_llm_panel(new=True)
        else:
            self._switch_llm_provider(selected)
            if self._llm_panel_visible:
                self._populate_llm_panel(selected)

    def _toggle_llm_panel(self):
        if self._llm_panel_visible:
            self._llm_panel.pack_forget()
            self._llm_panel_visible = False
        else:
            selected = self._llm_var.get()
            if selected == "+ 新建":
                self._show_llm_panel(new=True)
            else:
                self._show_llm_panel(new=False)

    def _show_llm_panel(self, new: bool = False):
        if not self._llm_panel_visible:
            self._llm_panel.pack(fill=tk.X, pady=(0, 6),
                                after=self._llm_combo.master)
            self._llm_panel_visible = True

        self._llm_name_entry.delete(0, tk.END)
        self._llm_url_entry.delete(0, tk.END)
        self._llm_key_entry.delete(0, tk.END)
        self._llm_model_entry.delete(0, tk.END)

        if new:
            self._llm_editing_name = None
            self._llm_name_entry.insert(0, "new-provider")
        else:
            name = self._llm_var.get()
            self._populate_llm_panel(name)

    def _populate_llm_panel(self, name: str):
        self._llm_editing_name = name
        providers = self.config["llm"].get("providers", {})
        p = providers.get(name, {})

        self._llm_name_entry.delete(0, tk.END)
        self._llm_name_entry.insert(0, name)
        self._llm_url_entry.delete(0, tk.END)
        self._llm_url_entry.insert(0, p.get("base_url", ""))
        self._llm_key_entry.delete(0, tk.END)
        self._llm_key_entry.insert(0, p.get("api_key", ""))
        self._llm_model_entry.delete(0, tk.END)
        self._llm_model_entry.insert(0, p.get("model", ""))

    def _save_llm_config(self):
        new_name = self._llm_name_entry.get().strip()
        base_url = self._llm_url_entry.get().strip()
        api_key = self._llm_key_entry.get().strip()
        model = self._llm_model_entry.get().strip()

        if not new_name or not base_url:
            self._set_status("名称和 Base URL 不能为空")
            return

        providers = self.config["llm"].setdefault("providers", {})

        if self._llm_editing_name and self._llm_editing_name != new_name:
            if self._llm_editing_name in providers:
                del providers[self._llm_editing_name]

        providers[new_name] = {
            "base_url": base_url,
            "api_key": api_key,
            "model": model,
            "max_tokens": 2048,
            "temperature": 0.3,
        }

        self._current_llm_provider = new_name
        self.config["ui"]["last_llm_provider"] = new_name
        if self.config["llm"].get("default_provider") == self._llm_editing_name:
            self.config["llm"]["default_provider"] = new_name
        save_config(self.config)

        self._refresh_llm_combo()
        self._llm_var.set(new_name)
        self._try_load_llm()
        self._toggle_llm_panel()
        self._set_status(f"LLM 配置已保存: {new_name}")

    def _delete_llm_config(self):
        name = self._llm_editing_name or self._llm_name_entry.get().strip()
        providers = self.config["llm"].get("providers", {})
        if name in providers:
            del providers[name]
            save_config(self.config)
            self._refresh_llm_combo()
            remaining = list(providers.keys())
            if remaining:
                self._llm_var.set(remaining[0])
                self._switch_llm_provider(remaining[0])
            else:
                self._llm_var.set("")
                self._llm = None
            self._toggle_llm_panel()
            self._set_status(f"已删除 LLM 配置: {name}")

    def _refresh_llm_combo(self):
        providers = list(self.config["llm"].get("providers", {}).keys())
        self._llm_choices = providers + ["+ 新建"]
        self._llm_combo["values"] = self._llm_choices

    def _test_llm_connection(self):
        self._set_status("测试 LLM 连通性...")
        threading.Thread(target=self._do_test_llm, daemon=True).start()

    def _do_test_llm(self):
        import httpx
        try:
            provider = self._llm_var.get()
            providers = self.config["llm"].get("providers", {})
            if provider not in providers:
                self._set_status("未选择有效的 LLM 配置")
                return
            p = providers[provider]
            base_url = p["base_url"].rstrip("/")
            resp = httpx.post(
                f"{base_url}/chat/completions",
                headers={
                    "Authorization": f"Bearer {p.get('api_key', '')}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": p.get("model", ""),
                    "messages": [{"role": "user", "content": "hi"}],
                    "max_tokens": 5,
                },
                timeout=15.0,
            )
            if resp.status_code == 200:
                self._set_status(f"连通成功: {provider}")
            else:
                self._set_status(f"连通失败 ({resp.status_code}): {resp.text[:80]}")
        except Exception as e:
            self._set_status(f"连通失败: {e}")

    # ── 个人词库面板 ──

    def _toggle_corpus_panel(self):
        if self._corpus_panel_visible:
            self._corpus_panel.pack_forget()
            self._corpus_panel_visible = False
        else:
            self._corpus_panel.pack(fill=tk.X, pady=(0, 6),
                                    after=self._llm_panel if self._llm_panel_visible
                                    else self._llm_combo.master)
            self._corpus_panel_visible = True
            if self._corpus_enabled_var.get():
                self._update_corpus_stats()
                self._request_corpus_profile()

    def _on_corpus_toggle(self):
        enabled = not self._corpus_enabled_var.get()
        self._corpus_enabled_var.set(enabled)
        self.config["corpus"]["enabled"] = enabled
        self.corpus.enabled = enabled
        save_config(self.config)
        color = "#4a9eff" if enabled else "#555555"
        self._corpus_toggle_canvas.itemconfig(self._corpus_toggle_dot, fill=color)
        self._corpus_mode_label_var.set("(开启个人词库)" if enabled else "(旅客模式)")
        if enabled:
            self._corpus_detail_frame.pack(fill=tk.BOTH, expand=True)
            self._set_status("个人词库已启用")
            self._update_corpus_stats()
            self._request_corpus_profile()
        else:
            self._corpus_detail_frame.pack_forget()
            self._set_status("个人词库已关闭 (旅客模式)")

    def _update_corpus_stats(self):
        corrections = self.corpus._data.get("corrections", [])
        total = len(corrections)
        if total == 0:
            self._corpus_stats_var.set("词条总数: 0")
            return
        top_entry = max(corrections, key=lambda e: e["count"])
        self._corpus_stats_var.set(
            f"词条总数: {total} | 最高频: \"{top_entry['correct']}\" (count={top_entry['count']})"
        )

    def _request_corpus_profile(self):
        self._corpus_profile_text.config(state=tk.NORMAL)
        self._corpus_profile_text.delete("1.0", tk.END)
        self._corpus_profile_text.insert("1.0", "正在分析词库特征...")
        self._corpus_profile_text.config(state=tk.DISABLED)
        threading.Thread(target=self._do_corpus_profile, daemon=True).start()

    def _do_corpus_profile(self):
        import httpx

        corrections = self.corpus._data.get("corrections", [])
        if not corrections:
            self.root.after(0, self._set_corpus_profile, "词库为空，暂无特征分析。")
            return

        provider = self._llm_var.get()
        providers = self.config["llm"].get("providers", {})
        if provider not in providers:
            self.root.after(0, self._set_corpus_profile, "未配置 LLM，无法分析。")
            return

        p = providers[provider]
        sorted_entries = sorted(corrections, key=lambda e: e["count"], reverse=True)[:200]

        corpus_summary_lines = []
        for entry in sorted_entries:
            variants = ", ".join(entry["wrong_variants"][:3])
            corpus_summary_lines.append(f"{entry['correct']} (count={entry['count']}, 错误变体: {variants})")

        corpus_text = "\n".join(corpus_summary_lines)

        prompt = (
            "下面是一位用户的语音转写个人词库（词条和使用频率）。\n"
            "请用1-2句简短的中文，以第二人称直接对用户说，概括你从词库中看到的信息：\n"
            "- 用户主要在哪些领域转写\n"
            "- 高频词反映了什么兴趣或习惯\n"
            "- 你会在未来转写中注意什么\n\n"
            "语气轻松自然，像朋友聊天，不要用\"该用户\"这种第三人称。"
            "不要分点列举，就说一两句话。\n\n"
            f"词库（共{len(corrections)}条，前{len(sorted_entries)}条按频率排序）:\n"
            f"{corpus_text}"
        )

        try:
            base_url = p["base_url"].rstrip("/")
            resp = httpx.post(
                f"{base_url}/chat/completions",
                headers={
                    "Authorization": f"Bearer {p.get('api_key', '')}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": p.get("model", ""),
                    "messages": [{"role": "user", "content": prompt}],
                    "max_tokens": 1024,
                    "temperature": 0.4,
                },
                timeout=60.0,
            )
            if resp.status_code == 200:
                result = resp.json()["choices"][0]["message"]["content"].strip()
                self.root.after(0, self._set_corpus_profile, result)
            else:
                self.root.after(0, self._set_corpus_profile, f"分析失败 ({resp.status_code})")
        except Exception as e:
            self.root.after(0, self._set_corpus_profile, f"分析失败: {e}")

    def _set_corpus_profile(self, text: str):
        self._corpus_profile_text.config(state=tk.NORMAL)
        self._corpus_profile_text.delete("1.0", tk.END)
        self._corpus_profile_text.insert("1.0", text)
        self._corpus_profile_text.config(state=tk.DISABLED)

    def _corpus_search(self):
        word = self._corpus_search_entry.get().strip()
        if not word:
            return

        self._corpus_search_word = word
        self._corpus_search_action_btn.pack_forget()

        if self.corpus.is_blacklisted(word):
            self._corpus_search_result_var.set(f"「{word}」已加入词库黑名单")
            self._corpus_search_action_type = "restore"
            self._corpus_search_action_btn.config(text="恢复")
            self._corpus_search_action_btn.pack(side=tk.LEFT, padx=(8, 0))
        else:
            entry = self.corpus.lookup(word)
            if entry:
                self._corpus_search_result_var.set(
                    f"「{word}」在词库中, count={entry['count']}"
                )
                self._corpus_search_action_type = "delete"
                self._corpus_search_action_btn.config(text="删除")
                self._corpus_search_action_btn.pack(side=tk.LEFT, padx=(8, 0))
            else:
                self._corpus_search_result_var.set(f"您暂未把「{word}」加入词库")
                self._corpus_search_action_type = "add"
                self._corpus_search_action_btn.config(text="加入词库")
                self._corpus_search_action_btn.pack(side=tk.LEFT, padx=(8, 0))

    def _corpus_search_action(self):
        word = self._corpus_search_word
        if not word:
            return

        if self._corpus_search_action_type == "delete":
            self.corpus.delete_term(word)
            self._corpus_search_result_var.set(f"「{word}」已删除并加入黑名单")
            self._corpus_search_action_btn.pack_forget()
            self._update_corpus_stats()
        elif self._corpus_search_action_type == "restore":
            self.corpus.remove_from_blacklist(word)
            self._corpus_search_result_var.set(f"「{word}」已从黑名单移除")
            self._corpus_search_action_btn.pack_forget()
        elif self._corpus_search_action_type == "add":
            self.corpus.add_term_manual(word)
            self._corpus_search_result_var.set(f"「{word}」已加入词库")
            self._corpus_search_action_btn.pack_forget()
            self._update_corpus_stats()

    # ── 录音模式切换 ──

    def _on_mode_change(self):
        self._hotkey_mode = self._mode_var.get()
        self.config["hotkeys"]["mode"] = self._hotkey_mode
        save_config(self.config)
        label = "按住录音" if self._hotkey_mode == "push_to_talk" else "按一下开始/再按结束"
        self._set_status(f"录音模式: {label}")

    # ── 热键自定义 ──

    def _start_hotkey_listen(self, tier: int):
        if self._hotkey_listening is not None:
            return
        self._hotkey_listening = tier
        self._listen_keys: set[str] = set()
        self._listen_combo: str = ""
        self._hotkey_labels[tier].set("按下组合键...")
        self._set_status(f"正在监听档位 {tier} 的新热键，按下组合键后松开任意键确认")

    def _capture_key_press(self, key) -> Optional[str]:
        """在监听模式下捕获按键，返回格式化的组合键字符串或 None"""
        if self._hotkey_listening is None:
            return None

        key_str = self._key_to_str(key)
        self._listen_keys.add(key_str)

        display = self._format_combo(self._listen_keys)
        tier = self._hotkey_listening
        self.root.after(0, lambda: self._hotkey_labels[tier].set(display))
        return key_str

    def _capture_key_release(self, key) -> bool:
        """在监听模式下，松开任意键时确认组合键。返回 True 表示已处理。"""
        if self._hotkey_listening is None:
            return False

        if len(self._listen_keys) < 2:
            key_str = self._key_to_str(key)
            self._listen_keys.discard(key_str)
            if not self._listen_keys:
                self._hotkey_labels[self._hotkey_listening].set("需要至少2个键")
            return True

        combo = self._format_combo(self._listen_keys)
        tier = self._hotkey_listening
        self._hotkey_listening = None

        self.root.after(0, self._apply_new_hotkey, tier, combo)
        self._listen_keys.clear()
        return True

    def _format_combo(self, keys: set[str]) -> str:
        order = []
        for mod in ("ctrl", "alt", "shift"):
            if mod in keys:
                order.append(mod)
        for k in sorted(keys):
            if k not in ("ctrl", "alt", "shift"):
                order.append(k)
        return "+".join(order)

    def _apply_new_hotkey(self, tier: int, combo: str):
        self._hotkey_labels[tier].set(combo)

        tier_key = f"tier{tier}"
        self.config["hotkeys"][tier_key] = combo
        self._hotkey_map = {
            self.config["hotkeys"]["tier1"]: 1,
            self.config["hotkeys"]["tier2"]: 2,
            self.config["hotkeys"]["tier3"]: 3,
        }

        save_config(self.config)
        self._set_status(f"档位 {tier} 热键已更新为: {combo}")

    # ── 热键 ──

    def _bind_hotkeys(self):
        from pynput import keyboard

        hotkeys = self.config["hotkeys"]
        self._hotkey_map = {
            hotkeys["tier1"]: 1,
            hotkeys["tier2"]: 2,
            hotkeys["tier3"]: 3,
        }

        self._pressed_keys: set = set()
        self._active_tier: Optional[int] = None

        self._kb_listener = keyboard.Listener(
            on_press=self._on_key_press,
            on_release=self._on_key_release,
        )
        self._kb_listener.daemon = True
        self._kb_listener.start()

    def _parse_hotkey(self, hotkey_str: str) -> set[str]:
        parts = hotkey_str.lower().replace(" ", "").split("+")
        normalized = set()
        for p in parts:
            if p in ("ctrl", "control"):
                normalized.add("ctrl")
            elif p == "alt":
                normalized.add("alt")
            elif p == "shift":
                normalized.add("shift")
            else:
                normalized.add(p)
        return normalized

    def _key_to_str(self, key) -> str:
        from pynput import keyboard
        if isinstance(key, keyboard.Key):
            name = key.name.lower()
            if "ctrl" in name:
                return "ctrl"
            if "alt" in name:
                return "alt"
            if "shift" in name:
                return "shift"
            return name
        elif hasattr(key, "char") and key.char:
            return key.char.lower()
        elif hasattr(key, "vk"):
            vk = key.vk
            if 48 <= vk <= 57:
                return str(vk - 48)
            if 96 <= vk <= 105:
                return str(vk - 96)
        return str(key)

    def _on_key_press(self, key):
        if self._hotkey_listening is not None:
            self._capture_key_press(key)
            return

        key_str = self._key_to_str(key)
        self._pressed_keys.add(key_str)

        if self._hotkey_mode == "toggle":
            for hotkey_str, tier in self._hotkey_map.items():
                required = self._parse_hotkey(hotkey_str)
                if required.issubset(self._pressed_keys):
                    self.root.after(0, self._start_recording, tier)
                    break
            return

        if self._active_tier is not None:
            return

        for hotkey_str, tier in self._hotkey_map.items():
            required = self._parse_hotkey(hotkey_str)
            if required.issubset(self._pressed_keys):
                self._active_tier = tier
                self.root.after(0, self._start_recording, tier)
                break

    def _on_key_release(self, key):
        if self._capture_key_release(key):
            return

        key_str = self._key_to_str(key)
        self._pressed_keys.discard(key_str)

        if self._hotkey_mode == "toggle":
            return

        if self._active_tier is not None:
            hotkey_str = list(self._hotkey_map.keys())[self._active_tier - 1]
            required = self._parse_hotkey(hotkey_str)
            if not required.issubset(self._pressed_keys):
                self._active_tier = None
                self.root.after(0, self._stop_recording)

    # ── 系统托盘 ──

    def _setup_tray(self):
        icon_image = self._create_tray_icon()
        menu = pystray.Menu(
            pystray.MenuItem("显示", self._tray_show, default=True),
            pystray.MenuItem("退出", self._tray_quit),
        )
        self._tray = pystray.Icon("VentiVoice", icon_image, "VentiVoice", menu)
        tray_thread = threading.Thread(target=self._tray.run)
        tray_thread.daemon = False
        tray_thread.start()

    def _create_tray_icon(self) -> Image.Image:
        ico_path = Path(__file__).parent.parent / "logo.ico"
        if ico_path.exists():
            return Image.open(ico_path)
        img = Image.new("RGB", (64, 64), (30, 30, 30))
        draw = ImageDraw.Draw(img)
        draw.ellipse([4, 4, 60, 60], fill=(74, 158, 255))
        return img

    def _tray_show(self, icon=None, item=None):
        self.root.after(0, self._show_window)

    def _show_window(self):
        self.root.deiconify()
        self.root.lift()

    def _tray_quit(self, icon=None, item=None):
        if hasattr(self, "_tray"):
            self._tray.stop()
        self.root.after(0, self._quit)

    def _quit(self):
        if self._current_result:
            self._save_last_result(self._current_result)
        elif self._prev_result:
            self._save_last_result(self._prev_result)
        if hasattr(self, "_kb_listener"):
            self._kb_listener.stop()
        self.root.quit()
        self.root.destroy()

    def _on_close(self):
        self.root.withdraw()
        self._set_status("已最小化到系统托盘")

    def run(self):
        self.root.mainloop()


def main():
    app = VentiVoiceApp()
    app.run()


if __name__ == "__main__":
    main()
