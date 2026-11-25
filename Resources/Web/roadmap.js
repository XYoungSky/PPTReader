// 课件学习路线图：从左到右的大纲树，突出还没碰过的部分。
//
// 原生端调用：
//   Roadmap.show({ lang, title, pageCount, outline, touched, current })
//     outline: [{ title, pages: [start, end], children: [...] }]，页码从 1 开始，含首尾
//     touched: 碰过的页码数组；current: 当前页
//   Roadmap.setProgress({ touched, current })   对话或翻页后更新进度，不重建大纲
// 发回原生端（messageHandlers.roadmap）：{ type: 'goto', page } / { type: 'regenerate' }
//
// 直接在浏览器里打开（没有原生端）时显示一份示例课件，用作视觉稿。
(() => {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const $header = $('header');
  const $title = $('title');
  const $meta = $('meta');
  const $remaining = $('remaining');
  const $strip = $('strip');
  const $tree = $('tree');
  const $links = $('links');
  const $tip = $('tip');
  const $status = $('status');
  const $summary = document.querySelector('.summary-row');
  const $toast = $('toast');
  const SVG = 'http://www.w3.org/2000/svg';

  // 布局：列间距、同级之间的间距（按层级）、左右留白
  const GAP_X = 52;
  const SIBLING_GAP = [22, 12, 7];
  const PAD_X = 32;
  const PAD_TOP = 14;

  let lang = 'zh';
  const t = (zh, en) => (lang === 'en' ? en : zh);

  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.roadmap;

  let data = null;          // { title, pageCount, roots }
  let touched = new Set();
  let current = 0;
  const collapsed = new Set();
  const elements = new Map(); // 节点 id → DOM
  let firstRender = true;

  // ---------- 数据 ----------

  /** 整理大纲：补上 id、层级，页码范围限制在课件内，父节点的范围至少覆盖子节点。 */
  function prepare(list, depth = 0, prefix = '') {
    return (Array.isArray(list) ? list : []).map((item, index) => {
      const id = prefix + index;
      const children = depth < 2 ? prepare(item.children, depth + 1, id + '.') : [];
      let [start, end] = Array.isArray(item.pages) ? item.pages : [];
      start = clampPage(start);
      end = clampPage(end ?? start);
      for (const child of children) {
        start = start ? Math.min(start, child.start) : child.start;
        end = end ? Math.max(end, child.end) : child.end;
      }
      if (end < start) [start, end] = [end, start];
      return { id, depth, title: String(item.title || '').trim() || '…', start, end, children };
    }).filter((node) => node.start > 0);
  }

  function clampPage(value) {
    const page = Math.round(Number(value));
    if (!Number.isFinite(page) || page < 1) return 0;
    return data ? Math.min(page, data.pageCount) : page;
  }

  function pagesOf(node) {
    const pages = [];
    for (let page = node.start; page <= node.end; page++) pages.push(page);
    return pages;
  }

  function stats(node) {
    const pages = pagesOf(node);
    const left = pages.filter((page) => !touched.has(page));
    return { total: pages.length, done: pages.length - left.length, left };
  }

  /** 大纲覆盖到的页（封面、目录这类不在大纲里的页不算“没碰过”）。 */
  function coveredPages() {
    const pages = new Set();
    const walk = (nodes) => nodes.forEach((node) => {
      pagesOf(node).forEach((page) => pages.add(page));
      walk(node.children);
    });
    walk(data.roots);
    return [...pages].sort((a, b) => a - b);
  }

  /** 当前页所在的最深一层可见节点。 */
  function currentNodeId() {
    let found = null;
    const walk = (nodes) => {
      for (const node of nodes) {
        if (current < node.start || current > node.end) continue;
        found = node.id;
        if (!collapsed.has(node.id)) walk(node.children);
        return;
      }
    };
    walk(data.roots);
    return found;
  }

  // ---------- 渲染 ----------

  function pageLabel(node) {
    return node.start === node.end ? `p.${node.start}` : `p.${node.start}–${node.end}`;
  }

  function pageList(pages) {
    // 连续的页合并成范围：14、15、16、20 → 14–16、20
    const parts = [];
    for (let i = 0; i < pages.length; i++) {
      let j = i;
      while (j + 1 < pages.length && pages[j + 1] === pages[j] + 1) j++;
      parts.push(i === j ? `${pages[i]}` : `${pages[i]}–${pages[j]}`);
      i = j;
    }
    return parts.join(t('、', ', '));
  }

  const CHECK = '<svg class="check" viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 6.4 4.9 8.7 9.5 3.6" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const CHEVRON = '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M6.2 2.4 3.6 5l2.6 2.6" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const ARROW = '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="M2.5 6h7M6.5 3l3 3-3 3" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  function esc(text) {
    return text.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  }

  function visibleNodes() {
    const list = [];
    const walk = (nodes, parent) => nodes.forEach((node) => {
      list.push({ node, parent });
      if (!collapsed.has(node.id)) walk(node.children, node);
    });
    walk(data.roots, null);
    return list;
  }

  function renderNode(node, isCurrent) {
    let el = elements.get(node.id);
    const isNew = !el;
    if (isNew) {
      el = document.createElement('div');
      el.innerHTML = '<button type="button" class="pill"></button>';
      el.dataset.id = node.id;
      elements.set(node.id, el);
      $tree.appendChild(el);
    }
    const s = stats(node);
    const state = s.left.length === 0 ? 'done' : s.done > 0 ? 'partial' : 'todo';
    const isCollapsed = collapsed.has(node.id);
    el.className = `node depth-${node.depth} ${state}` + (isCurrent ? ' current' : '') + (isCollapsed ? ' collapsed' : '')
      + (isNew && !firstRender ? ' enter' : '');

    const pill = el.firstChild;
    pill.innerHTML = (isCurrent ? '<span class="here" aria-hidden="true"></span>' : '')
      + (state === 'done' ? CHECK : '')
      + `<span class="label">${esc(node.title)}</span><span class="pages">${pageLabel(node)}</span>`
      + (state === 'partial' ? `<span class="progress" style="--progress:${(s.done / s.total * 100).toFixed(1)}%"></span>` : '');
    pill.setAttribute('aria-label', `${node.title}，${tip(node, s, true)}`);

    let toggle = el.querySelector('.toggle');
    if (node.children.length) {
      if (!toggle) {
        toggle = document.createElement('button');
        toggle.type = 'button';
        toggle.className = 'toggle';
        el.appendChild(toggle);
      }
      toggle.innerHTML = isCollapsed ? `+${node.children.length}` : CHEVRON;
      toggle.setAttribute('aria-label', isCollapsed ? t('展开', 'Expand') : t('折叠', 'Collapse'));
      toggle.setAttribute('aria-expanded', String(!isCollapsed));
    } else if (toggle) {
      toggle.remove();
    }
    return el;
  }

  function render() {
    if (!data) return;
    const covered = coveredPages();
    renderHeader(covered);

    const visible = visibleNodes();
    const keep = new Set(visible.map((v) => v.node.id));
    for (const [id, el] of elements) {
      if (!keep.has(id)) { el.remove(); elements.delete(id); }
    }
    const currentId = currentNodeId();
    const items = visible.map(({ node, parent }) => ({ node, parent, el: renderNode(node, node.id === currentId) }));

    // 量尺寸，按层级对齐成列
    const columns = [];
    for (const item of items) {
      item.w = item.el.offsetWidth;
      item.h = item.el.offsetHeight;
      columns[item.node.depth] = Math.max(columns[item.node.depth] || 0, item.w);
    }
    const colX = [PAD_X];
    for (let d = 1; d < columns.length; d++) colX[d] = colX[d - 1] + columns[d - 1] + GAP_X;

    // 纵向：叶子依次往下排，父节点放在子节点的中间
    const byId = new Map(items.map((item) => [item.node.id, item]));
    let cursor = PAD_TOP;
    const place = (nodes) => nodes.forEach((node, index) => {
      const item = byId.get(node.id);
      if (index > 0) cursor += SIBLING_GAP[node.depth] || 7;
      const kids = collapsed.has(node.id) ? [] : node.children;
      if (kids.length) {
        const top = cursor;
        place(kids);
        const first = byId.get(kids[0].id), last = byId.get(kids[kids.length - 1].id);
        item.cy = (first.cy + last.cy) / 2;
        // 父节点比子节点整体还高时（只有一个矮的子节点），往下让出空间
        const overflow = top - (item.cy - item.h / 2);
        if (overflow > 0) cursor += overflow;
      } else {
        item.cy = cursor + item.h / 2;
        cursor += item.h;
      }
      item.x = colX[node.depth];
    });
    place(data.roots);

    for (const item of items) {
      item.el.style.setProperty('--x', `${item.x}px`);
      item.el.style.setProperty('--y', `${Math.round(item.cy - item.h / 2)}px`);
    }

    // 连线：父节点胶囊右侧到子节点左侧，细贝塞尔曲线（折叠按钮浮在起点上）
    const width = colX[colX.length - 1] + columns[columns.length - 1] + PAD_X;
    const height = cursor + PAD_TOP;
    $tree.style.height = `${height}px`;
    $tree.style.minWidth = `${width}px`;
    $links.setAttribute('width', width);
    $links.setAttribute('height', height);
    const paths = [];
    for (const item of items) {
      if (!item.parent) continue;
      const parent = byId.get(item.parent.id);
      const x1 = parent.x + parent.w + 1, y1 = parent.cy;
      const x2 = item.x - 2, y2 = item.cy;
      const bend = (x2 - x1) * 0.55;
      const done = stats(item.node).left.length === 0;
      paths.push(`<path class="${done ? 'done' : ''}" d="M${x1} ${y1}C${x1 + bend} ${y1} ${x2 - bend} ${y2} ${x2} ${y2}"/>`);
    }
    $links.innerHTML = paths.join('');

    if (firstRender) {
      firstRender = false;
      const el = currentId && elements.get(currentId);
      if (el) {
        const top = el.getBoundingClientRect().top + window.scrollY - $header.offsetHeight - 80;
        window.scrollTo(0, Math.max(0, top));
      }
    }
  }

  function renderHeader(covered) {
    document.title = data.title;
    $title.textContent = data.title;
    $meta.textContent = t(`共 ${data.pageCount} 页`, `${data.pageCount} pages`);
    $('regenerate').textContent = t('重新生成', 'Regenerate');
    const legend = document.querySelectorAll('.legend span');
    [t('未覆盖', 'Not covered'), t('部分覆盖', 'Partly covered'), t('已覆盖', 'Covered')].forEach((label, i) => {
      legend[i].lastChild.textContent = label;
    });

    const left = covered.filter((page) => !touched.has(page));
    const next = nextUntouched(left);
    if (left.length === 0) {
      $remaining.className = 'all-done';
      $remaining.innerHTML = CHECK + `<span>${t('所有页面均已覆盖', 'All pages covered')}</span>`;
    } else {
      $remaining.className = '';
      $remaining.innerHTML = t(
        `还有 <span class="count">${left.length}</span> 页未覆盖<span class="next">· 下一页：第 ${next} 页</span>`,
        `<span class="count">${left.length}</span> ${left.length === 1 ? 'page' : 'pages'} not yet covered<span class="next">· next: page ${next}</span>`,
      ) + ARROW;
    }
    $remaining.dataset.page = next || '';

    // 页码条
    const inOutline = new Set(covered);
    if ($strip.childElementCount !== data.pageCount) {
      $strip.innerHTML = '';
      for (let page = 1; page <= data.pageCount; page++) {
        const tick = document.createElement('button');
        tick.type = 'button';
        tick.dataset.page = page;
        $strip.appendChild(tick);
      }
    }
    for (const tick of $strip.children) {
      const page = Number(tick.dataset.page);
      tick.className = (touched.has(page) ? 'touched' : '') + (inOutline.has(page) ? '' : ' outside')
        + (page === current ? ' current' : '');
      tick.setAttribute('aria-label', t(`第 ${page} 页`, `Page ${page}`) + (touched.has(page) ? t('，已覆盖', ', covered') : ''));
    }
  }

  /** 当前页之后的下一个没碰过的页，到末尾再从头找。 */
  function nextUntouched(left) {
    if (!left.length) return 0;
    return left.find((page) => page > current) || left[0];
  }

  // ---------- 提示 ----------

  function tip(node, s = stats(node), plain = false) {
    const range = node.start === node.end ? t(`第 ${node.start} 页`, `Page ${node.start}`) : t(`第 ${node.start}–${node.end} 页`, `Pages ${node.start}–${node.end}`);
    // 只给数字：进度，部分完成时再列出剩余的页
    let progress = t(`进度 ${s.done}/${s.total}`, `${s.done}/${s.total} covered`);
    if (s.done > 0 && s.left.length) progress += t(` · 未覆盖：第 ${pageList(s.left)} 页`, ` · not covered: ${pageList(s.left)}`);
    return plain ? `${range}，${progress}` : `<strong>${range}</strong> · ${progress}`;
  }

  function showTip(el) {
    const node = findNode(el.dataset.id);
    if (!node) return;
    $tip.innerHTML = tip(node);
    const rect = el.firstChild.getBoundingClientRect();
    const tipRect = $tip.getBoundingClientRect();
    let top = rect.bottom + 8;
    if (top + tipRect.height > window.innerHeight - 8) top = rect.top - tipRect.height - 8;
    $tip.style.left = `${Math.min(rect.left, window.innerWidth - tipRect.width - 8)}px`;
    $tip.style.top = `${top}px`;
    $tip.classList.add('visible');
  }

  function hideTip() { $tip.classList.remove('visible'); }

  function findNode(id) {
    let found = null;
    const walk = (nodes) => nodes.some((node) => (node.id === id ? (found = node) : walk(node.children)));
    if (data) walk(data.roots);
    return found;
  }

  let toastTimer = 0;
  function toast(text) {
    $toast.textContent = text;
    $toast.classList.add('visible');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => $toast.classList.remove('visible'), 1400);
  }

  // ---------- 交互 ----------

  function post(message) {
    if (handler) handler.postMessage(message);
    else if (message.type === 'goto') toast(t(`跳到第 ${message.page} 页`, `Go to page ${message.page}`));
    else toast(t('重新生成大纲', 'Regenerate outline'));
  }

  function goto(page) {
    if (page > 0) post({ type: 'goto', page });
  }

  $tree.addEventListener('click', (e) => {
    const el = e.target.closest('.node');
    if (!el) return;
    const node = findNode(el.dataset.id);
    if (!node) return;
    if (e.target.closest('.toggle')) {
      if (collapsed.has(node.id)) collapsed.delete(node.id); else collapsed.add(node.id);
      hideTip();
      render();
      return;
    }
    // 跳到这块里第一个没碰过的页；都碰过了就跳到开头
    goto(stats(node).left[0] || node.start);
  });

  $tree.addEventListener('mouseover', (e) => {
    const pill = e.target.closest('.pill');
    if (pill) showTip(pill.parentElement);
  });
  $tree.addEventListener('mouseout', (e) => {
    if (e.target.closest('.pill') && !e.relatedTarget?.closest?.('.pill')) hideTip();
  });

  $remaining.addEventListener('click', () => goto(Number($remaining.dataset.page)));
  $strip.addEventListener('click', (e) => {
    const tick = e.target.closest('button');
    if (tick) goto(Number(tick.dataset.page));
  });
  $('regenerate').addEventListener('click', () => post({ type: 'regenerate' }));
  $('status-action').addEventListener('click', () => post({ type: 'generate' }));

  window.addEventListener('scroll', () => $header.classList.toggle('scrolled', window.scrollY > 4), { passive: true });
  document.addEventListener('contextmenu', (e) => e.preventDefault());

  // ---------- 对外接口 ----------

  function setLang(value) {
    lang = value === 'en' ? 'en' : 'zh';
    document.documentElement.lang = lang === 'en' ? 'en' : 'zh-CN';
  }

  /** 切换“大纲”和“状态”两种显示。 */
  function setMode(showingOutline) {
    $status.hidden = showingOutline;
    $summary.hidden = !showingOutline;
    $strip.hidden = !showingOutline;
    $('regenerate').hidden = !showingOutline;
    $tree.hidden = !showingOutline;
  }

  window.Roadmap = {
    show(payload) {
      setLang(payload.lang);
      setMode(true);
      data = { title: String(payload.title || ''), pageCount: Math.max(1, Number(payload.pageCount) || 1), roots: [] };
      data.roots = prepare(payload.outline);
      touched = new Set(payload.touched || []);
      current = Number(payload.current) || 0;
      collapsed.clear();
      elements.forEach((el) => el.remove());
      elements.clear();
      firstRender = true;
      render();
    },
    setProgress(payload) {
      if (!data || !$status.hidden) return;
      touched = new Set(payload.touched || []);
      current = Number(payload.current) || current;
      render();
    },
    /** state: loading（生成中）/ error / empty（还没有路线图）/ noDeck（没有打开课件）。 */
    showStatus(payload) {
      setLang(payload.lang);
      setMode(false);
      hideTip();
      data = null;
      elements.forEach((el) => el.remove());
      elements.clear();
      $links.innerHTML = '';
      const title = String(payload.title || '');
      document.title = title || t('学习路线图', 'Study Roadmap');
      $title.textContent = title || t('学习路线图', 'Study Roadmap');
      $meta.textContent = payload.pageCount ? t(`共 ${payload.pageCount} 页`, `${payload.pageCount} pages`) : '';
      $status.className = payload.state || 'loading';
      $('status-text').textContent = payload.message || '';
      const $action = $('status-action');
      $action.hidden = !payload.action;
      $action.textContent = payload.action || '';
    },
  };

  if (handler) {
    document.body.classList.add('in-app');
    post({ type: 'ready' });
  }

  // ---------- 视觉稿：示例课件 ----------

  if (!handler) {
    const p = (title, start, end = start, children = []) => ({ title, pages: [start, end], children });
    const touchedPages = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15, 18, 19, 20, 21];
    window.Roadmap.show({
      lang: new URLSearchParams(location.search).get('lang') || 'zh',
      title: '操作系统 · 第 4 章 进程与线程',
      pageCount: 38,
      current: 21,
      touched: touchedPages,
      outline: [
        p('进程的概念', 2, 9, [
          p('什么是进程', 2, 4, [p('程序与进程', 2), p('进程的组成', 3), p('进程控制块 PCB', 4)]),
          p('进程状态', 5, 7, [p('三态模型', 5), p('五态模型', 6), p('状态转换', 7)]),
          p('进程控制', 8, 9, [p('创建与终止', 8), p('fork 与 exec', 9)]),
        ]),
        p('线程', 10, 17, [
          p('为什么需要线程', 10, 11, [p('并发与开销', 10), p('线程与进程的对比', 11)]),
          p('线程模型', 12, 14, [p('用户级线程', 12), p('内核级线程', 13), p('多对多模型', 14)]),
          p('线程库', 15, 17, [p('Pthreads', 15), p('Java 线程', 16), p('隐式线程与线程池', 17)]),
        ]),
        p('CPU 调度', 18, 28, [
          p('调度准则', 18, 19, [p('周转时间与等待时间', 18), p('响应时间', 19)]),
          p('调度算法', 20, 25, [p('先来先服务 FCFS', 20), p('短作业优先 SJF', 21, 22), p('优先级调度', 23), p('时间片轮转', 24, 25)]),
          p('多处理器调度', 26, 28, [p('负载均衡', 26), p('处理器亲和性', 27), p('实时调度', 28)]),
        ]),
        p('进程同步', 29, 37, [
          p('临界区问题', 29, 31, [p('竞争条件', 29), p('Peterson 算法', 30, 31)]),
          p('同步工具', 32, 35, [p('互斥锁', 32), p('信号量', 33, 34), p('管程', 35)]),
          p('经典同步问题', 36, 37, [p('生产者-消费者', 36), p('哲学家就餐', 37)]),
        ]),
        p('本章小结', 38),
      ],
    });
  }
})();
