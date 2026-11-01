# PPTReader

轻量的 macOS 课件伴读应用：一边看课件，一边让读过整份课件的 AI 为你讲解。

[English](README.md) · **中文**

## 功能

- **边看边问**：支持 PDF、PowerPoint、Word（PPT/Word 由本机 Office 转换，原文件不会被修改）。
- **懂上下文**：每次提问都会附上整份课件的文字、当前页码、选中内容和当前页截图。
- **多种提问方式**：讲解本页 · 对选中内容解释 / 翻译 / 举例 · 自由提问 · 翻页自动讲解。
- **完整渲染**：Markdown、LaTeX 公式、代码、表格、SVG、Mermaid、行内 HTML。点按图表可放大预览（捏合或 ⌘ 滚轮缩放、拖动平移），并可拷贝或存储为 PNG。
- **学习统计**：按天、课件和模型统计阅读时长、阅读页数、讲解与提问次数和 Token 用量（7 天 / 30 天 / 全部），已有对话会自动计入。
- **自定义快捷键**：在「设置 → 快捷键」中修改所有菜单命令的快捷键。
- **兼容任意 OpenAI 格式接口**，针对 DeepSeek 优化（`deepseek-flash` 支持识图，`deepseek-v4-pro`，可开关深度思考）。
- 中英文界面、浅色 / 深色模式，原生应用约 7 MB。

## 环境要求

- macOS 14 及以上
- Xcode 命令行工具：`xcode-select --install`
- Microsoft PowerPoint / Word：仅打开 `.ppt(x)` / `.doc(x)` 时需要

## 构建

直接使用：从 [v1.2 发布页](https://github.com/XYoungSky/PPTReader/releases/tag/v1.2) 下载 `PPTReader-v1.2-macOS-arm64.zip`，解压后将 `PPTReader.app` 移入「应用程序」。此安装包需要 Apple Silicon Mac 和 macOS 14 及以上版本。应用采用本地临时签名，未经 Apple 公证，首次打开可能被 macOS 拦截。

从源码构建：

```bash
./scripts/build-app.sh            # 生成 build/Products.noindex/PPTReader.app
./scripts/build-app.sh --install  # 同时安装到 /Applications
```

## 配置

打开 **设置**（⌘,）→ **模型**：

| 项目 | 填写 |
|---|---|
| API 地址 | `https://api.deepseek.com` |
| API Key | 你的 Key |
| 模型 | 点击「测试连接」后选择接口返回的模型，或手动填写服务商支持的模型 ID |

模型列表由接口返回结果和当前选择组成，不再预设模型名称；开始对话前需选择或填写模型。

如果模型不支持图片，会自动识别并去掉截图重试。

## 快捷键

以下为默认快捷键，可在「设置 → 快捷键」中修改（点按快捷键后按下新的组合；⌫ 清除，esc 取消）。

| 操作 | 快捷键 |
|---|---|
| 打开课程文件夹 | ⌘O |
| 讲解当前页 | ⌘E |
| 提问（聚焦输入框） | ⌘L |
| 上一页 / 下一页 | ⌥⌘↑ / ⌥⌘↓ |
| 放大 / 缩小 / 适合窗口 | ⌘= / ⌘- / ⌘0 |
| 停止生成 | ⌘. |
| 显示 / 隐藏侧栏、AI 面板 | ⌃⌘S / ⌥⌘0 |
| 学习统计 | ⇧⌘S |
| 设置 | ⌘, |

总结课件、知识框架、练习题、翻页自动讲解、深度思考和连续滚动默认没有快捷键，可自行设置。

在课件中选中文字会出现工具条（解释 · 翻译 · 举例 · 提问）；点击回答中的「第 N 页」可直接跳转。

## 隐私

- 课程文件夹始终只读。
- 发送给模型服务的内容：课件文字、当前页码与截图、选中内容、最近的对话。
- API Key 存于系统钥匙串 · 对话记录与学习统计：`~/Library/Application Support/PPTReader` · 缓存：`~/Library/Caches/PPTReader`
- 学习统计只保存在本机，可在「设置 → 数据」中清除。

## 目录结构

```
Sources/PPTReader/
  App/        应用入口、菜单命令
  Models/     全局状态、当前课件、对话逻辑
  Services/   API 客户端、提示词、Office 转换、文字提取 / OCR、设置、快捷键、学习统计、多语言
  Views/      窗口布局、侧栏、阅读区、AI 面板、菜单、设置、学习统计、图表预览
Resources/Web/  回答渲染页与图表预览（markdown-it、KaTeX、highlight.js、DOMPurify、Mermaid，离线打包）
scripts/        build-app.sh · fetch-vendor.sh · make-icon.swift
```
