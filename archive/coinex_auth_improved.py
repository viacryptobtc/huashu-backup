import tkinter as tk
import tkinter.messagebox as messagebox
import base64
import requests
import json
import ast

def generate_base64_and_save_js():
    account = account_entry.get().strip()
    token = token_entry.get().strip()

    # 验证输入
    if not account or not token:
        messagebox.showerror("错误", "请输入账号和API密钥！")
        return

    try:
        # 生成 Base64 编码的认证信息
        s = account + "/token:" + token
        b = s.encode('utf-8')
        base64_bytes = base64.b64encode(b)
        base64_string = base64_bytes.decode('utf-8')

        headers = {
            "Content-Type": "application/json",
            "Authorization": "Basic " + base64_string
        }

        # 发送请求
        result_label.config(text="正在验证...")
        root.update()

        response = requests.get(url, headers=headers, timeout=10)

        if response.status_code == 200:
            json_data = response.json()

            # 处理宏数据
            for macro in json_data.get("macros", []):
                actions = macro.get("actions", [])
                cleaned_actions = []

                for action in actions:
                    if isinstance(action, str) and action.startswith("[") and action.endswith("]"):
                        # 使用 ast.literal_eval 替代 eval，更安全
                        try:
                            parsed = ast.literal_eval(action)
                            if isinstance(parsed, list) and len(parsed) > 1:
                                html_content = parsed[1]
                                cleaned_actions.append(html_content)
                        except (ValueError, SyntaxError, IndexError):
                            cleaned_actions.append(action)
                    elif isinstance(action, str):
                        cleaned_actions.append(action)
                    elif isinstance(action, dict):
                        value = action.get("value", "")
                        if isinstance(value, str):
                            cleaned_actions.append(value.replace("pending", ""))

                macro["actions"] = "".join(cleaned_actions)

            # 保存到文件
            data_part = json.dumps(json_data.get("macros", []), ensure_ascii=False, indent=4)

            with open("response_data.json", "w", encoding="utf-8") as json_file:
                json_file.write(data_part)

            messagebox.showinfo("验证成功", "验证成功！数据已保存到 response_data.json")
            result_label.config(text="验证成功！")
        else:
            error_msg = f"验证失败\nStatus code: {response.status_code}"
            try:
                error_detail = response.json()
                error_msg += f"\n详情: {error_detail.get('error', '未知错误')}"
            except:
                if response.text:
                    error_msg += f"\n响应: {response.text[:200]}"
            messagebox.showerror("错误", error_msg)
            result_label.config(text="验证失败")

    except requests.exceptions.Timeout:
        error_msg = "请求超时，请检查网络连接或稍后重试"
        messagebox.showerror("错误", error_msg)
        result_label.config(text="请求超时")
    except requests.exceptions.ConnectionError:
        error_msg = "网络连接错误，请检查网络设置"
        messagebox.showerror("错误", error_msg)
        result_label.config(text="连接错误")
    except requests.exceptions.RequestException as e:
        error_msg = f"请求失败: {str(e)}"
        messagebox.showerror("错误", error_msg)
        result_label.config(text="请求失败")
    except json.JSONDecodeError:
        error_msg = "解析响应数据失败，服务器返回了无效的JSON"
        messagebox.showerror("错误", error_msg)
        result_label.config(text="数据解析失败")
    except Exception as e:
        error_msg = f"发生未知错误: {str(e)}"
        messagebox.showerror("错误", error_msg)
        result_label.config(text="发生错误")

# 创建主窗口
root = tk.Tk()
root.title("CoinEx身份验证")
root.geometry("450x200")

# 账号输入
account_label = tk.Label(root, text="请输入账号：")
account_label.pack(pady=(10, 0))
account_entry = tk.Entry(root, width=40)
account_entry.pack(pady=5)

# API密钥输入
token_label = tk.Label(root, text="请输入API密钥：")
token_label.pack()
token_entry = tk.Entry(root, width=40, show="*")  # 隐藏密码
token_entry.pack(pady=5)

# 登录按钮
button = tk.Button(root, text="登录", command=generate_base64_and_save_js, width=15)
button.pack(pady=10)

# 结果标签
result_label = tk.Label(root, text="", fg="blue")
result_label.pack()

# API URL
url = "https://coinex.zendesk.com/api/v2/macros/active?access=shared&per_page=1000"

root.mainloop()
