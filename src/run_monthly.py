"""月度备份总入口：拉取话术 → 生成 XLSX → 发邮件。

cron 调用的就是本脚本。也支持手动运行（--test 走测试邮件）。

用法：
    python run_monthly.py            # 正式跑一次（cron / 手动）
    python run_monthly.py --test     # 发一封测试邮件，标记【测试】
"""

from __future__ import annotations

import logging
import os
import sys
from datetime import datetime

# 让 `from config_utils import ...` 在 cron 直接调用本文件时也能工作
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import config_utils  # noqa: E402
import fetch_macros  # noqa: E402
import build_xlsx  # noqa: E402
import send_email  # noqa: E402

PROJECT_ROOT = config_utils.PROJECT_ROOT
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "output")
LOG_DIR = os.path.join(PROJECT_ROOT, "logs")


def _setup_logging() -> str:
    """配置日志，同时输出到文件和 stderr。"""
    os.makedirs(LOG_DIR, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d")
    log_file = os.path.join(LOG_DIR, f"run_{stamp}.log")

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.FileHandler(log_file, encoding="utf-8"),
            logging.StreamHandler(sys.stderr),
        ],
        force=True,
    )
    return log_file


def run(test: bool = False) -> int:
    log_file = _setup_logging()
    log = logging.getLogger("huashu.run")
    log.info("=== 开始执行 %s ===", "（测试模式）" if test else "月度备份")

    # 1. 加载并校验配置
    config = config_utils.load_config()
    errors = config_utils.validate_config(config)
    if errors:
        for e in errors:
            log.error("配置错误: %s", e)
        log.error("请运行 manage.sh 修正配置后重试。")
        return 1

    zd = config["zendesk"]
    smtp = config["smtp"]
    recipients = config["recipients"]

    # 2. 拉取话术
    log.info("开始拉取话术（Zendesk）...")
    try:
        rows = fetch_macros.fetch_all_macros(
            email=zd["email"],
            api_token=zd["api_token"],
            base_url=zd.get("base_url", "https://coinex.zendesk.com"),
            progress_writer=lambda msg: log.info(msg),
        )
    except Exception as e:
        log.exception("拉取话术失败: %s", e)
        return 2
    log.info("拉取完成，共 %d 条话术。", len(rows))

    if not rows:
        log.warning("未获取到任何话术，跳过本次发送。")
        return 3

    # 3. 生成 XLSX
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    stamp = config_utils.stamp_for_filename()
    xlsx_name = f"话术数据_{stamp}.xlsx"
    xlsx_path = os.path.join(OUTPUT_DIR, xlsx_name)
    log.info("生成 XLSX: %s", xlsx_path)
    try:
        build_xlsx.build_xlsx(rows, xlsx_path)
    except Exception as e:
        log.exception("生成 XLSX 失败: %s", e)
        return 4
    log.info("XLSX 生成完成。")

    # 4. 发邮件
    subject, body = send_email.build_default_body(count=len(rows), stamp=stamp, is_test=test)
    log.info("发送邮件 → %s", recipients)
    try:
        send_email.send_email(smtp, recipients, subject, body, attachment_path=xlsx_path)
    except Exception as e:
        log.exception("发送邮件失败: %s", e)
        return 5

    log.info("=== 全部完成 ===")
    log.info("日志文件: %s", log_file)
    return 0


def main() -> int:
    test_mode = "--test" in sys.argv
    return run(test=test_mode)


if __name__ == "__main__":
    sys.exit(main())
