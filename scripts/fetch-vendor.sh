#!/bin/zsh
# 下载并整理 Markdown 渲染所需的前端库到 Resources/Web/vendor（离线打包进 App）。
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
VENDOR="$ROOT/Resources/Web/vendor"
WORK="$ROOT/tmp/vendor-dl"
rm -rf "$WORK" && mkdir -p "$WORK"

PACKAGES=(
  markdown-it@14.1.0
  katex@0.16.22
  @highlightjs/cdn-assets@11.11.1
  dompurify@3.2.6
  mermaid@11.4.1
)

cd "$WORK"
for p in $PACKAGES; do
  tgz=$(npm pack "$p" --silent | tail -1)
  dir="${tgz%.tgz}"
  mkdir -p "$dir" && tar -xzf "$tgz" -C "$dir"
done

rm -rf "$VENDOR" && mkdir -p "$VENDOR/katex/fonts" "$VENDOR/hljs"
cp markdown-it-14.1.0/package/dist/markdown-it.min.js "$VENDOR/"
cp dompurify-3.2.6/package/dist/purify.min.js "$VENDOR/"
cp mermaid-11.4.1/package/dist/mermaid.min.js "$VENDOR/"
cp katex-0.16.22/package/dist/katex.min.js katex-0.16.22/package/dist/katex.min.css "$VENDOR/katex/"
cp katex-0.16.22/package/dist/contrib/mhchem.min.js "$VENDOR/katex/"
cp katex-0.16.22/package/dist/fonts/*.woff2 "$VENDOR/katex/fonts/"
cp highlightjs-cdn-assets-11.11.1/package/highlight.min.js "$VENDOR/hljs/"
cp highlightjs-cdn-assets-11.11.1/package/styles/github.min.css "$VENDOR/hljs/github.min.css"
cp highlightjs-cdn-assets-11.11.1/package/styles/github-dark.min.css "$VENDOR/hljs/github-dark.min.css"

rm -rf "$WORK"
echo "vendor 已更新：$VENDOR"
du -sh "$VENDOR"
