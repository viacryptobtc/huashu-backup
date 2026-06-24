#!/bin/bash

# CoinEx 话术获取脚本
# 功能：从 Zendesk API 获取话术数据并输出为 CSV 表格

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="${SCRIPT_DIR}/话术数据.csv"

# API URL
API_URL="https://coinex.zendesk.com/api/v2/macros/active?access=shared&per_page=1000"

# 默认认证信息（已脱敏，真实值请通过 config.json 配置）
DEFAULT_EMAIL="<your_zendesk_email@example.com>"
DEFAULT_API_TOKEN="<your_zendesk_api_token>"

# 提示用户输入
echo "========================================="
echo "      CoinEx 话术数据获取工具"
echo "========================================="
echo ""
echo "默认邮箱: ${DEFAULT_EMAIL}"
echo "默认密钥: ${DEFAULT_API_TOKEN:0:10}..."
echo ""
echo "选项:"
echo "  1 - 使用默认邮箱和密钥（直接回车）"
echo "  2 - 修改邮箱地址"
echo "  3 - 修改API密钥"
echo "  4 - 修改邮箱和密钥"
echo ""
read -p "请选择 (1-4，默认为1): " CHOICE
echo ""

# 处理用户选择
case "$CHOICE" in
    2)
        read -p "请输入新的邮箱地址: " EMAIL
        API_TOKEN="$DEFAULT_API_TOKEN"
        ;;
    3)
        EMAIL="$DEFAULT_EMAIL"
        read -sp "请输入新的API密钥: " API_TOKEN
        echo ""
        ;;
    4)
        read -p "请输入新的邮箱地址: " EMAIL
        read -sp "请输入新的API密钥: " API_TOKEN
        echo ""
        ;;
    *)
        EMAIL="$DEFAULT_EMAIL"
        API_TOKEN="$DEFAULT_API_TOKEN"
        ;;
esac

echo ""
echo "使用邮箱: $EMAIL"
echo ""

# 验证输入
if [ -z "$EMAIL" ] || [ -z "$API_TOKEN" ]; then
    echo -e "${RED}错误: 邮箱地址和API密钥不能为空！${NC}"
    exit 1
fi

# 生成 Base64 认证信息
AUTH_STRING="${EMAIL}/token:${API_TOKEN}"
BASE64_AUTH=$(echo -n "$AUTH_STRING" | base64)

echo -e "${YELLOW}正在获取话术数据...${NC}"

# 收集所有话术数据
ALL_RESPONSES=""
PAGE=1
PER_PAGE=100

while true; do
    echo -ne "\r${YELLOW}正在获取第 ${PAGE} 页数据...${NC}"

    # 构建带分页参数的 URL
    PAGE_URL="https://coinex.zendesk.com/api/v2/macros/active?access=shared&per_page=${PER_PAGE}&page=${PAGE}"

    # 发送 API 请求
    RESPONSE=$(curl -s -w "\n%{http_code}" "$PAGE_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Basic ${BASE64_AUTH}")

    # 分离响应体和状态码
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

    # 检查 HTTP 状态码
    if [ "$HTTP_CODE" != "200" ]; then
        echo -e "\n${RED}请求失败！HTTP 状态码: $HTTP_CODE${NC}"
        echo -e "${RED}响应内容: $RESPONSE_BODY${NC}"
        exit 1
    fi

    # 累加响应数据
    if [ -z "$ALL_RESPONSES" ]; then
        ALL_RESPONSES="$RESPONSE_BODY"
    else
        # 合并 JSON 数组 - 使用临时文件避免引号问题
        echo "$ALL_RESPONSES" > /tmp/prev_data.json
        echo "$RESPONSE_BODY" > /tmp/curr_data.json
        ALL_RESPONSES=$(python3 << 'MERGE_EOF'
import json

with open('/tmp/prev_data.json', 'r') as f:
    data1 = json.load(f)

with open('/tmp/curr_data.json', 'r') as f:
    data2 = json.load(f)

data1['macros'].extend(data2.get('macros', []))
print(json.dumps(data1))
MERGE_EOF
        )
        rm -f /tmp/prev_data.json /tmp/curr_data.json
    fi

    # 检查是否还有更多数据
    MACRO_COUNT=$(echo "$RESPONSE_BODY" | python3 -c "import sys, json; print(len(json.loads(sys.stdin.read()).get('macros', [])))")

    if [ "$MACRO_COUNT" -lt "$PER_PAGE" ]; then
        break
    fi

    PAGE=$((PAGE + 1))
done

echo ""
RESPONSE_BODY="$ALL_RESPONSES"

# 解析 JSON 数据
echo -e "${YELLOW}正在解析数据并生成表格...${NC}"

# 创建临时 Python 脚本文件
PYTHON_TMP_FILE=$(mktemp)
cat > "$PYTHON_TMP_FILE" << 'PYEOF'
import json
import sys
import csv
import re
from datetime import datetime
from html import unescape

