package main

import (
	"bufio"
	"encoding/base64"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

// 默认认证信息（已脱敏，真实值请通过 config.json 配置）
const (
	DefaultEmail    = "<your_zendesk_email@example.com>"
	DefaultAPIToken = "<your_zendesk_api_token>"
)

// Macro 定义 Zendesk Macro 结构
type Macro struct {
	Title     string    `json:"title"`
	UpdatedAt string    `json:"updated_at"`
	CreatedAt string    `json:"created_at"`
	Active    bool      `json:"active"`
	Actions   []Action  `json:"actions"`
}

//Action 定义 Macro Action 结构
type Action struct {
	Field string      `json:"field"`
	Value interface{} `json:"value"`
}

// MacrosResponse 定义 API 响应结构
type MacrosResponse struct {
	Macros []Macro `json:"macros"`
}

var (
	// ANSI 颜色代码
	Reset  = "\033[0m"
	Red    = "\033[31m"
	Green  = "\033[32m"
	Yellow = "\033[33m"
)

func main() {
	fmt.Println("=========================================")
	fmt.Println("      CoinEx 话术数据获取工具")
	fmt.Println("=========================================")
	fmt.Println()

	// 提供选项
	fmt.Println("选项:")
	fmt.Println("  1 - 使用默认配置（直接回车）")
	fmt.Println("  2 - 修改邮箱地址")
	fmt.Println("  3 - 修改API密钥")
	fmt.Println("  4 - 修改邮箱和密钥")
	fmt.Println()

	reader := bufio.NewReader(os.Stdin)
	fmt.Print("请选择 (1-4，默认为1): ")
	choice, _ := reader.ReadString('\n')
	choice = strings.TrimSpace(choice)

	var email, apiToken string

	switch choice {
	case "2":
		email = readInput(reader, "请输入新的邮箱地址: ")
		apiToken = DefaultAPIToken
	case "3":
		email = DefaultEmail
		apiToken = readPassword(reader, "请输入新的API密钥: ")
	case "4":
		email = readInput(reader, "请输入新的邮箱地址: ")
		apiToken = readPassword(reader, "请输入新的API密钥: ")
	default:
		email = DefaultEmail
		apiToken = DefaultAPIToken
	}

	fmt.Println()
	fmt.Printf("使用邮箱: %s\n\n", email)

	// 验证输入
	if email == "" || apiToken == "" {
		fmt.Printf("%s错误: 邮箱地址和API密钥不能为空！%s\n", Red, Reset)
		os.Exit(1)
	}

	// 生成认证头
	authString := fmt.Sprintf("%s/token:%s", email, apiToken)
	base64Auth := base64.StdEncoding.EncodeToString([]byte(authString))

	// 获取脚本所在目录
	scriptDir, err := os.Getwd()
	if err != nil {
		scriptDir = "."
	}
	outputFile := scriptDir + "/话术数据.csv"

	fmt.Printf("%s正在获取话术数据...%s\n", Yellow, Reset)

	// 分页获取所有数据
	allMacros := []Macro{}
	page := 1
	perPage := 100

	client := &http.Client{
		Timeout: 30 * time.Second,
	}

	for {
		fmt.Printf("\r%s正在获取第 %d 页数据...%s", Yellow, page, Reset)

		url := fmt.Sprintf("https://coinex.zendesk.com/api/v2/macros?access=shared&per_page=%d&page=%d", perPage, page)

		req, err := http.NewRequest("GET", url, nil)
		if err != nil {
			fmt.Printf("\n%s创建请求失败: %v%s\n", Red, err, Reset)
			os.Exit(1)
		}

		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Basic "+base64Auth)

		resp, err := client.Do(req)
		if err != nil {
			fmt.Printf("\n%s请求失败: %v%s\n", Red, err, Reset)
			os.Exit(1)
		}

		if resp.StatusCode != 200 {
			fmt.Printf("\n%s请求失败！HTTP 状态码: %d%s\n", Red, resp.StatusCode, Reset)
			os.Exit(1)
		}

		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			fmt.Printf("\n%s读取响应失败: %v%s\n", Red, err, Reset)
			os.Exit(1)
		}

		var response MacrosResponse
		if err := json.Unmarshal(body, &response); err != nil {
			fmt.Printf("\n%s解析 JSON 失败: %v%s\n", Red, err, Reset)
			os.Exit(1)
		}

		allMacros = append(allMacros, response.Macros...)

		// 如果返回的数据少于每页数量，说明已经是最后一页
		if len(response.Macros) < perPage {
			break
		}

		page++
	}

	fmt.Println()
	fmt.Printf("%s正在解析数据并生成表格...%s\n", Yellow, Reset)

	// 创建 CSV 文件
	file, err := os.Create(outputFile)
	if err != nil {
		fmt.Printf("%s创建文件失败: %v%s\n", Red, err, Reset)
		os.Exit(1)
	}
	defer file.Close()

	// 写入 UTF-8 BOM（可选，帮助某些程序识别编码）
	// file.WriteString("\xEF\xBB\xBF")

	writer := csv.NewWriter(file)
	writer.UseCRLF = false // Unix 风格换行

	// 设置 CSV 写入选项，确保正确处理 UTF-8
	// 不使用 LazyQuotes，确保所有字段都被正确引用

	// 写入表头
	headers := []string{"激活状态", "话术大类", "话术标题", "更新时间", "创建时间", "话术正文"}
	if err := writer.Write(headers); err != nil {
		fmt.Printf("%s写入 CSV 失败: %v%s\n", Red, err, Reset)
		os.Exit(1)
	}

	// 处理每个话术
	for _, macro := range allMacros {
		title := macro.Title

		// 提取话术大类
		category := "未分类"
		if strings.Contains(title, "::") {
			parts := strings.SplitN(title, "::", 2)
			category = strings.TrimSpace(parts[0])
		}

		// 获取激活状态
		activeStatus := "未激活"
		if macro.Active {
			activeStatus = "激活"
		}

		// 处理时间格式
		updatedAt := formatTime(macro.UpdatedAt)
		createdAt := formatTime(macro.CreatedAt)

		// 处理话术正文
		content := extractContent(macro.Actions)
		content = htmlToText(content)

		if content == "" {
			content = "无内容"
		}

		// 写入 CSV
		record := []string{activeStatus, category, title, updatedAt, createdAt, content}
		if err := writer.Write(record); err != nil {
			fmt.Printf("%s写入 CSV 失败: %v%s\n", Red, err, Reset)
			os.Exit(1)
		}
	}

	writer.Flush()

	if err := writer.Error(); err != nil {
		fmt.Printf("%s刷新 CSV 失败: %v%s\n", Red, err, Reset)
		os.Exit(1)
	}

	fmt.Printf("%s成功！%s\n", Green, Reset)
	fmt.Printf("%s共处理 %d 条话术数据%s\n", Green, len(allMacros), Reset)
	fmt.Printf("%s表格已保存到: %s%s\n", Green, outputFile, Reset)
	fmt.Println()
	fmt.Println("完成！")
}

