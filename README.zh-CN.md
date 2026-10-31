# PPTReader

轻量的 macOS 课件伴读应用：一边看课件，一边让读过整份课件的 AI 为你讲解。

[English](README.md) · **中文**

## 功能

- **边看边问**：支持 PDF、PowerPoint、Word（PPT/Word 由本机 Office 转换，原文件不会被修改）。
- **懂上下文**：每次提问都会附上整份课件的文字、当前页码、选中内容和当前页截图。
- **多种提问方式**：讲解本页 · 对选中内容解释 / 翻译 / 举例 · 自由提问 · 翻页自动讲解。
- **完整渲染**：Markdown、LaTeX 公式、代码、表格、SVG、Mermaid、行内 HTML。
- **兼容任意 OpenAI 格式接口**，针对 DeepSeek 优化（`deepseek-flash` 支持识图，`deepseek-v4-pro`，可开关深度思考）。
- 中英文界面、浅色 / 深色模式，原生应用约 7 MB。

## 环境要求

- macOS 14 及以上
- Xcode 命令行工具：`xcode-select --install`
- Microsoft PowerPoint / Word：仅打开 `.ppt(x)` / `.doc(x)` 时需要

## 构建

```bash
./scripts/build-app.sh            # 生成 build/PPTReader.app
./scripts/build-app.sh --install  # 同时安装到 /Applications
```

## 配置

打开 **设置**（⌘,）→ **模型**：

| 项目 | 填写 |
|---|---|
| API 地址 | `https://api.deepseek.com` |
| API Key | 你的 Key |
| 模型 | `deepseek-flash`（快速，支持识图）或 `deepseek-v4-pro`（更强，仅文字） |

如果模型不支持图片，会自动识别并去掉截图重试。

## 快捷键

| 操作 | 快捷键 |
|---|---|
| 打开课程文件夹 | ⌘O |
| 讲解当前页 | ⌘E |
| 上一页 / 下一页 | ⌥⌘↑ / ⌥⌘↓ |
| 放大 / 缩小 / 适合窗口 | ⌘= / ⌘- / ⌘0 |
| 停止生成 | ⌘. |
| 显示 / 隐藏侧栏、AI 面板 | ⌃⌘S / ⌥⌘0 |
| 设置 | ⌘, |

在课件中选中文字会出现工具条（解释 · 翻译 · 举例 · 提问）；点击回答中的「第 N 页」可直接跳转。

## 隐私

- 课程文件夹始终只读。
- 发送给模型服务的内容：课件文字、当前页码与截图、选中内容、最近的对话。
- API Key 存于系统钥匙串 · 对话记录：`~/Library/Application Support/PPTReader` · 缓存：`~/Library/Caches/PPTReader`

## 目录结构

```
Sources/PPTReader/
  App/        应用入口、菜单命令
  Models/     全局状态、当前课件、对话逻辑
  Services/   API 客户端、提示词、Office 转换、文字提取 / OCR、设置、多语言
  Views/      窗口布局、侧栏、阅读区、AI 面板、菜单、设置
Resources/Web/  回答渲染页（markdown-it、KaTeX、highlight.js、DOMPurify、Mermaid，离线打包）
scripts/        build-app.sh · fetch-vendor.sh · make-icon.swift
```
