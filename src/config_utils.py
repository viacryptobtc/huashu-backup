"""配置文件读写与校验工具。

所有脚本（拉取、生成、发邮件、cron 入口、管理菜单）统一通过本模块访问
config/config.json，避免配置散落各处、口径不一致。

config.json 结构见 config/config.example.json。
"""

from __future__ import annotations

import json
import os
import re
from datetime import datetime
from typing import Any

# 项目根目录：本文件位于 <root>/src/config_utils.py
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_PATH = os.path.join(PROJECT_ROOT, "config", "config.json")
EXAMPLE_CONFIG_PATH = os.path.join(PROJECT_ROOT, "config", "config.example.json")

# 默认配置（首次部署或缺失字段时回填）
DEFAULTS: dict[str, Any] = {
    "zendesk": {
        "email": "",
        "api_token": "",
        "base_url": "https://coinex.zendesk.com",
    },
    "smtp": {
        "host": "",
        "port": 465,
        "use_ssl": True,
        "username": "",
        "password": "",
        "from_name": "话术备份机器人",
    },
    "recipients": [],
    "schedule": {"day_of_month": 1, "hour": 9, "minute": 0},
}

# 邮箱格式校验
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def is_valid_email(email: str) -> bool:
    """简单校验邮箱格式。"""
    return bool(_EMAIL_RE.match(email.strip()))


def _deep_merge(base: dict, override: dict) -> dict:
    """用 override 递归合并进 base（缺失字段用 base 的默认值补齐）。"""
    result = dict(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def load_config(path: str = CONFIG_PATH) -> dict[str, Any]:
    """读取配置，自动用默认值补齐缺失字段。

    如果配置文件不存在，返回纯默认值（调用方应判断是否已初始化）。
    """
    if not os.path.exists(path):
        return _deep_merge(DEFAULTS, {})
    try:
        with open(path, "r", encoding="utf-8") as f:
            user_cfg = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        raise RuntimeError(f"配置文件 {path} 解析失败: {e}")
    return _deep_merge(DEFAULTS, user_cfg)


def save_config(config: dict[str, Any], path: str = CONFIG_PATH) -> None:
    """写入配置（UTF-8、缩进 2、保留中文可读）。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(config, f, ensure_ascii=False, indent=2)
        f.write("\n")
    # 仅本用户可读写，保护密钥
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def ensure_config_exists() -> bool:
    """若 config.json 不存在则从 example 拷贝一份，返回是否新建。"""
    if os.path.exists(CONFIG_PATH):
        return False
    if os.path.exists(EXAMPLE_CONFIG_PATH):
        with open(EXAMPLE_CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = _deep_merge(DEFAULTS, {})
    save_config(data)
    return True


def validate_config(config: dict[str, Any]) -> list[str]:
    """校验配置完整性，返回错误信息列表（空列表表示通过）。"""
    errors: list[str] = []

    zd = config.get("zendesk", {})
    if not zd.get("email"):
        errors.append("zendesk.email 未配置")
    if not zd.get("api_token"):
        errors.append("zendesk.api_token 未配置")

    smtp = config.get("smtp", {})
    if not smtp.get("host"):
        errors.append("smtp.host 未配置")
    if not smtp.get("username"):
        errors.append("smtp.username 未配置")
    if not smtp.get("password"):
        errors.append("smtp.password 未配置")

    recipients = config.get("recipients", [])
    if not isinstance(recipients, list) or not recipients:
        errors.append("recipients 收件人列表为空")
    else:
        for addr in recipients:
            if not is_valid_email(addr):
                errors.append(f"收件人邮箱格式不正确: {addr}")

    return errors


def parse_recipients_input(raw: str) -> list[str]:
    """把用户输入的逗号/空格/分号分隔的收件人解析为去重后的列表。"""
    parts = re.split(r"[,;\s]+", raw.strip())
    return [p.strip() for p in parts if p.strip()]


def cron_schedule_line(config: dict[str, Any], venv_python: str, run_script: str,
                       log_file: str) -> str:
    """根据 schedule 生成一行 crontab。"""
    sch = config.get("schedule", {})
    minute = sch.get("minute", 0)
    hour = sch.get("hour", 9)
    day = sch.get("day_of_month", 1)
    # MARKER 便于后续卸载/更新时定位
    return (f"{minute} {hour} {day} * * {venv_python} {run_script} "
            f">> \"{log_file}\" 2>&1  # huashu-backup:cron")


def stamp_for_filename(now: datetime | None = None) -> str:
    """生成用于文件名的时间戳，如 2026-06-01。"""
    return (now or datetime.now()).strftime("%Y-%m-%d")
