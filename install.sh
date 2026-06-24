#!/usr/bin/env bash
# ============================================================================
#  CoinEx 话术备份 — 一行命令部署脚本
#  用法（发布到 GitHub 后）：
#    curl -fsSL https://raw.githubusercontent.com/<用户>/<仓库>/main/install.sh | bash
#  或本地直接：
#    ./install.sh
# ============================================================================
set -euo pipefail

# 当通过 `curl | bash` 管道执行时，stdin 被管道占用，
# 后续交互式 read 会失败。这里把 stdin 重定向到终端 tty。
if [ ! -t 0 ]; then
    exec 0</dev/tty 2>/dev/null || true
fi

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { printf "${BLUE}[信息]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[成功]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[警告]${NC} %s\n" "$*"; }
die()   { printf "${RED}[错误]${NC} %s\n" "$*"; exit 1; }

# GitHub 仓库地址（push 后改成你的真实地址，或通过环境变量覆盖）
REPO_URL="${HUASHU_REPO_URL:-https://github.com/viacryptobtc/huashu-backup.git}"
INSTALL_DIR="${HUASHU_INSTALL_DIR:-$HOME/huashu-backup}"
BRANCH="${HUASHU_BRANCH:-main}"

# ---------- 1. 环境检测 ----------
title() { printf "\n${GREEN}======== %s ========${NC}\n" "$*"; }

title "第 1 步：环境检测"
[[ "$(uname -s)" == "Darwin" || "$(uname -s)" == "Linux" ]] || die "仅支持 macOS / Linux。"

command -v python3 >/dev/null 2>&1 || die "未检测到 python3，请先安装 Python 3.8+。"
command -v pip3   >/dev/null 2>&1 || die "未检测到 pip3，请先安装 pip。"
command -v git    >/dev/null 2>&1 || die "未检测到 git，请先安装 git。"
if ! command -v crontab >/dev/null 2>&1; then
    warn "未检测到 crontab，定时任务将无法安装。（macOS 需在系统设置中授予「完全磁盘访问权限」）"
fi
PYVER=$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')
ok "python3 $PYVER / pip3 / git 已就绪"

# ---------- 2. 拉取 / 更新代码 ----------
title "第 2 步：拉取代码到 $INSTALL_DIR"
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "目录已存在，执行 git pull 更新..."
    git -C "$INSTALL_DIR" fetch --quiet origin "$BRANCH"
    git -C "$INSTALL_DIR" reset --hard "origin/$BRANCH" >/dev/null
    ok "代码已更新到最新"
else
    mkdir -p "$(dirname "$INSTALL_DIR")"
    info "git clone $REPO_URL ..."
    git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    ok "代码克隆完成"
fi
cd "$INSTALL_DIR"

# ---------- 3. 虚拟环境 + 依赖 ----------
title "第 3 步：创建虚拟环境并安装依赖"
VENV_DIR="$INSTALL_DIR/.venv"
PY="$VENV_DIR/bin/python"

# 创建虚拟环境（--clear 保证幂等，重装时不残留旧文件）
info "创建虚拟环境 ..."
if ! python3 -m venv --clear "$VENV_DIR"; then
    die "创建虚拟环境失败。请检查 python3 是否完整（可能缺少 ensurepip）。"
fi

# Python 3.12+ 的 venv 可能不带 pip，需要引导
if [ ! -x "$VENV_DIR/bin/pip" ]; then
    info "venv 缺少 pip，正在引导 ..."
    "$PY" -m ensurepip --upgrade || die "ensurepip 失败，请手动执行: python3 -m pip install --user virtualenv"
fi

# 关闭 set -e，因为 pip 升级自身时退出码可能非零但实际成功
set +e
info "升级 pip ..."
"$PY" -m pip install --upgrade pip >/dev/null 2>&1
info "安装 openpyxl / requests ..."
"$PY" -m pip install openpyxl requests
INSTALL_RC=$?
set -e

if [ "$INSTALL_RC" -ne 0 ]; then
    die "依赖安装失败（退出码 $INSTALL_RC）。可手动重试: $PY -m pip install openpyxl requests"
fi

# 确认依赖可用
"$PY" -c "import openpyxl, requests" 2>/dev/null || die "依赖导入失败，请检查虚拟环境: $VENV_DIR"
ok "依赖安装完成（隔离在 $VENV_DIR，不污染系统）"

# ---------- 4. 交互式生成配置 ----------
title "第 4 步：配置（密钥仅写入本地 config.json，不上传）"
CONFIG_FILE="$INSTALL_DIR/config/config.json"

prompt() { # prompt "提示" "默认值" -> 读到 $REPLY
    local msg="$1" def="${2-}"
    if [[ -n "$def" ]]; then
        printf "${YELLOW}%s${NC} [回车保留默认: %s]: " "$msg" "$def"
    else
        printf "${YELLOW}%s${NC}: " "$msg"
    fi
    read -r REPLY
    REPLY="${REPLY:-$def}"
}
prompt_secret() { # 隐藏输入
    local msg="$1" def="${2-}"
    printf "${YELLOW}%s${NC}${msg_silent:+ [回车保留默认]}: " "$msg"
    read -rs REPLY; echo
    REPLY="${REPLY:-$def}"
}

echo
echo "${BLUE}--- Zendesk 认证 ---${NC}"
prompt "Zendesk 邮箱" "your_zendesk_email@example.com"; ZD_EMAIL="$REPLY"
prompt_secret "Zendesk API Token"; ZD_TOKEN="$REPLY"
[[ -z "$ZD_TOKEN" ]] && die "API Token 不能为空。"
ZD_BASE="https://coinex.zendesk.com"