def html_to_text(html_content):
    if not html_content:
        return ""

    # 移除 <script> 和 <style> 标签及其内容
    html_content = re.sub(r'<script[^>]*>.*?</script>', '', html_content, flags=re.DOTALL | re.IGNORECASE)
    html_content = re.sub(r'<style[^>]*>.*?</style>', '', html_content, flags=re.DOTALL | re.IGNORECASE)

    # 处理 <br> 和 <br/> 标签，替换为换行符
    html_content = re.sub(r'<br\s*/?>', '\n', html_content, flags=re.IGNORECASE)

    # 处理 </p> 标签，替换为换行符
    html_content = re.sub(r'</p>', '\n\n', html_content, flags=re.IGNORECASE)

    # 处理 <div> 和 </div> 标签
    html_content = re.sub(r'<div[^>]*>', '\n', html_content, flags=re.IGNORECASE)
    html_content = re.sub(r'</div>', '\n', html_content, flags=re.IGNORECASE)

    # 处理 <li> 标签
    html_content = re.sub(r'<li[^>]*>', '\n• ', html_content, flags=re.IGNORECASE)

    # 处理 <a> 标签，保留链接文本和URL
    html_content = re.sub(r'<a[^>]*href=["\']([^"\']*)["\'][^>]*>([^<]*)</a>',
                         r'\2 (\1)', html_content, flags=re.IGNORECASE)

    # 处理 <strong> 和 <b> 标签
    html_content = re.sub(r'</?(?:strong|b)[^>]*>', '', html_content, flags=re.IGNORECASE)

    # 处理 <em> 和 <i> 标签
    html_content = re.sub(r'</?(?:em|i)[^>]*>', '', html_content, flags=re.IGNORECASE)

    # 移除所有剩余的 HTML 标签
    html_content = re.sub(r'<[^>]+>', '', html_content)

    # 解码 HTML 实体（如 &nbsp; &amp; 等）
    html_content = unescape(html_content)

    # 将 &nbsp; 替换为空格
    html_content = html_content.replace('\xa0', ' ')

    # 清理多余的空行
    html_content = re.sub(r'\n\s*\n\s*\n', '\n\n', html_content)

    # 移除行首行尾空格
    lines = [line.strip() for line in html_content.split('\n')]
    html_content = '\n'.join(lines)

    # 移除开头和结尾的空白
    html_content = html_content.strip()

    return html_content

try:
    # 读取 JSON 数据
    data = json.loads(sys.stdin.read())
    macros = data.get("macros", [])

    # 准备 CSV 数据
    csv_data = []
    csv_data.append(["话术大类", "话术标题", "更新时间", "创建时间", "话术正文"])

    for macro in macros:
        # 提取标题
        title = macro.get("title", "")

        # 提取话术大类（第一个 "::" 前面的内容）
        category = ""
        if "::" in title:
            category = title.split("::")[0].strip()
        else:
            category = "未分类"

        # 处理时间格式
        updated_at = macro.get("updated_at", "")
        created_at = macro.get("created_at", "")

        # 转换时间格式
        try:
            if updated_at:
                dt = datetime.fromisoformat(updated_at.replace('Z', '+00:00'))
                updated_at = dt.strftime('%Y-%m-%d %H:%M:%S')
        except:
            pass

        try:
            if created_at:
                dt = datetime.fromisoformat(created_at.replace('Z', '+00:00'))
                created_at = dt.strftime('%Y-%m-%d %H:%M:%S')
        except:
            pass

        # 处理话术正文
        actions = macro.get("actions", [])
        cleaned_actions = []

        for action in actions:
            if isinstance(action, str) and action.startswith("[") and action.endswith("]"):
                try:
                    parsed = eval(action)
                    if isinstance(parsed, list) and len(parsed) > 1:
                        html_content = parsed[1]
                        cleaned_actions.append(html_content)
                except:
                    cleaned_actions.append(action)
            elif isinstance(action, str):
                cleaned_actions.append(action)
            elif isinstance(action, dict):
                value = action.get("value", "")
                if isinstance(value, str):
                    cleaned_actions.append(value.replace("pending", ""))

        # 合并所有动作内容
        html_content = "".join(cleaned_actions)

        # 将 HTML 转换为纯文本
        content = html_to_text(html_content)

        # 如果内容为空，使用占位符
        if not content:
            content = "无内容"

        # 添加到 CSV 数据
        csv_data.append([category, title, updated_at, created_at, content])

    # 输出 CSV 格式
    writer = csv.writer(sys.stdout, quoting=csv.QUOTE_ALL)
    writer.writerows(csv_data)

    sys.stderr.write(f"SUCCESS:共处理 {len(macros)} 条话术数据\n")

except json.JSONDecodeError as e:
    sys.stderr.write(f"ERROR:JSON解析失败: {str(e)}\n")
    sys.exit(1)
except Exception as e:
    sys.stderr.write(f"ERROR:处理数据时出错: {str(e)}\n")
    sys.exit(1)
PYEOF

# 使用 Python 处理数据并保存到 CSV
echo "$RESPONSE_BODY" | python3 "$PYTHON_TMP_FILE" 2>error_message > "$OUTPUT_FILE"
PYTHON_EXIT_CODE=$?

# 清理临时文件
rm -f "$PYTHON_TMP_FILE"

# 检查处理结果
if [ $PYTHON_EXIT_CODE -eq 0 ]; then
    ERROR_MSG=$(cat error_message 2>/dev/null)
    if [[ "$ERROR_MSG" == SUCCESS:* ]]; then
        COUNT=$(echo "$ERROR_MSG" | cut -d':' -f2)
        echo -e "${GREEN}成功！${NC}"
        echo -e "${GREEN}$COUNT${NC}"
        echo -e "${GREEN}表格已保存到: $OUTPUT_FILE${NC}"
        rm -f error_message
    else
        echo -e "${RED}处理数据时出错: $ERROR_MSG${NC}"
        rm -f error_message
        exit 1
    fi
else
    ERROR_MSG=$(cat error_message 2>/dev/null)
    echo -e "${RED}处理数据时失败${NC}"
    if [ -n "$ERROR_MSG" ]; then
        echo -e "${RED}错误信息: $ERROR_MSG${NC}"
    fi
    rm -f error_message
    exit 1
fi

echo ""
echo "完成！"
