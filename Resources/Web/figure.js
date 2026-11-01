/*
 * 图表放大预览：缩放（捏合、⌘ 滚轮、按钮、键盘）、拖动平移、双击切换适合窗口 / 放大。
 * Swift 通过 window.Figure 传入图表；导出图片时由 Swift 截取卡片区域。
 */
(() => {
  'use strict';

  function post(message) {
    try {
      window.webkit.messageHandlers.figure.postMessage(message);
    } catch (_) {
      console.log('[figure]', message);
    }
  }

  const $stage = document.getElementById('stage');
  const $card = document.getElementById('card');
  const $label = document.getElementById('zoom-label');
  const $toolbar = document.getElementById('toolbar');
  const $toast = document.getElementById('toast');
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  /** 卡片内边距（自然尺寸下），四周留白与工具条占用的高度。 */
  const PAD = 24;
  const MARGIN = 32;
  const TOP = 44;
  const BOTTOM = 78;
  const STEPS = [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8];

  const view = { w: 0, h: 0, pad: PAD, scale: 1, x: 0, y: 0, fitted: true, vector: true, ready: false };
  let lang = 'zh';
  const t = (zh, en) => (lang === 'en' ? en : zh);

  // ---------------------------------------------------------------- 几何

  function cardSize(scale = view.scale) {
    return { w: (view.w + view.pad * 2) * scale, h: (view.h + view.pad * 2) * scale };
  }

  function available() {
    return { w: Math.max(innerWidth - MARGIN * 2, 40), h: Math.max(innerHeight - TOP - BOTTOM, 40) };
  }

  function fitScale() {
    const base = cardSize(1);
    if (!base.w || !base.h) return 1;
    const room = available();
    const scale = Math.min(room.w / base.w, room.h / base.h);
    // 矢量图可以放大填满窗口；位图最多显示到原始大小
    return Math.max(0.02, Math.min(scale, view.vector ? 4 : 1));
  }

  function limits() {
    const fit = fitScale();
    return { min: Math.min(fit, 1) * 0.5, max: Math.max(8, fit * 4) };
  }

  function centered(scale) {
    const size = cardSize(scale);
    return { x: (innerWidth - size.w) / 2, y: TOP + (available().h - size.h) / 2 };
  }

  function clampPosition() {
    const size = cardSize();
    const keep = 80;
    view.x = Math.min(Math.max(view.x, keep - size.w), innerWidth - keep);
    view.y = Math.min(Math.max(view.y, keep - size.h), innerHeight - keep);
  }

  /** 按实际尺寸重新排版（而不是缩放位图），任何比例下都清晰。 */
  function apply(animate) {
    $card.classList.toggle('animate', !!animate && !reduceMotion.matches);
    const size = cardSize();
    $card.style.width = `${size.w}px`;
    $card.style.height = `${size.h}px`;
    $card.style.padding = `${view.pad * view.scale}px`;
    $card.style.transform = `translate(${view.x}px, ${view.y}px)`;
    $label.textContent = `${Math.round(view.scale * 100)}%`;
  }

  function fit(animate) {
    view.scale = fitScale();
    Object.assign(view, centered(view.scale));
    view.fitted = true;
    apply(animate);
  }

  function zoomTo(scale, cx, cy, animate) {
    const { min, max } = limits();
    const next = Math.min(max, Math.max(min, scale));
    const px = cx ?? innerWidth / 2;
    const py = cy ?? TOP + available().h / 2;
    const ratio = next / view.scale;
    view.x = px - (px - view.x) * ratio;
    view.y = py - (py - view.y) * ratio;
    view.scale = next;
    view.fitted = false;
    // 比窗口小时保持居中
    const size = cardSize();
    const room = available();
    if (size.w <= room.w) view.x = centered(next).x;
    if (size.h <= room.h) view.y = centered(next).y;
    clampPosition();
    apply(animate);
  }

  function step(direction) {
    const current = view.scale;
    let target = direction > 0
      ? STEPS.find((v) => v > current * 1.01)
      : STEPS.slice().reverse().find((v) => v < current * 0.99);
    if (target == null) target = direction > 0 ? current * 1.25 : current / 1.25;
    zoomTo(target, undefined, undefined, true);
  }

  function pan(dx, dy) {
    view.x += dx;
    view.y += dy;
    view.fitted = false;
    clampPosition();
    apply(false);
  }

  /** 适合窗口 ⇄ 放大到两倍（至少原始大小）。 */
  function toggleZoom(x, y) {
    const fitted = fitScale();
    if (view.fitted || Math.abs(view.scale - fitted) < 0.01) zoomTo(Math.max(fitted * 2, 1), x, y, true);
    else fit(true);
  }

  // ---------------------------------------------------------------- 交互

  $stage.addEventListener('wheel', (e) => {
    e.preventDefault();
    if (!view.ready) return;
    if (e.ctrlKey || e.metaKey) {
      const unit = e.deltaMode === 1 ? 0.05 : 0.01;
      zoomTo(view.scale * Math.exp(-e.deltaY * unit), e.clientX, e.clientY, false);
    } else {
      pan(-e.deltaX, -e.deltaY);
    }
  }, { passive: false });

  let drag = null;

  $stage.addEventListener('pointerdown', (e) => {
    if (e.button !== 0 || !view.ready) return;
    drag = { id: e.pointerId, x: e.clientX, y: e.clientY, vx: view.x, vy: view.y };
    $stage.setPointerCapture(e.pointerId);
    $stage.classList.add('dragging');
  });

  $stage.addEventListener('pointermove', (e) => {
    if (!drag || e.pointerId !== drag.id) return;
    view.x = drag.vx + (e.clientX - drag.x);
    view.y = drag.vy + (e.clientY - drag.y);
    view.fitted = false;
    clampPosition();
    apply(false);
  });

  const endDrag = () => {
    drag = null;
    $stage.classList.remove('dragging');
  };
  $stage.addEventListener('pointerup', endDrag);
  $stage.addEventListener('pointercancel', endDrag);

  $stage.addEventListener('dblclick', (e) => {
    if (view.ready) toggleZoom(e.clientX, e.clientY);
  });

  $toolbar.addEventListener('click', (e) => {
    const button = e.target.closest('button');
    if (!button || !view.ready) return;
    command(button.dataset.cmd);
  });

  function command(name) {
    switch (name) {
      case 'zoom-in': step(1); break;
      case 'zoom-out': step(-1); break;
      case 'actual': zoomTo(1, undefined, undefined, true); break;
      case 'fit': fit(true); break;
      case 'copy': post({ type: 'export', action: 'copy' }); break;
      case 'save': post({ type: 'export', action: 'save' }); break;
      default: break;
    }
  }

  document.addEventListener('keydown', (e) => {
    const mod = e.metaKey || e.ctrlKey;
    const key = e.key.toLowerCase();
    if (e.key === 'Escape') post({ type: 'close' });
    else if (!view.ready) return;
    else if (mod && key === 'c') command('copy');
    else if (mod && key === 's') command('save');
    else if (e.altKey) return;
    else if (key === '+' || key === '=') command('zoom-in');
    else if (key === '-' || key === '_') command('zoom-out');
    else if (key === '0') command('fit');
    else if (key === '1' && !mod) command('actual');
    else if (mod) return; // 其余组合键交给菜单
    else if (e.key === 'ArrowLeft') pan(60, 0);
    else if (e.key === 'ArrowRight') pan(-60, 0);
    else if (e.key === 'ArrowUp') pan(0, 60);
    else if (e.key === 'ArrowDown') pan(0, -60);
    else return;
    e.preventDefault();
  });

  document.addEventListener('contextmenu', (e) => e.preventDefault());

  window.addEventListener('resize', () => {
    if (!view.ready) return;
    if (view.fitted) fit(false);
    else {
      clampPosition();
      apply(false);
    }
  });

  // ---------------------------------------------------------------- 提示

  let toastTimer = 0;
  function toast(text) {
    if (!text) return;
    $toast.textContent = text;
    $toast.classList.add('visible');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => $toast.classList.remove('visible'), 1600);
  }

  function localize() {
    document.documentElement.lang = lang === 'en' ? 'en' : 'zh-CN';
    const labels = {
      'zoom-out': [t('缩小', 'Zoom out'), '−'],
      actual: [t('实际大小', 'Actual size'), '1'],
      'zoom-in': [t('放大', 'Zoom in'), '+'],
      fit: [t('适合窗口', 'Fit to window'), '0'],
      copy: [t('拷贝图片', 'Copy image'), '⌘C'],
      save: [t('存储为 PNG…', 'Save as PNG…'), '⌘S'],
    };
    for (const button of $toolbar.querySelectorAll('button')) {
      const [name, key] = labels[button.dataset.cmd] || ['', ''];
      button.title = `${name}  ${key}`;
      button.setAttribute('aria-label', name);
    }
    $toolbar.setAttribute('aria-label', t('图表工具', 'Figure tools'));
  }

  // ---------------------------------------------------------------- 对外接口

  let exportState = null;

  window.Figure = {
    show(payload) {
      lang = payload.lang === 'en' ? 'en' : 'zh';
      localize();
      view.ready = false;
      $card.className = '';
      $card.replaceChildren();
      view.vector = payload.kind !== 'image';
      view.pad = payload.kind === 'image' ? 0 : PAD;

      const finish = (width, height) => {
        view.w = width > 0 ? width : 480;
        view.h = height > 0 ? height : 320;
        view.ready = true;
        fit(false);
        requestAnimationFrame(() => $card.classList.add('visible'));
      };

      if (payload.kind === 'mermaid') {
        $card.classList.add('mermaid');
        const tpl = document.createElement('template');
        tpl.innerHTML = payload.markup || '';
        const svg = tpl.content.querySelector('svg');
        if (!svg) return;
        svg.removeAttribute('style');
        svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
        $card.append(svg);
        finish(payload.width, payload.height);
      } else {
        if (payload.kind === 'image') $card.classList.add('image');
        const img = new Image();
        img.alt = '';
        img.draggable = false;
        img.onload = () => finish(payload.width || img.naturalWidth, payload.height || img.naturalHeight);
        img.onerror = () => finish(0, 0);
        img.src = payload.src || '';
        $card.append(img);
      }
    },

    /** 触控板捏合（由 Swift 转发 magnify 事件）。 */
    pinch(magnification, x, y) {
      if (view.ready) zoomTo(view.scale * (1 + magnification), x, y, false);
    },

    /** 触控板双指轻点两下。 */
    smartMagnify(x, y) {
      if (view.ready) toggleZoom(x, y);
    },

    /** 导出前切换到适合窗口并隐藏工具条，返回卡片区域。 */
    beginExport() {
      if (!view.ready) return '';
      exportState = { scale: view.scale, x: view.x, y: view.y, fitted: view.fitted };
      document.body.classList.add('exporting');
      fit(false);
      // 向内取整，避免截到卡片外的背景
      const rect = $card.getBoundingClientRect();
      const left = Math.ceil(rect.left), top = Math.ceil(rect.top);
      const width = Math.floor(rect.right) - left, height = Math.floor(rect.bottom) - top;
      return JSON.stringify({ x: left, y: top, width, height, naturalWidth: cardSize(1).w });
    },

    endExport(message) {
      document.body.classList.remove('exporting');
      if (exportState) {
        Object.assign(view, exportState);
        exportState = null;
        apply(false);
      }
      toast(message);
    },
  };

  localize();
  post({ type: 'ready' });
})();