echo
echo "${BLUE}--- 发件邮箱（SMTP）---${NC}"
echo "常见 SMTP 配置："
echo "  QQ邮箱:       smtp.qq.com:465  (SSL)   授权码在 设置→账户→SMTP 开启"
echo "  163邮箱:      smtp.163.com:465 (SSL)   授权码在 设置→POP3/SMTP"
echo "  Gmail:        smtp.gmail.com:465(SSL)/587(TLS)  需用「应用专用密码」"
echo "  企业微信邮箱: smtp.exmail.qq.com:465 (SSL)"
echo "  Outlook:      smtp.office365.com:587 (STARTTLS)"
prompt "SMTP 服务器地址" "smtp.qq.com"; SMTP_HOST="$REPLY"
prompt "SMTP 端口 (465=SSL / 587=STARTTLS)" "465"; SMTP_PORT="$REPLY"
if [[ "$SMTP_PORT" == "465" ]]; then USE_SSL="true"; else USE_SSL="false"; fi
prompt "发件邮箱账号 (用户名)" ""; SMTP_USER="$REPLY"
prompt_secret "发件邮箱密码/授权码"; SMTP_PASS="$REPLY"
prompt "发件人显示名称" "话术备份机器人"; SMTP_NAME="$REPLY"

echo
echo "${BLUE}--- 收件人（可填多个，逗号分隔）---${NC}"
prompt "收件人邮箱（多个用逗号分隔）" ""; RECIPIENTS_RAW="$REPLY"

echo
echo "${BLUE}--- 发送时间 ---${NC}"
prompt "每月几号发送 (1-28)" "1"; SCHED_DAY="$REPLY"
prompt "几点发送 (小时 0-23)" "9"; SCHED_HOUR="$REPLY"
prompt "几分发送 (0-59)" "0"; SCHED_MIN="$REPLY"

# ---------- 5. 写 config.json ----------
info "写入配置文件 $CONFIG_FILE ..."
mkdir -p "$(dirname "$CONFIG_FILE")"

# 用 python 处理收件人切分和 JSON 序列化，避免 shell 转义地狱
"$PY" - "$CONFIG_FILE" "$ZD_EMAIL" "$ZD_TOKEN" "$ZD_BASE" \
    "$SMTP_HOST" "$SMTP_PORT" "$USE_SSL" "$SMTP_USER" "$SMTP_PASS" "$SMTP_NAME" \
    "$RECIPIENTS_RAW" "$SCHED_DAY" "$SCHED_HOUR" "$SCHED_MIN" <<'PYEOF'
import json, re, sys, os
(cfg, email, token, base, host, port, ssl_, user, pwd, name,
 recips, day, hour, minute) = sys.argv[1:]
recipients = [r.strip() for r in re.split(r"[,;\s]+", recips) if r.strip()]
data = {
    "zendesk": {"email": email, "api_token": token, "base_url": base},
    "smtp": {
        "host": host, "port": int(port), "use_ssl": ssl_ == "true",
        "username": user, "password": pwd, "from_name": name,
    },
    "recipients": recipients,
    "schedule": {
        "day_of_month": int(day), "hour": int(hour), "minute": int(minute),
    },
}
os.makedirs(os.path.dirname(cfg), exist_ok=True)
with open(cfg, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2); f.write("\n")
os.chmod(cfg, 0o600)
print("收件人:", ", ".join(recipients))
PYEOF

# 校验
"$PY" "$INSTALL_DIR/src/run_monthly.py" --test >/dev/null 2>&1 || true  # 不在这里真发
ok "配置已保存（权限 600）"

# ---------- 6. 写入 crontab ----------
title "第 5 步：注册定时任务（cron）"
RUN_SCRIPT="$INSTALL_DIR/src/run_monthly.py"
LOG_FILE="$INSTALL_DIR/logs/cron.log"
CRON_LINE="$SCHED_MIN $SCHED_HOUR $SCHED_DAY * * \"$PY\" \"$RUN_SCRIPT\" >> \"$LOG_FILE\" 2>&1 # huashu-backup:cron"

# 清掉旧的（如果重装）
( crontab -l 2>/dev/null | grep -v "huashu-backup:cron" ; echo "$CRON_LINE" ) | crontab -
ok "已注册 cron 任务："
echo "    $CRON_LINE"

# ---------- 7. 可选立即测试 ----------
title "第 6 步：完成"
cat <<EOF
${GREEN}部署成功！${NC}

  安装目录 : $INSTALL_DIR
  配置文件 : $CONFIG_FILE（含密钥，勿外传）
  虚拟环境 : $VENV_DIR
  运行日志 : $LOG_FILE

后续管理：
  修改收件人 / 发件箱 / 密钥 / 发送时间 → ${YELLOW}cd $INSTALL_DIR && ./manage.sh${NC}
  立即手动发送一封测试邮件          → ${YELLOW}./manage.sh${NC} 选 7
  卸载                                → ${YELLOW}./uninstall.sh${NC}
EOF

read -r -p "$(printf "${YELLOW}是否立即发送一封测试邮件验证配置？[y/N]: ${NC}")" YN
if [[ "$YN" =~ ^[Yy]$ ]]; then
    info "正在发送测试邮件 ..."
    if "$PY" "$RUN_SCRIPT" --test; then
        ok "测试邮件已发送，请查收（含【测试】标记）。"
    else
        warn "测试发送失败，请检查日志后用 manage.sh 修正配置。"
    fi
fi
echo
ok "全部完成。"
