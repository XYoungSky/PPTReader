/*
 * PPTReader 讲解面板渲染器
 * Markdown（markdown-it）+ LaTeX（KaTeX）+ 代码高亮（highlight.js）+ SVG + Mermaid + 行内 HTML，
 * 所有 HTML 经 DOMPurify 清洗。Swift 通过 window.PPT 推送消息，网页通过 bridge 回传事件。
 */
(() => {
  'use strict';

  // ---------------------------------------------------------------- 通信

  function post(message) {
    try {
      window.webkit.messageHandlers.bridge.postMessage(message);
    } catch (_) {
      console.log('[bridge]', message);
    }
  }

  window.addEventListener('error', (e) => post({ type: 'log', message: `${e.message} @${e.lineno}` }));

  // ---------------------------------------------------------------- 工具

  const esc = (s) => String(s ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

  function boundedCache(limit) {
    const map = new Map();
    return {
      get: (k) => map.get(k),
      set(k, v) {
        if (map.size >= limit) map.delete(map.keys().next().value);
        map.set(k, v);
      },
      clear: () => map.clear(),
    };
  }

  const prefersDark = window.matchMedia('(prefers-color-scheme: dark)');

  /** 界面文案：中英成对，按 App 设置的语言选择。 */
  const t = (zh, en) => (state.meta.lang === 'en' ? en : zh);

  // ---------------------------------------------------------------- 数学公式保护
  // 在 Markdown 解析前把公式替换成占位符，避免 _ * \ 等字符被 Markdown 误解析；
  // 代码块与行内代码中的内容保持原样。

  const PH_OPEN = '';
  const PH_CLOSE = '';
  const PH_RE = /(\d+)/g;
  const MATH_ENVS = new Set([
    'equation', 'align', 'aligned', 'gather', 'gathered', 'multline', 'split', 'alignat',
    'eqnarray', 'cases', 'matrix', 'pmatrix', 'bmatrix', 'vmatrix', 'Vmatrix', 'array',
  ]);

  function protectMath(src, store) {
    const lines = src.split('\n');
    const out = [];
    let buffer = [];
    let fence = null;
    const flush = () => {
      if (buffer.length) out.push(protectInline(buffer.join('\n'), store));
      buffer = [];
    };
    for (const line of lines) {
      if (fence) {
        out.push(line);
        const m = /^\s*(`{3,}|~{3,})\s*$/.exec(line);
        if (m && m[1][0] === fence[0] && m[1].length >= fence.length) fence = null;
        continue;
      }
      const open = /^\s*(`{3,}|~{3,})/.exec(line);
      if (open) {
        flush();
        fence = open[1];
        out.push(line);
        continue;
      }
      buffer.push(line);
    }
    flush();
    return out.join('\n');
  }

  function placeholder(store, tex, display) {
    store.push({ tex, display });
    return PH_OPEN + (store.length - 1) + PH_CLOSE;
  }

  function protectInline(text, store) {
    let res = '';
    let i = 0;
    const n = text.length;
    while (i < n) {
      const c = text[i];

      if (c === '\\') {
        const nx = text[i + 1];
        if (nx === '[' || nx === '(') {
          const close = nx === '[' ? '\\]' : '\\)';
          const end = text.indexOf(close, i + 2);
          if (end !== -1) {
            res += placeholder(store, text.slice(i + 2, end), nx === '[');
            i = end + 2;
            continue;
          }
        }
        if (text.startsWith('\\begin{', i)) {
          const m = /^\\begin\{([a-zA-Z]+)(\*?)\}/.exec(text.slice(i, i + 40));
          if (m && MATH_ENVS.has(m[1])) {
            const endTag = `\\end{${m[1]}${m[2]}}`;
            const end = text.indexOf(endTag, i);
            if (end !== -1) {
              res += placeholder(store, text.slice(i, end + endTag.length), true);
              i = end + endTag.length;
              continue;
            }
          }
        }
        res += c + (nx ?? '');
        i += 2;
        continue;
      }

      if (c === '`') {
        let j = i;
        while (text[j] === '`') j++;
        const ticks = text.slice(i, j);
        let k = text.indexOf(ticks, j);
        while (k !== -1 && text[k + ticks.length] === '`') k = text.indexOf(ticks, k + ticks.length + 1);
        if (k !== -1) {
          res += text.slice(i, k + ticks.length);
          i = k + ticks.length;
        } else {
          res += ticks;
          i = j;
        }
        continue;
      }

      if (c === '$') {
        if (text[i + 1] === '$') {
          const end = text.indexOf('$$', i + 2);
          if (end !== -1) {
            res += placeholder(store, text.slice(i + 2, end), true);
            i = end + 2;
          } else {
            res += '$$';
            i += 2;
          }
          continue;
        }
        const next = text[i + 1];
        if (next && !/\s/.test(next)) {
          let j = i + 1;
          while (j < n) {
            const cj = text[j];
            if (cj === '\\') { j += 2; continue; }
            if (cj === '\n' && text[j + 1] === '\n') { j = n; break; }
            if (cj === '$') break;
            j++;
          }
          if (j < n && text[j] === '$' && !/\s/.test(text[j - 1]) && !/\d/.test(text[j + 1] || '')) {
            res += placeholder(store, text.slice(i + 1, j), false);
            i = j + 1;
            continue;
          }
        }
        res += c;
        i++;
        continue;
      }

      res += c;
      i++;
    }
    return res;
  }

  const mathCache = boundedCache(2000);

  function renderTex(tex, display) {
    const key = (display ? 'D:' : 'I:') + tex;
    let html = mathCache.get(key);
    if (html === undefined) {
      try {
        html = katex.renderToString(tex.trim(), {
          displayMode: display,
          throwOnError: false,
          strict: 'ignore',
          trust: false,
          output: 'htmlAndMathml',
        });
      } catch (_) {
        html = `<code class="math-error">${esc(tex)}</code>`;
      }
      mathCache.set(key, html);
    }
    return html;
  }

  // ---------------------------------------------------------------- Markdown

  const md = window.markdownit({ html: true, linkify: true, breaks: true, typographer: false });
  const highlightCache = boundedCache(400);

  function highlight(code, lang) {
    const key = lang + '\u0000' + code;
    let html = highlightCache.get(key);
    if (html === undefined) {
      html = esc(code);
      if (lang && hljs.getLanguage(lang)) {
        try { html = hljs.highlight(code, { language: lang, ignoreIllegals: true }).value; } catch (_) { /* 保持纯文本 */ }
      }
      highlightCache.set(key, html);
    }
    return html;
  }

  const ICON_COPY = '<svg class="ui-icon" viewBox="0 0 16 16" aria-hidden="true"><rect x="5.25" y="5.25" width="8.25" height="8.25" rx="1.75" fill="none" stroke="currentColor" stroke-width="1.25"/><path d="M10.5 2.75H4.25a1.5 1.5 0 0 0-1.5 1.5v6.25" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round"/></svg>';
  const ICON_EXPAND = '<svg class="ui-icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M9.5 2.75h3.75v3.75M6.5 13.25H2.75V9.5M13.25 2.75 9 7M2.75 13.25 7 9" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const ICON_CHECK = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3.5 8.5 6.5 11.5 12.5 4.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  const LANG_LABELS = { js: 'javascript', ts: 'typescript', py: 'python', sh: 'shell', zsh: 'shell', bash: 'shell', yml: 'yaml', md: 'markdown', tex: 'latex' };

  function codeBlock(code, lang, { preview = false } = {}) {
    const label = LANG_LABELS[lang] || lang || 'text';
    const actions = [
      preview ? `<button type="button" class="ghost-btn" data-action="preview">${t('预览', 'Preview')}</button>` : '',
      `<button type="button" class="icon-btn" data-action="copy-code" title="${t('复制', 'Copy')}">${ICON_COPY}</button>`,
    ].join('');
    return `<div class="code-block"><div class="code-head"><span class="code-lang">${esc(label)}</span>` +
      `<span class="code-actions">${actions}</span></div>` +
      `<pre><code class="hljs">${highlight(code, lang)}</code></pre></div>`;
  }

  function expandButton() {
    return `<button type="button" class="icon-btn figure-expand" data-action="expand-figure" title="${t('放大查看', 'Enlarge')}" aria-label="${t('放大查看', 'Enlarge')}">${ICON_EXPAND}</button>`;
  }

  md.renderer.rules.fence = (tokens, idx) => {
    const token = tokens[idx];
    const info = token.info ? md.utils.unescapeAll(token.info).trim() : '';
    const lang = (info.split(/\s+/)[0] || '').toLowerCase();
    const code = token.content.replace(/\n$/, '');

    if (lang === 'mermaid') {
      return `<div class="mermaid-block" data-state="pending"><div class="mermaid-canvas"></div>${expandButton()}` +
        `<details class="figure-source"><summary>${t('源码', 'Source')}</summary>${codeBlock(code, 'mermaid')}</details></div>`;
    }
    const looksLikeSvg = /^\s*(<\?xml[^>]*>\s*)?<svg[\s>]/i.test(code);
    if (lang === 'svg' || (looksLikeSvg && ['', 'xml', 'html'].includes(lang))) {
      const complete = /<\/svg>\s*$/i.test(code);
      const canvas = complete
        ? `<div class="svg-canvas">${code.replace(/^\s*<\?xml[^>]*>/i, '')}</div>`
        : `<div class="svg-canvas pending"><span class="figure-hint">${t('正在绘制…', 'Drawing…')}</span></div>`;
      return `<figure class="svg-figure">${canvas}${complete ? expandButton() : ''}` +
        `<details class="figure-source"><summary>${t('源码', 'Source')}</summary>${codeBlock(code, 'xml')}</details></figure>`;
    }
    return codeBlock(code, lang, { preview: lang === 'html' });
  };

  // 链接统一交给 App 处理（外部链接用系统浏览器打开）
  const defaultLinkOpen = md.renderer.rules.link_open || ((tokens, idx, options, env, self) => self.renderToken(tokens, idx, options));
  md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
    tokens[idx].attrSet('target', '_blank');
    return defaultLinkOpen(tokens, idx, options, env, self);
  };

  // ---------------------------------------------------------------- 清洗

  const PURIFY_CONFIG = {
    FORCE_BODY: true,
    ADD_ATTR: ['target'],
    FORBID_TAGS: ['script', 'iframe', 'object', 'embed', 'form', 'link', 'meta', 'base', 'frame', 'frameset'],
    FORBID_ATTR: ['autofocus'],
  };

  // ---------------------------------------------------------------- DOM 后处理

  const NO_LINKIFY = 'code, pre, a, .katex, svg, kbd, button, summary, h1, h2, h3, h4, h5, h6, .math-error';
  const PAGE_RE = /第\s*(\d{1,4})\s*(?:[-–—~～至到]\s*(\d{1,4})\s*)?页|\b(?:[Pp]age|[Ss]lide|[Pp]\.)\s?(\d{1,4})\b/g;

  function textNodes(root, rejectSelector) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const parent = node.parentElement;
        if (rejectSelector && parent && parent.closest(rejectSelector)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    return nodes;
  }

  function linkifyPages(root) {
    const total = state.meta.pageCount || 0;
    if (!total) return;
    for (const node of textNodes(root, NO_LINKIFY)) {
      const text = node.nodeValue;
      PAGE_RE.lastIndex = 0;
      if (!PAGE_RE.test(text)) continue;
      PAGE_RE.lastIndex = 0;
      const frag = document.createDocumentFragment();
      let last = 0;
      let m;
      while ((m = PAGE_RE.exec(text))) {
        const page = parseInt(m[1] || m[3], 10);
        if (!page || page > total) continue;
        frag.append(text.slice(last, m.index));
        const a = document.createElement('a');
        a.className = 'page-ref';
        a.dataset.page = String(page);
        a.title = t(`跳转到第 ${page} 页`, `Go to page ${page}`);
        a.textContent = m[0];
        frag.append(a);
        last = m.index + m[0].length;
      }
      if (last === 0) continue;
      frag.append(text.slice(last));
      node.replaceWith(frag);
    }
  }

  function restoreMath(root, store) {
    for (const node of textNodes(root, null)) {
      const text = node.nodeValue;
      if (!text.includes(PH_OPEN)) continue;
      const tpl = document.createElement('template');
      tpl.innerHTML = text.split(PH_RE).map((part, i) => {
        if (i % 2 === 0) return esc(part);
        const item = store[+part];
        return item ? renderTex(item.tex, item.display) : '';
      }).join('');
      node.replaceWith(tpl.content);
    }
    // 落在属性（如图片 alt）里的占位符还原为原始 TeX
    for (const el of root.querySelectorAll('[alt], [title]')) {
      for (const attr of ['alt', 'title']) {
        const v = el.getAttribute(attr);
        if (v && v.includes(PH_OPEN)) el.setAttribute(attr, v.replace(PH_RE, (_, i) => store[+i]?.tex ?? ''));
      }
    }
  }

  // SVG 统一转换为 <img>：样式与脚本被完全隔离，不会影响页面
  function isolateSvgs(root) {
    for (const svg of Array.from(root.querySelectorAll('svg'))) {
      if (svg.parentElement && svg.parentElement.closest('svg')) continue;
      // 代码块、图表按钮上的界面图标保持内联，才能跟随文字颜色
      if (svg.classList.contains('ui-icon') && svg.parentElement && svg.parentElement.matches('button[data-action]')) {
        svg.querySelectorAll('style').forEach((style) => style.remove());
        continue;
      }
      if (!svg.getAttribute('xmlns')) svg.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
      const width = svg.getAttribute('width');
      const viewBox = (svg.getAttribute('viewBox') || '').trim().split(/[\s,]+/).map(Number);
      const img = document.createElement('img');
      img.className = 'svg-image';
      img.alt = 'SVG';
      img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg.outerHTML);
      if (!width || /%$/.test(width)) {
        // 没有固定宽度：按 viewBox 的自然尺寸显示（不超过容器宽度）
        img.style.width = viewBox.length === 4 && viewBox[2] > 0 ? `${Math.max(viewBox[2], 240)}px` : '100%';
      }
      if (!svg.closest('.svg-canvas')) {
        const wrap = document.createElement('span');
        wrap.className = 'svg-inline';
        wrap.append(img);
        svg.replaceWith(wrap);
      } else {
        svg.replaceWith(img);
      }
    }
    // SVG 之外的 <style> 一律移除
    for (const style of Array.from(root.querySelectorAll('style'))) style.remove();
  }

  function wrapTables(root) {
    for (const table of Array.from(root.querySelectorAll('table'))) {
      if (table.parentElement && table.parentElement.classList.contains('table-wrap')) continue;
      const wrap = document.createElement('div');
      wrap.className = 'table-wrap';
      table.replaceWith(wrap);
      wrap.append(table);
    }
  }

  function renderMarkdown(src, { pageLinks = true } = {}) {
    const store = [];
    const protectedSrc = protectMath(String(src || '').replace(/\r\n?/g, '\n'), store);
    const html = DOMPurify.sanitize(md.render(protectedSrc), PURIFY_CONFIG);
    const tpl = document.createElement('template');
    tpl.innerHTML = html;
    const root = tpl.content;
    isolateSvgs(root);
    wrapTables(root);
    if (pageLinks) linkifyPages(root);
    restoreMath(root, store);
    applyCachedMermaid(root);
    return root;
  }

  // ---------------------------------------------------------------- Mermaid（按需加载）

  const mermaidCache = boundedCache(100);
  let mermaidLoader = null;
  let mermaidSeq = 0;

  function mermaidTheme() { return prefersDark.matches ? 'dark' : 'default'; }

  function loadMermaid() {
    if (!mermaidLoader) {
      mermaidLoader = new Promise((resolve, reject) => {
        const s = document.createElement('script');
        s.src = 'vendor/mermaid.min.js';
        s.onload = () => resolve(window.mermaid);
        s.onerror = () => reject(new Error('Mermaid failed to load'));
        document.head.append(s);
      });
    }
    return mermaidLoader;
  }

  function mermaidSource(block) {
    const code = block.querySelector('.figure-source code');
    return code ? code.textContent : '';
  }

  function applyCachedMermaid(root) {
    for (const block of root.querySelectorAll('.mermaid-block')) {
      const cached = mermaidCache.get(mermaidTheme() + '\u0000' + mermaidSource(block));
      if (cached) {
        block.querySelector('.mermaid-canvas').innerHTML = cached;
        block.dataset.state = 'done';
      }
    }
  }

  async function renderMermaidIn(root, streaming) {
    const blocks = Array.from(root.querySelectorAll('.mermaid-block[data-state="pending"]'));
    if (!blocks.length) return;
    if (streaming) {
      for (const b of blocks) b.querySelector('.mermaid-canvas').innerHTML = `<span class="figure-hint">${t('回答完成后绘制图表…', 'Diagram renders when the answer finishes…')}</span>`;
      return;
    }
    let mermaid;
    try {
      mermaid = await loadMermaid();
    } catch (e) {
      for (const b of blocks) b.querySelector('.mermaid-canvas').innerHTML = `<span class="figure-hint error">${esc(e.message)}</span>`;
      return;
    }
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: mermaidTheme(),
      fontFamily: '-apple-system, "PingFang SC", sans-serif',
    });
    for (const block of blocks) {
      const source = mermaidSource(block);
      const canvas = block.querySelector('.mermaid-canvas');
      try {
        const { svg } = await mermaid.render(`mmd-${++mermaidSeq}`, source);
        mermaidCache.set(mermaidTheme() + '\u0000' + source, svg);
        canvas.innerHTML = svg;
        block.dataset.state = 'done';
      } catch (e) {
        canvas.innerHTML = `<span class="figure-hint error">${t('图表语法有误：', 'Diagram error: ')}${esc(String(e.message || e).split('\n')[0])}</span>`;
        block.dataset.state = 'error';
        block.querySelector('.figure-source').open = true;
      }
      document.querySelectorAll('body > [id^="dmmd-"], body > [id^="mmd-"]').forEach((n) => n.remove());
    }
  }

  // ---------------------------------------------------------------- 消息渲染

  const $thread = document.getElementById('thread');
  const $empty = document.getElementById('empty');

  // 公式优先在运算符处换行；矩阵等无法断行的内容缩放到可用宽度。
  // 面板缩放、流式更新与字体加载后重新测量，避免裁掉公式或横向滚动。
  let mathLayoutQueued = false;
  function scheduleMathLayout() {
    if (mathLayoutQueued) return;
    mathLayoutQueued = true;
    requestAnimationFrame(() => {
      mathLayoutQueued = false;
      const formulas = Array.from($thread.querySelectorAll('.katex'));
      for (const formula of formulas) formula.style.zoom = '1';
      const scales = formulas.map((formula) => {
        const container = formula.closest('.katex-display, td, th, p, li, .md');
        if (!container || !container.clientWidth) return 1;
        const style = getComputedStyle(container);
        const available = container.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
        const width = Math.max(formula.scrollWidth, formula.getBoundingClientRect().width);
        return width > 0 && available > 0 ? Math.min(1, available / width) : 1;
      });
      formulas.forEach((formula, index) => { formula.style.zoom = String(scales[index]); });
    });
  }
  new ResizeObserver(scheduleMathLayout).observe($thread);
  new MutationObserver(scheduleMathLayout).observe($thread, { childList: true, subtree: true });
  document.fonts.addEventListener('loadingdone', scheduleMathLayout);

  const state = {
    meta: { title: '', pageCount: 0, currentPage: 0, hasDocument: false, hasKey: true },
    entries: new Map(),
    pending: new Map(),
    flushTimer: 0,
    stickToBottom: true,
    animate: false,
  };

  const ICONS = {
    page: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 1.5h5.2L12.5 4.8V14a.5.5 0 0 1-.5.5H4a.5.5 0 0 1-.5-.5V2a.5.5 0 0 1 .5-.5Z" fill="none" stroke="currentColor" stroke-width="1.2"/><path d="M9 1.8V5h3.2" fill="none" stroke="currentColor" stroke-width="1.2"/></svg>',
    auto: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.5 9.4 6 14 7.5 9.4 9 8 13.5 6.6 9 2 7.5 6.6 6Z" fill="currentColor"/></svg>',
    copy: ICON_COPY,
    retry: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M13 8a5 5 0 1 1-1.6-3.7M13 2.5v3h-3" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  };

  function splitThink(m) {
    let content = m.content || '';
    let reasoning = m.reasoning || '';
    const think = /^\s*<think>([\s\S]*?)(?:<\/think>|$)/.exec(content);
    if (think) {
      reasoning = (reasoning ? reasoning + '\n' : '') + think[1].trim();
      content = content.slice(think[0].length);
    }
    return { content, reasoning };
  }

  function formatTokens(n) {
    if (n == null) return '';
    return n >= 1000 ? (n / 1000).toFixed(n >= 100000 ? 0 : 1) + 'k' : String(n);
  }

  function renderUser(entry, m) {
    const meta = [];
    if (m.page) meta.push(`<a data-page="${m.page}">${t(`第 ${m.page} 页`, `Page ${m.page}`)}</a>`);
    if (m.auto) meta.push(`<span>${t('自动讲解', 'Auto')}</span>`);
    entry.el.innerHTML =
      '<div class="user-wrap"><div class="bubble">' +
      (m.selection ? `<div class="selection-quote">${esc(m.selection)}</div>` : '') +
      '<div class="md bubble-text"></div></div>' +
      (meta.length ? `<div class="msg-meta">${meta.join('<span class="dot">·</span>')}</div>` : '') +
      '</div>';
    entry.el.querySelector('.bubble-text').replaceChildren(renderMarkdown(m.content, { pageLinks: false }));
  }

  function buildAssistant(entry) {
    entry.el.innerHTML =
      `<details class="reasoning" hidden><summary><span class="reasoning-label">${t('思考过程', 'Thinking')}</span></summary><div class="reasoning-body"></div></details>` +
      '<div class="md content"></div>' +
      '<div class="msg-error" hidden></div>' +
      '<footer class="msg-foot" hidden></footer>';
    const details = entry.el.querySelector('.reasoning');
    details.querySelector('summary').addEventListener('click', () => { entry.userToggledReasoning = true; });
  }

  function renderAssistant(entry, m) {
    if (!entry.built) {
      buildAssistant(entry);
      entry.built = true;
    }
    const el = entry.el;
    const { content, reasoning } = splitThink(m);
    const thinking = m.streaming && !content.trim();
    const prev = entry.rendered || {};

    // 思考过程
    const details = el.querySelector('.reasoning');
    if (reasoning.trim()) {
      details.hidden = false;
      if (reasoning !== prev.reasoning) el.querySelector('.reasoning-body').textContent = reasoning.trim();
      el.querySelector('.reasoning-label').textContent = thinking ? t('正在思考…', 'Thinking…') : t('思考过程', 'Thinking');
      details.classList.toggle('live', thinking);
      if (!entry.userToggledReasoning) details.open = thinking;
    } else {
      details.hidden = true;
    }

    // 正文
    const body = el.querySelector('.content');
    if (content !== prev.content || m.streaming !== prev.streaming) {
      const frag = renderMarkdown(content);
      if (m.streaming) {
        if (!content.trim() && !reasoning.trim()) {
          const dots = document.createElement('div');
          dots.className = 'typing';
          dots.innerHTML = '<span></span><span></span><span></span>';
          frag.append(dots);
        } else if (content.trim()) {
          const caret = document.createElement('span');
          caret.className = 'caret';
          const last = frag.lastElementChild;
          if (last && /^(P|LI|H[1-6])$/.test(last.tagName)) last.append(caret);
          else if (last && /^(UL|OL)$/.test(last.tagName) && last.lastElementChild) last.lastElementChild.append(caret);
          else frag.append(caret);
        }
      }
      body.replaceChildren(frag);
      body.hidden = !content.trim() && !m.streaming;
      renderMermaidIn(body, m.streaming);
    }

    // 错误
    const err = el.querySelector('.msg-error');
    if (m.error) {
      err.hidden = false;
      err.innerHTML = `<div class="error-text">${esc(m.error)}</div><button type="button" class="ghost-btn" data-action="retry">${ICONS.retry}${t('重试', 'Retry')}</button>`;
    } else {
      err.hidden = true;
    }

    // 底部操作
    const foot = el.querySelector('.msg-foot');
    if (!m.streaming && content.trim()) {
      const usage = [
        m.model ? esc(m.model) : '',
        m.usage ? `${t('输入', 'In')} ${formatTokens(m.usage.prompt)}` : '',
        m.usage && m.usage.cacheHit ? `${t('缓存', 'Cached')} ${formatTokens(m.usage.cacheHit)}` : '',
        m.usage ? `${t('输出', 'Out')} ${formatTokens(m.usage.completion)}` : '',
      ].filter(Boolean).join(' · ');
      foot.hidden = false;
      foot.innerHTML =
        `<button type="button" class="icon-btn" data-action="copy-message" title="${t('复制', 'Copy')}">${ICONS.copy}</button>` +
        `<button type="button" class="icon-btn regenerate" data-action="regenerate" title="${t('重新生成', 'Regenerate')}">${ICONS.retry}</button>` +
        (m.stopped ? `<span class="tag">${t('已停止', 'Stopped')}</span>` : '') +
        (usage ? `<span class="usage">${usage}</span>` : '');
    } else {
      foot.hidden = true;
    }

    entry.rendered = { content, reasoning, streaming: m.streaming };
  }

  function renderEntry(m) {
    let entry = state.entries.get(m.id);
    if (!entry) {
      const el = document.createElement('article');
      el.className = `msg ${m.role}${state.animate ? ' enter' : ''}`;
      el.dataset.id = m.id;
      entry = { el, data: m };
      state.entries.set(m.id, entry);
      $thread.append(el);
    }
    entry.data = m;
    if (m.role === 'user') {
      if (!entry.rendered || entry.rendered.content !== m.content) {
        renderUser(entry, m);
        entry.rendered = { content: m.content };
      }
      return;
    }
    const full = m.content || '';
    if (state.animate && !reduceMotion.matches && (m.streaming || entry.revealing)) {
      entry.shown = Math.min(entry.shown ?? 0, full.length);
      entry.revealing = true;
      renderAssistant(entry, liveView(entry));
      startReveal();
    } else {
      entry.shown = full.length;
      entry.revealing = false;
      renderAssistant(entry, m);
    }
  }

  // ---------------------------------------------------------------- 平滑显示
  // 网络按块到达，这里按帧逐步显示：积压越多走得越快，结束后迅速追平。

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const reveal = { running: false, lastRender: 0 };

  function liveView(entry) {
    const full = entry.data.content || '';
    return Object.assign({}, entry.data, {
      content: full.slice(0, entry.shown),
      streaming: entry.data.streaming || entry.shown < full.length,
    });
  }

  function startReveal() {
    if (reveal.running) return;
    reveal.running = true;
    requestAnimationFrame(revealTick);
  }

  function revealTick(now) {
    const due = now - reveal.lastRender >= 30;
    const stick = isNearBottom();
    let active = false;
    for (const entry of state.entries.values()) {
      if (!entry.revealing) continue;
      const full = entry.data.content || '';
      const backlog = full.length - entry.shown;
      if (backlog > 0) {
        let next = Math.min(full.length, entry.shown + Math.max(1, Math.ceil(backlog / (entry.data.streaming ? 16 : 5))));
        const code = full.charCodeAt(next - 1);
        if (code >= 0xd800 && code <= 0xdbff && next < full.length) next += 1;
        entry.shown = next;
      }
      if (!entry.data.streaming && entry.shown >= full.length) {
        entry.revealing = false;
        renderAssistant(entry, entry.data);
      } else {
        if (due) renderAssistant(entry, liveView(entry));
        active = true;
      }
    }
    if (due) reveal.lastRender = now;
    if (stick) scrollToBottom();
    updateJumpButton();
    if (active) requestAnimationFrame(revealTick);
    else reveal.running = false;
  }

  // ---------------------------------------------------------------- 滚动

  const $jump = document.getElementById('jump');

  function distanceToBottom() {
    const doc = document.scrollingElement;
    return doc.scrollHeight - doc.scrollTop - window.innerHeight;
  }

  function isNearBottom() {
    return distanceToBottom() < 100;
  }

  function scrollToBottom() {
    const doc = document.scrollingElement;
    doc.scrollTop = doc.scrollHeight;
  }

  function smoothScrollToBottom() {
    window.scrollTo({ top: document.scrollingElement.scrollHeight, behavior: reduceMotion.matches ? 'auto' : 'smooth' });
  }

  function updateJumpButton() {
    $jump.classList.toggle('visible', state.entries.size > 0 && distanceToBottom() > 240);
  }

  let scrollQueued = false;
  window.addEventListener('scroll', () => {
    if (scrollQueued) return;
    scrollQueued = true;
    requestAnimationFrame(() => { scrollQueued = false; updateJumpButton(); });
  }, { passive: true });

  $jump.addEventListener('click', smoothScrollToBottom);

  function scheduleFlush() {
    if (state.flushTimer) return;
    state.flushTimer = setTimeout(flush, 16);
  }

  function flush() {
    state.flushTimer = 0;
    const forced = state.stickToBottom;
    const stick = forced || isNearBottom();
    for (const m of state.pending.values()) renderEntry(m);
    state.pending.clear();
    updateEmpty();
    if (forced) smoothScrollToBottom();
    else if (stick) scrollToBottom();
    state.stickToBottom = false;
    updateJumpButton();
  }

  // ---------------------------------------------------------------- 空状态

  const SUGGESTIONS = [
    { action: 'explainPage', title: () => t('讲解本页', 'Explain page'), icon: 'M8 1.8 9.3 6.1 13.6 7.5 9.3 8.9 8 13.2 6.7 8.9 2.4 7.5 6.7 6.1Z' },
    { action: 'summary', title: () => t('总结课件', 'Summarize'), icon: 'M3 4h10M3 8h10M3 12h6' },
    { action: 'outline', title: () => t('知识框架', 'Concept map'), icon: 'M4 4h3v3H4zM9 9h3v3H9zM5.5 7v3.5H9' },
    { action: 'quiz', title: () => t('练习题', 'Quiz me'), icon: 'M3.5 8.5 6 11l6.5-6.5' },
  ];

  const suggestionIcon = (d) => `<svg viewBox="0 0 16 16" aria-hidden="true"><path d="${d}" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

  let emptyHTML = '';

  function updateEmpty() {
    const isEmpty = state.entries.size === 0;
    $empty.hidden = !isEmpty;
    document.body.classList.toggle('is-empty', isEmpty);
    if (!isEmpty) {
      emptyHTML = '';
      return;
    }
    const html = emptyContent();
    if (html === emptyHTML) return;
    emptyHTML = html;
    $empty.innerHTML = html;
    replay($empty, 'show');
  }

  function replay(el, className) {
    el.classList.remove(className);
    void el.offsetWidth;
    el.classList.add(className);
  }

  function emptyContent() {
    const meta = state.meta;
    if (!meta.hasDocument) {
      return `<div class="empty-icon">${ICONS.auto}</div><h2>${t('AI 讲解', 'AI Tutor')}</h2><p>${t('打开一个课件开始', 'Open a deck to start')}</p>`;
    }
    return (
      `<div class="empty-icon">${ICONS.auto}</div>` +
      `<h2>${t('今天想弄懂什么？', 'What shall we learn?')}</h2>` +
      '<div class="suggestions">' +
      SUGGESTIONS.map((s) => `<button type="button" class="suggestion" data-action="quick" data-quick="${s.action}">${suggestionIcon(s.icon)}${s.title()}</button>`).join('') +
      '</div>' +
      '');
  }

  // ---------------------------------------------------------------- 图表放大

  /** 从 SVG 源码读出自然尺寸：优先 width/height（像素），否则用 viewBox。 */
  function svgSize(svg) {
    const viewBox = (svg.getAttribute('viewBox') || '').trim().split(/[\s,]+/).map(Number);
    const px = (v) => (v && /^\s*[\d.]+\s*(px)?\s*$/.test(v) ? parseFloat(v) : 0);
    let width = px(svg.getAttribute('width'));
    let height = px(svg.getAttribute('height'));
    if (viewBox.length === 4 && viewBox[2] > 0 && viewBox[3] > 0) {
      if (!width && !height) { width = viewBox[2]; height = viewBox[3]; }
      else if (!height) height = width * viewBox[3] / viewBox[2];
      else if (!width) width = height * viewBox[2] / viewBox[3];
    }
    return { width: width || 0, height: height || 0 };
  }

  function figurePayload(el) {
    const block = el.closest('.svg-figure, .mermaid-block');
    if (block && block.classList.contains('mermaid-block')) {
      const svg = block.dataset.state === 'done' && block.querySelector('.mermaid-canvas > svg');
      if (!svg) return null;
      return Object.assign({ kind: 'mermaid', markup: svg.outerHTML }, svgSize(svg));
    }
    const img = el.tagName === 'IMG' ? el : el.querySelector('img');
    if (!img || !img.complete) return null;
    if (img.classList.contains('svg-image')) {
      const comma = img.src.indexOf(',');
      let markup = '';
      try { markup = decodeURIComponent(img.src.slice(comma + 1)); } catch (_) { return null; }
      const doc = new DOMParser().parseFromString(markup, 'image/svg+xml');
      const svg = doc.documentElement;
      if (!svg || svg.nodeName.toLowerCase() !== 'svg') return null;
      return Object.assign({ kind: 'svg', src: img.src }, svgSize(svg));
    }
    return { kind: 'image', src: img.currentSrc || img.src, width: img.naturalWidth, height: img.naturalHeight };
  }

  function openFigure(el) {
    const payload = el && figurePayload(el);
    if (!payload) return;
    post(Object.assign({ type: 'figure', title: state.meta.title || '', lang: state.meta.lang || 'zh', dark: prefersDark.matches }, payload));
  }

  // ---------------------------------------------------------------- 交互

  function flashButton(btn) {
    const original = btn.innerHTML;
    btn.innerHTML = ICON_CHECK;
    btn.classList.add('done');
    btn.disabled = true;
    setTimeout(() => { btn.innerHTML = original; btn.classList.remove('done'); btn.disabled = false; }, 1200);
  }

  document.addEventListener('click', (e) => {
    const pageLink = e.target.closest('[data-page]');
    if (pageLink) {
      e.preventDefault();
      post({ type: 'gotoPage', page: parseInt(pageLink.dataset.page, 10) });
      return;
    }

    const quote = e.target.closest('.selection-quote');
    if (quote) {
      quote.classList.toggle('expanded');
      return;
    }

    const btn = e.target.closest('[data-action]');
    if (!btn) {
      const figure = e.target.closest('.svg-canvas, .mermaid-block[data-state="done"] .mermaid-canvas, .md img');
      if (figure && window.getSelection().isCollapsed) openFigure(figure);
      return;
    }
    const article = btn.closest('.msg');
    const id = article && article.dataset.id;
    switch (btn.dataset.action) {
      case 'copy-code': {
        const code = btn.closest('.code-block').querySelector('pre code');
        post({ type: 'copy', text: code.textContent });
        flashButton(btn);
        break;
      }
      case 'copy-message': {
        const entry = state.entries.get(id);
        if (entry) post({ type: 'copy', text: splitThink(entry.data).content.trim() });
        flashButton(btn);
        break;
      }
      case 'preview': {
        const block = btn.closest('.code-block');
        let frame = block.querySelector('iframe');
        if (frame) {
          frame.remove();
          btn.textContent = t('预览', 'Preview');
        } else {
          frame = document.createElement('iframe');
          frame.className = 'html-preview';
          frame.setAttribute('sandbox', 'allow-scripts');
          frame.srcdoc = block.querySelector('pre code').textContent;
          block.append(frame);
          btn.textContent = t('收起', 'Hide');
        }
        break;
      }
      case 'expand-figure':
        openFigure(btn.closest('.svg-figure, .mermaid-block'));
        break;
      case 'retry':
        post({ type: 'retry', id });
        break;
      case 'regenerate':
        post({ type: 'regenerate', id });
        break;
      case 'quick':
        post({ type: 'quick', action: btn.dataset.quick });
        break;
      default:
        break;
    }
  });

  // 右键：交给 App 弹出与界面统一的菜单
  document.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    const link = e.target.closest('a[href]');
    const pageRef = e.target.closest('[data-page]');
    const msg = e.target.closest('.msg');
    post({
      type: 'contextmenu',
      x: e.clientX,
      y: e.clientY,
      selection: String(window.getSelection() || '').trim(),
      link: link && !pageRef ? link.href : null,
      id: msg ? msg.dataset.id : null,
      role: msg ? (msg.classList.contains('assistant') ? 'assistant' : 'user') : null,
      page: pageRef ? parseInt(pageRef.dataset.page, 10) : null,
    });
  });

  prefersDark.addEventListener('change', () => {
    for (const entry of state.entries.values()) {
      if (entry.data.role === 'assistant') {
        entry.rendered = null;
        renderAssistant(entry, entry.data);
      }
    }
  });

  function applyMeta() {
    if (state.meta.fontSize) document.documentElement.style.setProperty('--font-size', `${state.meta.fontSize}px`);
    document.body.classList.toggle('serif', !!state.meta.serif);
    document.documentElement.lang = state.meta.lang === 'en' ? 'en' : 'zh-CN';
    scheduleMathLayout();
  }

  // ---------------------------------------------------------------- 对外接口

  window.PPT = {
    reset(payload) {
      clearTimeout(state.flushTimer);
      state.flushTimer = 0;
      state.pending.clear();
      state.entries.clear();
      $thread.replaceChildren();
      if (payload.meta) state.meta = Object.assign(state.meta, payload.meta);
      applyMeta();
      state.animate = false;
      for (const m of payload.messages || []) renderEntry(m);
      state.animate = true;
      emptyHTML = '';
      updateEmpty();
      scrollToBottom();
      replay($thread, 'fade');
      updateJumpButton();
    },
    upsert(m, { scroll = false } = {}) {
      state.pending.set(m.id, m);
      if (scroll) state.stickToBottom = true;
      scheduleFlush();
    },
    remove(id) {
      state.pending.delete(id);
      const entry = state.entries.get(id);
      if (entry) {
        state.entries.delete(id);
        entry.el.classList.add('leaving');
        setTimeout(() => {
          entry.el.remove();
          updateEmpty();
        }, reduceMotion.matches ? 0 : 180);
      } else {
        updateEmpty();
      }
    },
    setMeta(meta) {
      state.meta = Object.assign(state.meta, meta);
      applyMeta();
      if (state.entries.size === 0) updateEmpty();
    },
    scrollToBottom,
    renderMarkdown, // 便于调试
  };

  updateEmpty();
  post({ type: 'ready' });
})();
