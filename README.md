# CoinEx 话术备份自动推送 📧

每月自动从 Zendesk 拉取 CoinEx 客服话术库，生成 Excel 表格，通过邮件推送到指定收件人。
支持 **一行命令部署**、**收发件人/密钥/时间全可配置**、**无需重启即时生效**。

---

## ✨ 功能特性

- 🔁 **每月自动备份** —— 通过 cron 定时拉取全部话术，生成 `.xlsx` 并邮件发送
- 📎 **Excel 附件** —— 表头冻结、自动筛选、列宽自适应、中文无乱码
- 👥 **多收件人管理** —— 随时新增 / 删除收件邮箱
- 🔧 **全配置可改** —— 发件邮箱、Zendesk 密钥、发送时间都能在菜单里改
- 🔒 **密钥安全** —— 所有敏感信息只在本地 `config.json`（600 权限），绝不进入仓库
- 🧩 **依赖隔离** —— 使用 Python 虚拟环境，不污染系统
- 🚀 **一行部署** —— `curl | bash` 搞定

---

## 🚀 一行命令部署

在你的服务器上执行（需联网、有 `python3` 和 `git`）：

```bash
curl -fsSL https://raw.githubusercontent.com/viacryptobtc/huashu-backup/main/install.sh | bash
```

> 仓库地址 `viacryptobtc/huashu-backup`（如需修改仓库名，把 URL 里 `huashu-backup` 一并替换）。

部署脚本会引导你完成：Zendesk 认证 → 发件 SMTP → 收件人 → 发送时间 → 注册 cron，全程交互式填表，回车保留默认值。

也可以先 clone 再本地部署：
```bash
git clone https://github.com/viacryptobtc/huashu-backup.git
cd 话术备份自动推送
./install.sh
```

---

## 🛠 日常管理

进入交互菜单，所有操作即改即生效（下次 cron 自动用新配置）：

```bash
cd ~/huashu-backup && ./manage.sh
```

```
====== 话术备份管理菜单 ======
  1) 查看当前配置
  2) 新增收件人邮箱
  3) 删除收件人邮箱
  4) 修改发件邮箱（SMTP）
  5) 修改 Zendesk 认证（邮箱/密钥）
  6) 修改发送时间
  7) 立即手动发送一次（测试）
  8) 查看 cron 任务
  9) 卸载
  0) 退出
```

**立即手动测试一封邮件**（带【测试】标记）：
```bash
./manage.sh   # 选 7
# 或直接：
.venv/bin/python src/run_monthly.py --test
```

---

## 📧 常见 SMTP 配置速查表

| 服务商 | SMTP 主机 | 端口 | 加密 | 密码字段 |
|--------|-----------|------|------|----------|
| QQ 邮箱 | `smtp.qq.com` | 465 | SSL | **授权码**（设置→账户→开启 SMTP） |
| 163 邮箱 | `smtp.163.com` | 465 | SSL | **授权码**（设置→POP3/SMTP） |
| Gmail | `smtp.gmail.com` | 465 / 587 | SSL / STARTTLS | **应用专用密码** |
| 企业微信邮箱 | `smtp.exmail.qq.com` | 465 | SSL | 邮箱密码 |
| Outlook / Office365 | `smtp.office365.com` | 587 | STARTTLS | 账户密码 |

> ⚠️ 多数国内邮箱不能直接用登录密码发信，需要单独开启 SMTP 并生成「授权码」，把它填到密码字段。

---

## 📂 项目结构

```
话术备份自动推送/
├── install.sh               # 一行部署脚本
├── uninstall.sh             # 卸载脚本
├── manage.sh                # 交互式管理菜单
├── config/
│   ├── config.example.json  # 配置模板（提交）
│   └── config.json          # 真实配置（gitignore，含密钥）
├── src/
│   ├── config_utils.py      # 配置读写 + 校验
│   ├── fetch_macros.py      # 拉取话术 + HTML→文本
│   ├── build_xlsx.py        # 生成 XLSX
│   ├── send_email.py        # SMTP 发邮件
│   └── run_monthly.py       # cron 入口（串联全流程）
├── logs/                    # 运行日志（gitignore）
├── output/                  # 生成的 xlsx（gitignore）
└── archive/                 # 旧版本（.go/.sh/.py，仅作参考）
```

---

## ⚙️ 配置说明（config.json）

```json
{
  "zendesk":  { "email": "...", "api_token": "...", "base_url": "https://coinex.zendesk.com" },
  "smtp":     { "host": "...", "port": 465, "use_ssl": true, "username": "...", "password": "...", "from_name": "话术备份机器人" },
  "recipients": ["a@example.com", "b@example.com"],
  "schedule": { "day_of_month": 1, "hour": 9, "minute": 0 }
}
```

通常不需要手改，用 `./manage.sh` 即可。`day_of_month` 建议填 1-28（避免没有 29/30/31 号的月份漏发）。

---

## 🔧 系统要求

- Linux 或 macOS（服务器 / Mac 均可）
- Python 3.8+、pip3、git、cron
- 能访问 Zendesk API 和目标 SMTP 服务器
- 内存 256MB+ 足矣

---

## ❓ FAQ

**Q: 收到的邮件附件打开是乱码？**
A: 本工具用 openpyxl 生成标准 xlsx，UTF-8 编码，Excel/WPS/Numbers 都能正常打开。若仍乱码，确认是 xlsx 而非 csv。

**Q: 邮件进了垃圾箱？**
A: 让收件人把发件地址加入通讯录/白名单；或检查发件域名是否配置了 SPF/DKIM。

**Q: cron 到点了没触发？**
A: macOS 需在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里给 `/usr/sbin/cron` 授权；Linux 用 `grep CRON /var/log/syslog` 排查。查看日志：`tail -f logs/cron.log`。

**Q: 想换成每周 / 每天发？**
A: 当前菜单只支持每月固定日。需要的话直接编辑 crontab（`crontab -e`）把那行 `huashu-backup:cron` 的日期字段 `*` 之前那位改掉即可，但注意下次改发送时间会覆盖。

**Q: 怎么更新到新版本？**
A: 重跑部署命令即可，会 `git pull` 更新代码并保留你的 `config.json`：
```bash
curl -fsSL https://raw.githubusercontent.com/<user>/话术备份自动推送/main/install.sh | bash
```

---

## 🗑 卸载

```bash
cd ~/huashu-backup && ./uninstall.sh
```
会移除 cron 任务，并询问是否删除整个目录（含配置和日志）。

---

## 📜 License

仅供内部使用。