// readInput 读取用户输入
func readInput(reader *bufio.Reader, prompt string) string {
	fmt.Print(prompt)
	text, _ := reader.ReadString('\n')
	return strings.TrimSpace(text)
}

// readPassword 读取密码（简单版本）
func readPassword(reader *bufio.Reader, prompt string) string {
	fmt.Print(prompt)
	text, _ := reader.ReadString('\n')
	return strings.TrimSpace(text)
}

// formatTime 格式化时间
func formatTime(timeStr string) string {
	if timeStr == "" {
		return ""
	}

	// 尝试解析 ISO 8601 格式
	t, err := time.Parse(time.RFC3339Nano, strings.Replace(timeStr, "Z", "+00:00", 1))
	if err != nil {
		return timeStr // 如果解析失败，返回原始字符串
	}

	return t.Format("2006-01-02 15:04:05")
}

// extractContent 从 actions 中提取内容
func extractContent(actions []Action) string {
	// 找到最后一个 comment_value_html 字段（话术内容）
	var lastContentHTML string

	for _, action := range actions {
		field := action.Field
		value := action.Value

		// 检查 value 是否为字符串类型
		valueStr, ok := value.(string)
		if !ok || valueStr == "" {
			continue
		}

		// 只提取 comment_value_html 字段
		if field == "comment_value_html" || field == "comment_value" {
			// 更新为最新的内容（话术内容通常在最后一个）
			lastContentHTML = valueStr
		}
	}

	// 如果找到了话术内容，移除 "pending" 标记
	if lastContentHTML != "" {
		return strings.Replace(lastContentHTML, "pending", "", -1)
	}

	return ""
}

