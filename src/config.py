"""配置加载与保存模块"""

from pathlib import Path
import yaml


_DEFAULT_CONFIG_PATH = Path(__file__).parent.parent / "config.yaml"


def load_config(config_path: str = None) -> dict:
    if config_path is None:
        config_path = _DEFAULT_CONFIG_PATH
    else:
        config_path = Path(config_path)

    with open(config_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def save_config(config: dict, config_path: str = None) -> None:
    if config_path is None:
        config_path = _DEFAULT_CONFIG_PATH
    else:
        config_path = Path(config_path)

    with open(config_path, "w", encoding="utf-8") as f:
        yaml.dump(config, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
