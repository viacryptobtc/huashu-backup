"""从 Zendesk 拉取话术（Macros）并整理为统一数据结构。

逻辑移植自原 话术备份.sh / 话术备份.go，并复用其经过验证的：
- 分页拉取（每页 100，循环到不足一页为止）
- comment_value_html 提取
- HTML → 纯文本正则转换
- HTML 实体 / Unicode 转义解码

输出：list[dict]，每个 dict 形如：
    {
        "active": "激活" | "未激活",
        "category": "话术大类",
        "title": "话术标题",
        "updated_at": "2026-06-01 09:00:00",
        "created_at": "2026-06-01 09:00:00",
        "content": "话术正文（纯文本）",
    }
"""

from __future__ import annotations

import base64
import re
import sys
from datetime import datetime
from html import unescape
from typing import Any

try:
    import requests
except ImportError:  # pragma: no cover
    requests = None  # type: ignore

PER_PAGE = 100
REQUEST_TIMEOUT = 30


# ------------------------------------------------------------------
# HTML → 纯文本（移植自原脚本，保持输出一致）
# ------------------------------------------------------------------
def html_to_text(html: str) -> str:
    if not html:
        return ""

    # 移除 <script> / <style>
    html = re.sub(r"<script[^>]*>.*?</script>", "", html, flags=re.DOTALL | re.IGNORECASE)
    html = re.sub(r"<style[^>]*>.*?</style>", "", html, flags=re.DOTALL | re.IGNORECASE)

    # 块级标签转换行
    html = re.sub(r"<br\s*/?>", "\n", html, flags=re.IGNORECASE)
    html = re.sub(r"</p>", "\n\n", html, flags=re.IGNORECASE)
    html = re.sub(r"<div[^>]*>", "\n", html, flags=re.IGNORECASE)
    html = re.sub(r"</div>", "\n", html, flags=re.IGNORECASE)
    html = re.sub(r"<li[^>]*>", "\n• ", html, flags=re.IGNORECASE)

    # <a href="url">text</a> → text (url)
    html = re.sub(
        r'<a[^>]*href=["\']([^"\']*)["\'][^>]*>([^<]*)</a>',
        r"\2 (\1)",
        html,
        flags=re.IGNORECASE,
    )

    # 移除其余标签
    html = re.sub(r"<[^>]+>", "", html)

    # 解码 HTML 实体
    html = unescape(html)
    html = html.replace("\xa0", " ").replace("&nbsp;", " ")

    # 压缩多余空行
    html = re.sub(r"\n\s*\n\s*\n", "\n\n", html)
    # 行首尾去空格
    html = "\n".join(line.strip() for line in html.split("\n"))
    return html.strip()


# ------------------------------------------------------------------
# 从单条 macro 解析正文
# ------------------------------------------------------------------
def extract_content(actions: list[Any]) -> str:
    """提取最后一条 comment_value_html / comment_value 作为正文。

    原脚本处理过 value 可能是字符串、也可能是字符串化的列表（Zendesk
    旧格式），这里一并兼容。
    """
    import ast

    last_html = ""
    for action in actions or []:
        if not isinstance(action, dict):
            continue
        field = action.get("field", "")
        if field not in ("comment_value_html", "comment_value"):
            continue
        value = action.get("value", "")
        if not isinstance(value, str) or not value:
            continue

        # 兼容旧格式："[\"comment_value_html\", \"<p>...</p>\"]"
        if value.startswith("[") and value.endswith("]"):
            try:
                parsed = ast.literal_eval(value)
                if isinstance(parsed, list) and len(parsed) > 1:
                    value = parsed[1]
            except (ValueError, SyntaxError, IndexError):
                pass

        last_html = value

    if last_html:
        # 去掉 Zendesk 的 pending 占位标记
        return last_html.replace("pending", "")
    return ""


# ------------------------------------------------------------------
# 时间格式化
# ------------------------------------------------------------------
def format_time(time_str: str) -> str:
    if not time_str:
        return ""
    try:
        dt = datetime.fromisoformat(time_str.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    except ValueError:
        return time_str


# ------------------------------------------------------------------
# 分页拉取
# ------------------------------------------------------------------
def fetch_all_macros(email: str, api_token: str,
                     base_url: str = "https://coinex.zendesk.com",
                     per_page: int = PER_PAGE,
                     progress_writer=None) -> list[dict]:
    """分页拉取所有 shared macros，返回解析后的统一数据列表。

    progress_writer: 可选的回调（如 print），用于输出进度。
    """
    if requests is None:
        raise RuntimeError("缺少 requests 库，请在虚拟环境中运行: pip install requests")

    auth = base64.b64encode(f"{email}/token:{api_token}".encode()).decode()
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Basic {auth}",
    }

    page = 1
    raw_macros: list[dict] = []
    while True:
        url = f"{base_url}/api/v2/macros?access=shared&per_page={per_page}&page={page}"
        if progress_writer:
            progress_writer(f"正在获取第 {page} 页数据...")

        resp = requests.get(url, headers=headers, timeout=REQUEST_TIMEOUT)
        if resp.status_code != 200:
            raise RuntimeError(
                f"请求失败 HTTP {resp.status_code}: {resp.text[:200]}"
            )

        data = resp.json()
        macros = data.get("macros", [])
        raw_macros.extend(macros)

        if len(macros) < per_page:
            break
        page += 1

    return [parse_macro(m) for m in raw_macros]


def parse_macro(macro: dict) -> dict:
    title = macro.get("title", "")
    if "::" in title:
        category = title.split("::", 1)[0].strip()
    else:
        category = "未分类"

    content = html_to_text(extract_content(macro.get("actions", [])))
    return {
        "active": "激活" if macro.get("active") else "未激活",
        "category": category,
        "title": title,
        "updated_at": format_time(macro.get("updated_at", "")),
        "created_at": format_time(macro.get("created_at", "")),
        "content": content or "无内容",
    }


# ------------------------------------------------------------------
# 命令行入口：拉取后输出 CSV（兼容原有用法）
# ------------------------------------------------------------------
def main() -> int:
    import argparse
    import csv

    parser = argparse.ArgumentParser(description="拉取 Zendesk 话术并输出 CSV")
    parser.add_argument("--email", required=True, help="Zendesk 邮箱")
    parser.add_argument("--token", required=True, help="Zendesk API Token")
    parser.add_argument("--base-url", default="https://coinex.zendesk.com")
    parser.add_argument("--output", "-o", default="-", help="输出 CSV 路径，- 表示 stdout")
    args = parser.parse_args()

    rows = fetch_all_macros(args.email, args.token, args.base_url, progress_writer=print)
    header = ["激活状态", "话术大类", "话术标题", "更新时间", "创建时间", "话术正文"]

    out = sys.stdout if args.output == "-" else open(args.output, "w", encoding="utf-8-sig", newline="")
    try:
        writer = csv.writer(out, quoting=csv.QUOTE_ALL)
        writer.writerow(header)
        for r in rows:
            writer.writerow([r["active"], r["category"], r["title"],
                             r["updated_at"], r["created_at"], r["content"]])
    finally:
        if args.output != "-":
            out.close()

    print(f"共处理 {len(rows)} 条话术数据", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