// htmlToText 将 HTML 转换为纯文本
func htmlToText(html string) string {
	if html == "" {
		return ""
	}

	// 移除 <script> 和 <style> 标签及其内容
	scriptRegex := regexp.MustCompile(`(?i)<script[^>]*>.*?</script>`)
	html = scriptRegex.ReplaceAllString(html, "")

	styleRegex := regexp.MustCompile(`(?i)<style[^>]*>.*?</style>`)
	html = styleRegex.ReplaceAllString(html, "")

	// 处理 <br> 标签
	brRegex := regexp.MustCompile(`(?i)<br\s*/?>`)
	html = brRegex.ReplaceAllString(html, "\n")

	// 处理 </p> 标签
	pCloseRegex := regexp.MustCompile(`(?i)</p>`)
	html = pCloseRegex.ReplaceAllString(html, "\n\n")

	// 处理 <div> 标签
	divRegex := regexp.MustCompile(`(?i)<div[^>]*>`)
	html = divRegex.ReplaceAllString(html, "\n")

	divCloseRegex := regexp.MustCompile(`(?i)</div>`)
	html = divCloseRegex.ReplaceAllString(html, "\n")

	// 处理 <li> 标签
	liRegex := regexp.MustCompile(`(?i)<li[^>]*>`)
	html = liRegex.ReplaceAllString(html, "\n• ")

	// 处理 <a> 标签，保留链接文本和URL
	aRegex := regexp.MustCompile(`(?i)<a[^>]*href=["']([^"']*)["'][^>]*>([^<]*)</a>`)
	html = aRegex.ReplaceAllString(html, "$2 ($1)")

	// 移除所有剩余的 HTML 标签
	tagRegex := regexp.MustCompile(`<[^>]+>`)
	html = tagRegex.ReplaceAllString(html, "")

	// 解码 Unicode 转义序列 \uXXXX
	unicodeEscapeRegex := regexp.MustCompile(`\\u([0-9a-fA-F]{4})`)
	html = unicodeEscapeRegex.ReplaceAllStringFunc(html, func(match string) string {
		hexStr := match[2:]
		var codepoint int64
		fmt.Sscanf(hexStr, "%x", &codepoint)
		return string(rune(codepoint))
	})

	// 解码 HTML 实体
	html = htmlEntityDecode(html)

	// 替换剩余的 &nbsp; 为空格（如果有未被解码的）
	html = strings.ReplaceAll(html, "&nbsp;", " ")

	// 清理多余的空行
	spaceRegex := regexp.MustCompile(`\n\s*\n\s*\n`)
	html = spaceRegex.ReplaceAllString(html, "\n\n")

	// 移除每行首尾空格
	lines := strings.Split(html, "\n")
	for i, line := range lines {
		lines[i] = strings.TrimSpace(line)
	}
	html = strings.Join(lines, "\n")

	return strings.TrimSpace(html)
}

// htmlEntityDecode 解码 HTML 实体
func htmlEntityDecode(html string) string {
	// 先解码数字实体 &#1234;
	decimalRegex := regexp.MustCompile(`&#(\d+);`)
	html = decimalRegex.ReplaceAllStringFunc(html, func(match string) string {
		// 提取数字部分（去掉 &# 和 ;）
		numStr := match[2 : len(match)-1]
		var codepoint int
		fmt.Sscanf(numStr, "%d", &codepoint)
		return string(rune(codepoint))
	})

	// 解码十六进制实体 &#x263A;
	hexRegex := regexp.MustCompile(`&#x([0-9a-fA-F]+);`)
	html = hexRegex.ReplaceAllStringFunc(html, func(match string) string {
		// 提取十六进制数字（去掉 &#x 和 ;）
		hexStr := match[3 : len(match)-1]
		var codepoint int64
		fmt.Sscanf(hexStr, "%x", &codepoint)
		return string(rune(codepoint))
	})

	// 常见的 HTML 实体
	entities := map[string]string{
		"&amp;":   "&",
		"&lt;":    "<",
		"&gt;":    ">",
		"&quot;":  "\"",
		"&apos;":  "'",
		"&#39;":   "'",
		"&nbsp;":  " ",
		"&copy;":  "©",
		"&reg;":   "®",
		"&trade;": "™",
		"&euro;":  "€",
		"&pound;": "£",
		"&yen;":   "¥",
		"&cent;":  "¢",
	}

	for entity, char := range entities {
		html = strings.ReplaceAll(html, entity, char)
	}

	return html
}
