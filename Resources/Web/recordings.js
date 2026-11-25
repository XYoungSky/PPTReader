// 课堂录音窗口：左边是录音列表（按课程分组），右边是回放、转写，以及整理出的补充要点和课程安排。
// 原生端调用：
//   Recordings.setList({lang, items, selected})
//     items: [{id, title, course, tags, startedAt(毫秒), duration(秒), status: 'recording'|'transcribing'|'ready', organized, elapsed?}]
//   Recordings.showDetail({id, title, startedAt, duration, locale, deck, status, segments, lines, live, supplements, organize})
//     supplements: [{kind: 'supplement'|'arrangement', deck, deckTitle, page, point, quote, t}]（整理过才有）
//     corrections: [{segment, start, text}]：纠正过的句子（整理过才有）；lines 里的 segment + start 对得上
//     segments: [{index, duration, state: 'complete'|'damaged'|'recording', transcribed, queued}]
//     lines: [{t, end, text}]，t 是录音时间（秒，已按分段换算好）；segment 标出所属分段
//   Recordings.setPlayback({time, playing, rate})  播放时每 0.25 秒一次；两次之间由这里按速度补帧，进度条才顺滑
//   Recordings.setLive({text, volatile})  正在录音时的实时字幕
//   Recordings.toast(message)
// 发回原生端：ready / select / play / pause / seek / rate / organize / organizeConfirm / organizeCancel / openPage / rename / editTags
//   / reveal / exportAudio / exportTab / delete
//
// 动效的原则：已经在页面上的元素尽量原地更新、不重建（重建会让状态点的呼吸、转圈和过渡动画从头开始，看起来一跳一跳的）；
// 换录音、换标签页时新内容淡入；整理面板展开、收起和换阶段时高度平滑过渡。系统打开“减少动态效果”时都不做。
(function () {
  'use strict';

  const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.recordings;
  const post = (message) => native && native.postMessage(message);
  const $ = (id) => document.getElementById(id);

  let lang = (navigator.language || 'zh').startsWith('zh') ? 'zh' : 'en';
  const t = (zh, en) => (lang === 'zh' ? zh : en);

  const ICON = {
    play: '<svg viewBox="0 0 16 16"><path d="M4.5 2.8v10.4a.6.6 0 0 0 .9.5l8.2-5.2a.6.6 0 0 0 0-1L5.4 2.3a.6.6 0 0 0-.9.5z"/></svg>',
    pause: '<svg viewBox="0 0 16 16"><rect x="3.5" y="2.5" width="3" height="11" rx="1"/><rect x="9.5" y="2.5" width="3" height="11" rx="1"/></svg>',
    back: '<svg viewBox="0 0 20 20"><path d="M4.5 9.5a6 6 0 1 0 1.8-4.3"/><path d="M4 2.5v3.6h3.6"/><text x="10" y="12.6" text-anchor="middle" font-size="5.6" font-family="-apple-system" font-weight="600" fill="currentColor" stroke="none">15</text></svg>',
    forward: '<svg viewBox="0 0 20 20"><path d="M15.5 9.5a6 6 0 1 1-1.8-4.3"/><path d="M16 2.5v3.6h-3.6"/><text x="10" y="12.6" text-anchor="middle" font-size="5.6" font-family="-apple-system" font-weight="600" fill="currentColor" stroke="none">15</text></svg>',
    more: '<svg viewBox="0 0 16 16"><circle cx="3.5" cy="8" r=".6" fill="currentColor"/><circle cx="8" cy="8" r=".6" fill="currentColor"/><circle cx="12.5" cy="8" r=".6" fill="currentColor"/></svg>',
    sparkles: '<svg viewBox="0 0 16 16"><path d="M7 2.5 8.2 6 11.5 7.2 8.2 8.4 7 12 5.8 8.4 2.5 7.2 5.8 6z"/><path d="M12.2 10.3l.5 1.4 1.4.5-1.4.5-.5 1.4-.5-1.4-1.4-.5 1.4-.5z"/></svg>',
    check: '<svg viewBox="0 0 12 12"><path d="m2.5 6.3 2.3 2.2 4.7-5"/></svg>',
    export: '<svg viewBox="0 0 16 16"><path d="M8 10V2.5M5 5.2 8 2.3l3 2.9"/><path d="M3.5 8.5v4a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1v-4"/></svg>',
    import: '<svg viewBox="0 0 16 16"><path d="M8 2.5V10M5 7l3 3 3-3"/><path d="M3 9.5v3a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1v-3"/></svg>',
    mic: '<svg viewBox="0 0 20 20"><rect x="7.2" y="2.5" width="5.6" height="9.5" rx="2.8"/><path d="M4.5 9.5a5.5 5.5 0 0 0 11 0M10 15v2.5"/></svg>',
  };

  let items = [];
  let selected = null;
  let detail = null;
  let tab = 'transcript';
  let playback = { time: 0, playing: false, rate: 1 };
  let query = '';
  /** 列表的搜索：标题、标签、课程、日期。 */
  let listQuery = '';
  /** 用户自己滚动了转写：几秒内不自动滚到当前句。 */
  let manualScrollUntil = 0;

  // ---------- 动效 ----------

  const EASE = 'cubic-bezier(0.2, 0.8, 0.2, 1)';
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  /**
   * 页面不可见时（窗口在后台被隐藏、被遮住）WebKit 会暂停动画：停在第一帧的高度、透明度会把内容遮住、点不到。
   * 所以：不可见时不做动画，直接到最终状态；每个动画到点没播完就强制结束；页面变成不可见时，正在播的动画立即结束。
   */
  function animate(el, frames, options) {
    if (!el || reducedMotion.matches || document.visibilityState !== 'visible') return null;
    const a = el.animate(frames, options);
    const limit = (options.delay || 0) + (options.duration || 0) + 250;
    setTimeout(() => { if (a.playState === 'running' || a.playState === 'paused') a.finish(); }, limit);
    return a;
  }

  /** 结束所有一次性的动画和过渡（呼吸、转圈这类无限循环的 CSS 动画不动）。 */
  function settleAnimations() {
    for (const a of document.getAnimations()) {
      const timing = a.effect && a.effect.getTiming ? a.effect.getTiming() : null;
      if (timing && timing.iterations === Infinity) continue;
      try { a.finish(); } catch (_) { /* 无法结束的（例如时长为 0）忽略 */ }
    }
  }

  document.addEventListener('visibilitychange', settleAnimations);

  /** 新内容出现：淡入，带一点位移。 */
  function enter(el, distance = 6, duration = 240) {
    animate(el, [{ opacity: 0, transform: `translateY(${distance}px)` }, { opacity: 1, transform: 'none' }], { duration, easing: EASE });
  }

  function fadeIn(el, duration = 180) {
    animate(el, [{ opacity: 0 }, { opacity: 1 }], { duration, easing: 'ease-out' });
  }

  /** 从无到有：高度从 0 展开。 */
  function expand(el, duration = 280) {
    const height = el.offsetHeight;
    const style = getComputedStyle(el);
    el.style.overflow = 'hidden';
    const a = animate(el, [
      { height: '0px', opacity: 0, marginTop: '0px', marginBottom: '0px', paddingTop: '0px', paddingBottom: '0px' },
      { height: `${height}px`, opacity: 1, marginTop: style.marginTop, marginBottom: style.marginBottom, paddingTop: style.paddingTop, paddingBottom: style.paddingBottom },
    ], { duration, easing: EASE });
    if (a) a.onfinish = a.oncancel = () => { el.style.overflow = ''; };
    else el.style.overflow = '';
  }

  /** 收起后移除。 */
  function collapse(el, duration = 220) {
    el.classList.add('leaving');
    el.style.overflow = 'hidden';
    const a = animate(el, [
      { height: `${el.offsetHeight}px`, opacity: 1 },
      { height: '0px', opacity: 0, marginTop: '0px', marginBottom: '0px', paddingTop: '0px', paddingBottom: '0px' },
    ], { duration, easing: EASE, fill: 'forwards' });
    if (a) a.onfinish = () => el.remove();
    else el.remove();
  }

  /** 原地换成新的元素：高度从旧的过渡到新的，内容淡入。 */
  function morph(from, to, duration = 280) {
    const before = from.offsetHeight;
    from.replaceWith(to);
    const after = to.offsetHeight;
    to.style.overflow = 'hidden';
    const a = animate(to, [{ height: `${before}px` }, { height: `${after}px` }], { duration, easing: EASE });
    if (a) a.onfinish = a.oncancel = () => { to.style.overflow = ''; };
    else to.style.overflow = '';
    for (const child of to.children) {
      animate(child, [{ opacity: 0 }, { opacity: 1 }], { duration: 220, delay: 70, easing: 'ease-out', fill: 'backwards' });
    }
  }

  /** 只在内容变了时才改 innerHTML，原有的元素和它们的动画不受打扰。 */
  function patch(el, html) {
    if (el._html === html) return false;
    el.innerHTML = html;
    el._html = html;
    return true;
  }

  // ---------- 格式 ----------

  function clock(seconds, long) {
    const s = Math.max(0, Math.floor(seconds || 0));
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
    const mm = String(m).padStart(2, '0'), ss = String(sec).padStart(2, '0');
    return h > 0 || long ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
  }

  function length(seconds) {
    const m = Math.round((seconds || 0) / 60);
    if (m < 60) return t(`${m} 分钟`, `${m} min`);
    const h = Math.floor(m / 60), rest = m % 60;
    return rest ? t(`${h} 小时 ${rest} 分`, `${h} h ${rest} min`) : t(`${h} 小时`, `${h} h`);
  }

  function day(ms) {
    const d = new Date(ms);
    const week = t(['周日', '周一', '周二', '周三', '周四', '周五', '周六'][d.getDay()],
      ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d.getDay()]);
    const time = `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
    return {
      date: t(`${d.getMonth() + 1}月${d.getDate()}日 ${week}`, `${week}, ${d.toLocaleDateString('en', { month: 'short', day: 'numeric' })}`),
      time,
    };
  }

  const LOCALES = { en_US: ['美式英语', 'US English'], en_GB: ['英式英语', 'UK English'], en_AU: ['澳式英语', 'Australian English'],
    en_IN: ['印度英语', 'Indian English'], en_SG: ['新加坡英语', 'Singapore English'], en_CA: ['加拿大英语', 'Canadian English'] };
  const localeName = (id) => (LOCALES[id] ? t(...LOCALES[id]) : id || '');

  const escape = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  // ---------- 列表 ----------
  // 列表项按 id 复用：录音时每秒更新一次时长，只改那一行字，“录音中”的红点和“转写中”的圈不会重新开始。

  const listNodes = new Map();
  const groupNodes = new Map();
  let noneNode = null;
  let listShown = false;

  function matchesList(item) {
    const needle = listQuery.trim().toLowerCase();
    if (!needle) return true;
    const when = day(item.startedAt);
    return [item.title, item.course, when.date, ...(item.tags || [])].some((field) => (field || '').toLowerCase().includes(needle));
  }

  function itemHTML(item) {
    const when = day(item.startedAt);
    let status = '';
    if (item.status === 'recording') status = `<span class="badge"><span class="rec-dot"></span>${t('录音中', 'Recording')}</span>`;
    else if (item.status === 'importing') status = `<span class="badge"><span class="spinner"></span>${t('导入中', 'Importing')}</span>`;
    else if (item.status === 'transcribing') status = `<span class="badge"><span class="spinner"></span>${t('转写中', 'Transcribing')}</span>`;
    else if (item.organized) status = `<span class="badge done">${ICON.check}${t('已整理', 'Organized')}</span>`;
    const duration = item.status === 'recording' ? clock(item.elapsed || item.duration, true)
      : item.status === 'importing' ? `${Math.round((item.progress || 0) * 100)}%` : length(item.duration);
    return {
      name: `<span>${escape(item.title)}</span>${status}`,
      sub: `<span>${when.date} ${when.time}</span><span>·</span><span class="${item.status === 'recording' ? 'clock' : ''}">${duration}</span>`,
    };
  }

  function listNode(id) {
    let el = listNodes.get(id);
    if (el) return [el, false];
    el = document.createElement('button');
    el.type = 'button';
    el.className = 'item';
    el.innerHTML = '<div class="name"></div><div class="sub"></div>';
    el.addEventListener('click', () => selectItem(id));
    listNodes.set(id, el);
    return [el, true];
  }

  function groupNode(key) {
    let el = groupNodes.get(key);
    if (el) return [el, false];
    el = document.createElement('div');
    el.className = 'group';
    groupNodes.set(key, el);
    return [el, true];
  }

  /** - Parameter filtering: 搜索框里打字时：不显示进出的动画，跟手。 */
  function renderList(filtering) {
    $('list-title').textContent = t('课堂录音', 'Lectures');
    $('import').title = t('导入音频…', 'Import Audio…');
    $('import').setAttribute('aria-label', $('import').title);
    $('list-search-input').placeholder = t('搜索标题、标签、日期', 'Search titles, tags, dates');
    const list = $('list');
    const shown = items.filter(matchesList);
    const wanted = [];
    const fresh = [];
    if (!shown.length && items.length) {
      if (!noneNode) { noneNode = document.createElement('div'); noneNode.className = 'group none'; fresh.push(noneNode); }
      noneNode.textContent = t('无匹配项', 'No matches');
      wanted.push(noneNode);
    }
    const groups = new Map();
    for (const item of shown) {
      // 按第一个标签（通常是课程编号）分组，没有标签时按课程文件夹
      const key = (item.tags && item.tags[0]) || item.course || t('未归入课程', 'No course');
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(item);
    }
    for (const [key, group] of groups) {
      const [header, newHeader] = groupNode(key);
      header.textContent = key;
      header.title = key;
      if (newHeader) fresh.push(header);
      wanted.push(header);
      for (const item of group) {
        const [el, isNew] = listNode(item.id);
        const html = itemHTML(item);
        patch(el.firstElementChild, html.name);
        patch(el.lastElementChild, html.sub);
        el.classList.toggle('selected', item.id === selected);
        if (isNew) fresh.push(el);
        wanted.push(el);
      }
    }

    // 不再显示的：删掉的录音收起，搜索筛掉的直接拿走
    const keep = new Set(wanted);
    const existing = new Set(items.map((item) => item.id));
    for (const [id, el] of listNodes) {
      if (keep.has(el)) continue;
      listNodes.delete(id);
      if (!filtering && listShown && !existing.has(id)) collapse(el); else el.remove();
    }
    for (const [key, el] of groupNodes) {
      if (keep.has(el)) continue;
      groupNodes.delete(key);
      if (!filtering && listShown) collapse(el); else el.remove();
    }
    if (noneNode && !keep.has(noneNode)) { noneNode.remove(); noneNode = null; }

    // 按顺序放好；已经在位置上的不动（挪动元素会让它的动画重新开始）
    let cursor = list.firstElementChild;
    for (const el of wanted) {
      while (cursor && cursor.classList.contains('leaving')) cursor = cursor.nextElementSibling;
      if (el === cursor) { cursor = cursor.nextElementSibling; continue; }
      list.insertBefore(el, cursor);
    }
    if (listShown && !filtering) fresh.forEach((el) => expand(el, 240));
    listShown = true;
  }

  function selectItem(id) {
    if (id === selected) return;
    selected = id;
    for (const [key, el] of listNodes) el.classList.toggle('selected', key === id);
    post({ type: 'select', id });
    if (!native) demoSelect(id);
  }

  // ---------- 详情 ----------

  function renderDetail(same) {
    const d = detail;
    if (!d) return;
    const recording = d.status === 'recording';
    const importing = d.status === 'importing';
    $('title').textContent = d.title;
    $('title').title = d.title;
    const when = day(d.startedAt);
    const parts = [`${when.date} ${when.time}`,
      recording ? t('正在录音', 'Recording now') : importing ? t(`正在导入 ${Math.round((d.progress || 0) * 100)}%`, `Importing ${Math.round((d.progress || 0) * 100)}%`) : length(d.duration),
      localeName(d.locale)];
    if (d.deck) parts.push(escape(d.deck));
    patch($('meta'), (d.tags || []).map((tag) => `<button type="button" class="chip tag-filter" data-tag="${escape(tag)}" title="${t('筛选此标签', 'Filter by this tag')}">${escape(tag)}</button>`).join('')
      + parts.map((p) => `<span>${p}</span>`).join('<span class="dot">·</span>'));

    const organize = $('organize');
    patch(organize, ICON.sparkles + `<span>${d.supplements ? t('重新整理', 'Organize again') : t('AI 整理', 'Organize with AI')}</span>`);
    organize.disabled = d.status !== 'ready' || !!d.organize;
    organize.title = d.status === 'ready'
      ? t('判断相关课件、纠正转写，并整理补充要点与课程安排', 'Find related decks, correct the transcript, and extract supplements and course arrangements')
      : t('录音与转写完成后可用', 'Available after recording and transcription finish');
    $('export').title = t('导出', 'Export');
    $('more').title = t('更多', 'More');
    $('back').title = t('后退 15 秒', 'Back 15 seconds');
    $('forward').title = t('前进 15 秒', 'Forward 15 seconds');
    for (const id of ['back', 'forward', 'play', 'rate']) $(id).disabled = recording || importing;
    $('player').classList.toggle('inactive', recording || importing);
    $('duration').textContent = clock(d.duration, d.duration >= 3600);
    $('search-input').placeholder = t('搜索转写', 'Search transcript');
    renderTicks();
    renderControls();
    renderTabs(same);
    renderContent(same);
    drawProgress(displayTime());
    if (renderOrganize(same) && same) $('content').scrollTo({ top: 0, behavior: reducedMotion.matches ? 'auto' : 'smooth' });
  }

  function renderTabs(animated) {
    const d = detail;
    const count = (kind) => (d.supplements || []).filter((item) => (item.kind || 'supplement') === kind).length;
    const tabs = [
      ['transcript', t('转写', 'Transcript'), ''],
      ['corrected', t('纠正版', 'Corrected'), d.corrections ? String(d.corrections.length) : ''],
      ['supplements', t('补充要点', 'Supplements'), count('supplement') ? String(count('supplement')) : ''],
      ['arrangements', t('课程安排', 'Course arrangements'), count('arrangement') ? String(count('arrangement')) : ''],
    ];
    const box = $('tabs');
    patch(box, tabs.map(([key, label, n]) =>
      `<button type="button" role="tab" data-tab="${key}">${label}${n ? `<span class="count">${n}</span>` : ''}</button>`).join(''));
    for (const button of box.children) {
      const on = button.dataset.tab === tab;
      button.classList.toggle('active', on);
      button.setAttribute('aria-selected', on);
    }
    $('search').classList.toggle('soft-hidden', !(tab === 'transcript' || tab === 'corrected'));
    moveIndicator(animated);
  }

  /** 标签页下面的那条线：换标签页时滑过去。 */
  function moveIndicator(animated) {
    const active = $('tabs').querySelector('button.active');
    const bar = $('tab-indicator');
    if (!active) return;
    if (!animated) bar.style.transition = 'none';
    bar.style.width = `${active.offsetWidth}px`;
    bar.style.transform = `translateX(${active.offsetLeft}px)`;
    if (!animated) { void bar.offsetWidth; bar.style.transition = ''; }
  }

  function switchTab(key) {
    if (key === tab || !detail) return;
    tab = key;
    renderTabs(true);
    $('content').scrollTop = 0;
    renderContent(false);
    enter($('tab-body'), 6, 220);
  }

  /** 进度条上标出分段的接缝；损坏的分段在接缝处标红（那段没录下来）。 */
  function renderTicks() {
    const ticks = $('scrubber').querySelector('.ticks');
    const d = detail;
    let html = '';
    if (d && d.duration) {
      let offset = 0;
      let gapBefore = false;
      d.segments.forEach((segment, i) => {
        if (segment.state === 'damaged') { gapBefore = true; return; }
        if (segment.state !== 'complete') return;
        if (i > 0 && offset > 0) {
          html += `<div class="tick${gapBefore ? ' gap' : ''}" style="left:${(offset / d.duration) * 100}%"${gapBefore ? ` title="${t('此处缺失一段录音', 'A segment is missing here')}"` : ''}></div>`;
        }
        gapBefore = false;
        offset += segment.duration;
      });
    }
    patch(ticks, html);
  }

  // ---------- 播放 ----------
  // 原生端每 0.25 秒报一次时间；播放时按“上次报的时间 + 过去的时间 × 速度”逐帧推算，进度条和高亮跟着走。

  let anchor = { time: 0, at: 0 };
  let dragging = false;
  let frame = 0;
  /** 刚跳转过：原生端还在跳的路上报来的旧时间不要，免得进度条往回闪一下。 */
  let seekGuard = { time: 0, until: 0 };
  let shownClock = '';

  function displayTime() {
    if (!playback.playing || dragging) return playback.time;
    const duration = (detail && detail.duration) || 0;
    return Math.min(duration, anchor.time + ((performance.now() - anchor.at) / 1000) * playback.rate);
  }

  function applyPlayback(change, fromNative) {
    const now = performance.now();
    const next = { ...change };
    if (fromNative && 'time' in next) {
      if (dragging || (now < seekGuard.until && Math.abs(next.time - seekGuard.time) > 0.75)) delete next.time;
    }
    const shown = displayTime();
    playback = { ...playback, ...next };
    if (!('time' in next)) playback.time = shown;
    anchor = { time: playback.time, at: now };
    renderControls();
    drawProgress(playback.time);
    syncLoop();
  }

  function syncLoop() {
    const running = playback.playing && !dragging && !!detail;
    if (running && !frame) frame = requestAnimationFrame(tick);
    if (!running && frame) { cancelAnimationFrame(frame); frame = 0; }
  }

  function tick() {
    frame = 0;
    drawProgress(displayTime());
    syncLoop();
  }

  function drawProgress(time) {
    const duration = (detail && detail.duration) || 1;
    const fraction = Math.min(1, Math.max(0, time / duration));
    const scrubber = $('scrubber');
    scrubber.querySelector('.fill').style.transform = `scaleX(${fraction})`;
    scrubber.querySelector('.knob').style.left = `${fraction * 100}%`;
    const text = clock(time, duration >= 3600);
    if (text !== shownClock) { $('time').textContent = text; shownClock = text; }
    highlightAt(time, false);
  }

  function renderControls() {
    const play = $('play');
    play.classList.toggle('playing', playback.playing);
    play.title = playback.playing ? t('暂停', 'Pause') : t('播放', 'Play');
    play.setAttribute('aria-label', play.title);
    const rate = `${playback.rate}×`;
    if ($('rate').textContent !== rate) $('rate').textContent = rate;
    $('rate').title = t('播放速度', 'Playback speed');
  }

  function seek(time, play) {
    const duration = (detail && detail.duration) || 0;
    const target = Math.min(Math.max(0, time), duration);
    manualScrollUntil = 0;
    seekGuard = { time: target, until: performance.now() + 600 };
    post({ type: 'seek', time: target, play: !!play });
    const startPlaying = play && !playback.playing;
    if (startPlaying) post({ type: 'play' });
    applyPlayback({ time: target, playing: playback.playing || !!play });
    if (!native) demoPlay(playback.playing);
  }

  function togglePlay() {
    if (!detail || detail.status === 'recording') return;
    const playing = !playback.playing;
    post({ type: playing ? 'play' : 'pause' });
    applyPlayback({ playing });
    if (!native) demoPlay(playing);
  }

  const RATES = [1, 1.25, 1.5, 1.75, 2, 0.8];

  function cycleRate() {
    const rate = RATES[(RATES.indexOf(playback.rate) + 1) % RATES.length];
    post({ type: 'rate', rate });
    applyPlayback({ rate });
    animate($('rate'), [{ transform: 'scale(0.9)' }, { transform: 'none' }], { duration: 180, easing: EASE });
  }

  function setupScrubber() {
    const scrubber = $('scrubber');
    const timeAt = (event) => {
      const r = scrubber.getBoundingClientRect();
      const duration = (detail && detail.duration) || 0;
      return Math.max(0, Math.min(duration, ((event.clientX - r.left) / r.width) * duration));
    };
    scrubber.addEventListener('pointerdown', (event) => {
      if (!detail || detail.status === 'recording') return;
      scrubber.setPointerCapture(event.pointerId);
      scrubber.classList.add('dragging');
      dragging = true;
      syncLoop();
      playback.time = timeAt(event);
      drawProgress(playback.time);
    });
    scrubber.addEventListener('pointermove', (event) => {
      if (!dragging) return;
      playback.time = timeAt(event);
      drawProgress(playback.time);
    });
    const release = () => {
      if (!dragging) return;
      dragging = false;
      scrubber.classList.remove('dragging');
      seek(playback.time, false);
    };
    scrubber.addEventListener('pointerup', release);
    scrubber.addEventListener('pointercancel', release);
    scrubber.addEventListener('keydown', (event) => {
      if (event.key === 'ArrowLeft') seek(displayTime() - 5);
      if (event.key === 'ArrowRight') seek(displayTime() + 5);
    });
  }

  // ---------- 转写 ----------

  /** 句子按停顿和分段合成段落：停顿超过 3.5 秒、满 5 句、或换了分段时另起一段。 */
  function paragraphs(lines) {
    const result = [];
    let current = null;
    for (const line of lines) {
      const breakHere = !current || line.segment !== current.segment || current.lines.length >= 5
        || line.t - current.lines[current.lines.length - 1].end > 3.5;
      if (breakHere) {
        current = { segment: line.segment, t: line.t, lines: [] };
        result.push(current);
      }
      current.lines.push(line);
    }
    return result;
  }

  /** 当前标签页里的句子，按时间排好：播放时用二分查找找当前句，不用每帧扫一遍页面。 */
  let lineIndex = [];
  let currentLine = null;

  /** - Parameter keepScroll: 同一条录音的内容更新（转写完一段、整理有了进展）：保持滚动位置。 */
  function renderContent(keepScroll) {
    const content = $('content');
    const body = $('tab-body');
    const scroll = content.scrollTop;
    body.textContent = '';
    lineIndex = [];
    currentLine = null;
    buildTab(body);
    lineIndex = [...body.querySelectorAll('.line')].map((el) => ({ t: Number(el.dataset.t), end: Number(el.dataset.end), el }));
    if (keepScroll) content.scrollTop = scroll;
    highlightAt(displayTime(), !keepScroll && !(detail && detail.organize));
  }

  function buildTab(body) {
    const d = detail;
    if (tab === 'supplements' || tab === 'arrangements') {
      const kind = tab === 'supplements' ? 'supplement' : 'arrangement';
      const list = (d.supplements || []).filter((item) => (item.kind || 'supplement') === kind);
      if (list.length) {
        body.appendChild(kind === 'supplement' ? supplementsView(list) : arrangementsView(list));
      } else if (d.supplements) {
        body.appendChild(kind === 'supplement'
          ? placeholder(t('无补充要点', 'No supplements'), t('讲授内容均已包含在课件中。', 'The lecture content is covered by the slides.'), true)
          : placeholder(t('无课程安排', 'No course arrangements'), t('本节课未提及考试、作业或进度安排。', 'No exams, assignments or schedule changes were mentioned.'), true));
      } else if (!d.organize) {
        body.appendChild(kind === 'supplement'
          ? placeholder(t('尚无补充要点', 'No supplements yet'),
            t('AI 整理后，在此列出课件以外的讲授内容，并对应到课件页。', 'After organizing, content not on the slides is listed here, matched to slide pages.'))
          : placeholder(t('尚无课程安排', 'No course arrangements yet'),
            t('AI 整理后，在此列出考试、作业、截止日期等安排。', 'After organizing, exams, assignments and deadlines are listed here.')));
      }
      return;
    }

    if (tab === 'corrected' && !d.corrections) {
      if (!d.organize) {
        body.appendChild(placeholder(t('尚无纠正版', 'No corrected version yet'),
          t('AI 整理后，参照课件修正识别错误的术语、人名和数字，并标出改动。', 'After organizing, misrecognized terms, names and numbers are corrected using the slides, with every change marked.')));
      }
      return;
    }
    const fixedText = new Map((tab === 'corrected' ? d.corrections : []).map((fix) => [`${fix.segment}:${Number(fix.start).toFixed(3)}`, fix.text]));
    if (tab === 'corrected') {
      const summary = document.createElement('p');
      summary.className = 'fix-summary';
      summary.textContent = fixedText.size
        ? t(`已修正 ${fixedText.size} 句。悬停在标记处可查看原文。`, `${fixedText.size} lines corrected. Hover over a highlight to see the original.`)
        : t('未发现需要修正的内容。', 'No corrections needed.');
      body.appendChild(summary);
    }
    const bySegment = new Map();
    for (const line of d.lines) {
      if (!bySegment.has(line.segment)) bySegment.set(line.segment, []);
      bySegment.get(line.segment).push(line);
    }
    const needle = query.trim().toLowerCase();
    const pattern = needle ? new RegExp(needle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi') : null;
    let matches = 0;
    for (const segment of d.segments) {
      if (segment.state === 'damaged') {
        body.appendChild(notice('gap', t(`第 ${segment.index} 段缺失：录音时应用意外退出，该段未能保存。`,
          `Segment ${segment.index} is missing: the app quit unexpectedly while recording it.`)));
        continue;
      }
      const lines = bySegment.get(segment.index) || [];
      for (const para of paragraphs(lines)) {
        const row = document.createElement('div');
        row.className = 'para';
        const stamp = document.createElement('span');
        stamp.className = 'stamp clock';
        stamp.textContent = clock(para.t, d.duration >= 3600);
        stamp.title = t('从此处播放', 'Play from here');
        stamp.addEventListener('click', () => seek(para.t, true));
        const text = document.createElement('p');
        text.className = 'text';
        for (const line of para.lines) {
          const span = document.createElement('span');
          span.className = 'line';
          span.dataset.t = line.t;
          span.dataset.end = line.end;
          const fix = fixedText.get(`${line.segment}:${Number(line.start).toFixed(3)}`);
          let html = fix ? diffHTML(line.text, fix) : escape(line.text);
          if (fix) { span.classList.add('fixed'); span.title = t('原文：', 'Original: ') + line.text; }
          if (pattern) html = html.replace(pattern, (m) => { matches += 1; return `<mark>${m}</mark>`; });
          span.innerHTML = html + ' ';
          span.addEventListener('click', () => {
            if (window.getSelection().toString()) return;   // 选文字复制时不跳
            seek(line.t, true);
          });
          text.appendChild(span);
        }
        row.append(stamp, text);
        body.appendChild(row);
      }
      if (segment.state === 'complete' && !segment.transcribed) {
        body.appendChild(segment.queued === false
          ? notice('pending', t(`第 ${segment.index} 段转写失败，将在下次启动时重试。`,
            `Segment ${segment.index} failed to transcribe; it will be retried at next launch.`))
          : notice('pending', t(`正在转写第 ${segment.index} 段…`, `Transcribing segment ${segment.index}…`), true));
      }
    }
    if (d.status === 'recording') body.appendChild(liveRow());
    if (d.status === 'importing') {
      body.appendChild(notice('pending', t(`正在导入 ${Math.round((d.progress || 0) * 100)}%…`, `Importing ${Math.round((d.progress || 0) * 100)}%…`), true));
    }
    if (!d.lines.length && d.status !== 'recording' && d.status !== 'importing' && !d.segments.some((s) => s.state === 'complete' && !s.transcribed)) {
      body.appendChild(placeholder(t('无转写内容', 'No transcript'), t('未识别到语音。', 'No speech was recognized.')));
    }
    if (needle) toast(matches ? t(`找到 ${matches} 处`, `${matches} matches`) : t('无匹配项', 'No matches'));
  }

  /** 纠正后的句子：和原句逐词比较，新出现或改过的词标出来。 */
  function diffHTML(before, after) {
    const a = before.split(/\s+/).filter(Boolean);
    const b = after.split(/\s+/).filter(Boolean);
    // 最长公共子序列（句子都很短，直接用表）
    const dp = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
    for (let i = a.length - 1; i >= 0; i -= 1) {
      for (let j = b.length - 1; j >= 0; j -= 1) {
        dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
      }
    }
    const out = [];
    let i = 0;
    let j = 0;
    while (j < b.length) {
      if (i < a.length && a[i] === b[j]) { out.push(escape(b[j])); i += 1; j += 1; }
      else if (i < a.length && dp[i + 1][j] >= dp[i][j + 1]) { i += 1; }
      else { out.push(`<ins>${escape(b[j])}</ins>`); j += 1; }
    }
    return out.join(' ').replace(/<\/ins> <ins>/g, ' ');
  }

  function notice(kind, message, spinning) {
    const row = document.createElement('div');
    row.className = `notice ${kind}`;
    row.innerHTML = `<span></span><div class="body">${spinning ? '<span class="spinner"></span>' : ''}<span>${escape(message)}</span></div>`;
    return row;
  }

  function liveRow() {
    const row = document.createElement('div');
    row.className = 'live';
    row.id = 'live';
    const live = (detail && detail.live) || { text: '', volatile: '' };
    row.innerHTML = `<span class="stamp clock"><span class="rec-dot"></span>${t('实时', 'Live')}</span>
      <p class="text"><span class="final"></span> <span class="volatile"></span></p>`;
    row.querySelector('.final').textContent = live.text;
    row.querySelector('.volatile').textContent = live.volatile;
    return row;
  }

  function placeholder(title, body, noButton) {
    const box = document.createElement('div');
    box.className = 'placeholder';
    box.innerHTML = `<strong>${escape(title)}</strong><p>${escape(body)}</p>`;
    if (!noButton && detail && detail.status === 'ready' && !detail.organize) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'primary';
      button.innerHTML = ICON.sparkles + `<span>${t('AI 整理', 'Organize with AI')}</span>`;
      button.addEventListener('click', organize);
      box.appendChild(button);
    }
    return box;
  }

  /** 高亮正在播放的那句；跟着播放滚动，除非用户刚自己滚过。 */
  function highlightAt(time, force) {
    let lo = 0;
    let hi = lineIndex.length - 1;
    let found = -1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (lineIndex[mid].t <= time + 0.05) { found = mid; lo = mid + 1; } else hi = mid - 1;
    }
    let line = found >= 0 ? lineIndex[found] : null;
    if (line && time > line.end + 4) line = null;
    const el = line ? line.el : null;
    const changed = el !== currentLine;
    if (changed) {
      if (currentLine) currentLine.classList.remove('current');
      if (el) el.classList.add('current');
      currentLine = el;
    }
    if (el && ((changed && playback.playing) || force)) scrollToLine(el, force);
  }

  function scrollToLine(el, force) {
    if (!force && Date.now() < manualScrollUntil) return;
    const content = $('content');
    const box = content.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    if (r.top < box.top + 40 || r.bottom > box.bottom - 60) {
      content.scrollBy({ top: r.top - box.top - box.height * 0.35, behavior: force || reducedMotion.matches ? 'auto' : 'smooth' });
    }
  }

  // ---------- AI 整理 ----------
  // 面板放在内容最上面，原地更新：进度条和步骤是平滑过去的；选课件时用户勾的东西不会因为别的更新被重置。

  let organizeBox = null;
  let organizeLayout = null;
  let organizeFor = null;

  const STEPS = () => [t('判断相关课件', 'Find related decks'), t('纠正转写', 'Correct transcript'), t('整理补充要点与课程安排', 'Extract supplements & arrangements')];

  /** 返回 true：面板换了阶段（新出现或换了样子），调用方把内容滚回顶部，让它露出来。 */
  function renderOrganize(animated) {
    const slot = $('organize-slot');
    const state = detail && detail.organize;
    const owner = detail && detail.id;
    if (!state) {
      if (organizeBox) {
        if (animated && organizeFor === owner) collapse(organizeBox); else organizeBox.remove();
      }
      organizeBox = null;
      organizeLayout = null;
      organizeFor = null;
      return false;
    }
    const layout = state.stage === 'finding' || state.stage === 'running' ? 'progress' : state.stage;
    if (organizeBox && organizeFor === owner && organizeLayout === layout) {
      if (layout === 'progress') updateProgress(organizeBox, state, true);
      if (layout === 'failed') organizeBox.querySelector('.org-message').textContent = state.message;
      return false;
    }
    const box = organizePanel(state);
    if (organizeBox && organizeFor === owner && animated) {
      morph(organizeBox, box);
    } else {
      if (organizeBox) organizeBox.remove();
      slot.appendChild(box);
      if (animated) expand(box);
    }
    organizeBox = box;
    organizeLayout = layout;
    organizeFor = owner;
    if (layout === 'progress') {
      updateProgress(box, state, false);
      if (!elapsedTimer) elapsedTimer = setInterval(tickElapsed, 1000);
    }
    return true;
  }

  /** 模型思考得久时，一步可能要几十秒：显示这一步已用的时间，让人知道还在进行。 */
  let elapsedTimer = 0;
  function tickElapsed() {
    if (!organizeBox || organizeLayout !== 'progress' || !organizeBox.isConnected) {
      clearInterval(elapsedTimer);
      elapsedTimer = 0;
      return;
    }
    const seconds = Math.floor((Date.now() - (organizeBox._since || Date.now())) / 1000);
    organizeBox.querySelector('.org-elapsed').textContent = seconds >= 3 ? clock(seconds) : '';
  }

  /** 进行中的面板：三步的状态、当前在做什么、这一步的进度。 */
  function updateProgress(box, state, animated) {
    const step = state.stage === 'finding' ? 1 : Math.max(1, Math.min(state.step || 2, 3));
    box.querySelectorAll('.org-steps li').forEach((li, i) => {
      li.classList.toggle('done', i + 1 < step);
      li.classList.toggle('current', i + 1 === step);
    });
    const message = state.stage === 'finding' ? t('正在判断本节课涉及的课件…', 'Identifying the decks this lecture covered…') : (state.message || '');
    const text = box.querySelector('.org-message');
    if (text.textContent !== message) {
      text.textContent = message;
      box._since = Date.now();
      tickElapsed();
      if (animated) animate(text, [{ opacity: 0.25, transform: 'translateY(2px)' }, { opacity: 1, transform: 'none' }], { duration: 220, easing: EASE });
    }
    const bar = box.querySelector('.org-bar');
    const fraction = state.total ? Math.min(1, state.done / state.total) : 0;
    bar.classList.toggle('idle', !state.total);
    if (!animated) bar.firstElementChild.style.transition = 'none';
    bar.firstElementChild.style.transform = `scaleX(${fraction})`;
    if (!animated) { void bar.offsetWidth; bar.firstElementChild.style.transition = ''; }
  }

  /** 整理的面板：进行中、选课件、出错。 */
  function organizePanel(state) {
    const box = document.createElement('div');
    box.className = 'organize';
    const cancel = () => post({ type: 'organizeCancel', id: detail.id });
    if (state.stage === 'finding' || state.stage === 'running') {
      box.innerHTML = `
        <div class="org-head"><strong>${t('AI 整理中', 'Organizing with AI')}</strong><span class="spacer"></span><button type="button" class="link">${t('取消', 'Cancel')}</button></div>
        <ol class="org-steps">${STEPS().map((label, i) => `<li><span class="step-dot">${ICON.check}<span class="num">${i + 1}</span></span><span class="step-label">${label}</span></li>`).join('')}</ol>
        <div class="org-status"><p class="org-message"></p><span class="org-elapsed clock" title="${t('当前这一步已用时', 'Time on this step')}"></span></div>
        <div class="org-bar idle"><div></div></div>`;
      box.querySelector('.link').addEventListener('click', cancel);
      return box;
    }
    if (state.stage === 'failed') {
      box.classList.add('failed');
      box.innerHTML = `
        <div class="org-head"><strong>${t('整理未完成', 'Organizing did not finish')}</strong></div>
        <p class="org-message">${escape(state.message)}</p>
        <div class="org-actions"><button type="button" class="primary retry">${t('重试', 'Try again')}</button><button type="button" class="link">${t('关闭', 'Close')}</button></div>`;
      box.querySelector('.retry').addEventListener('click', () => { post({ type: 'organizeCancel', id: detail.id }); post({ type: 'organize', id: detail.id }); });
      box.querySelector('.link').addEventListener('click', cancel);
      return box;
    }
    // choosing
    const decks = state.decks || [];
    const suggested = decks.filter((deck) => deck.suggested);
    const others = decks.filter((deck) => !deck.suggested);
    box.innerHTML = `
      <div class="org-head"><strong>${t('选择本节课涉及的课件', 'Choose the decks this lecture covered')}</strong></div>
      <p class="org-message">${decks.length
        ? (suggested.length ? t('已勾选 AI 判断的相关课件，可调整。', 'Decks identified by AI are selected; adjust as needed.') : t('AI 未找到明显相关的课件，请手动选择。', 'AI found no clearly related deck; select them manually.'))
        : t('课程文件夹中没有课件，将仅纠正转写并整理课程安排。', 'No decks in the course folder. Only the transcript will be corrected and course arrangements extracted.')}</p>
      <div class="deck-list"></div>
      <p class="org-note">${t('转写与所选课件的文字将发送给模型，按用量计费。', 'The transcript and the selected decks\' text will be sent to the model and billed by usage.')}</p>
      <div class="org-actions"><button type="button" class="primary start"></button><button type="button" class="link">${t('取消', 'Cancel')}</button></div>`;
    const list = box.querySelector('.deck-list');
    const row = (deck) => {
      const label = document.createElement('label');
      label.className = 'deck' + (deck.readable ? '' : ' unreadable');
      label.innerHTML = `<input type="checkbox" ${deck.suggested && deck.readable ? 'checked' : ''} ${deck.readable ? '' : 'disabled'} value="${escape(deck.path)}">
        <span class="deck-text"><span class="deck-title">${escape(deck.title)}${deck.recorded ? `<span class="tag">${t('录音时打开', 'Open during recording')}</span>` : ''}</span>
        <span class="deck-sub">${escape(deck.reason || (deck.readable ? deck.folder : t('尚未转换，需先打开一次', 'Not converted yet; open it once first')))}</span></span>`;
      return label;
    };
    suggested.forEach((deck) => list.appendChild(row(deck)));
    if (others.length) {
      const more = document.createElement('details');
      more.open = suggested.length === 0;
      more.innerHTML = `<summary>${t(`其他 ${others.length} 份课件`, `${others.length} other decks`)}</summary>`;
      others.forEach((deck) => more.appendChild(row(deck)));
      // 展开时一行一行淡入
      more.addEventListener('toggle', () => {
        if (!more.open) return;
        [...more.querySelectorAll('.deck')].forEach((el, i) =>
          animate(el, [{ opacity: 0, transform: 'translateY(-3px)' }, { opacity: 1, transform: 'none' }], { duration: 200, delay: Math.min(i, 8) * 18, easing: EASE, fill: 'backwards' }));
      });
      list.appendChild(more);
    }
    const start = box.querySelector('.start');
    const update = () => {
      const count = box.querySelectorAll('input:checked').length;
      start.textContent = count ? t(`开始整理（${count} 份课件）`, `Start (${count} ${count === 1 ? 'deck' : 'decks'})`) : t('仅整理课程安排', 'Course arrangements only');
    };
    box.addEventListener('change', update);
    update();
    start.addEventListener('click', () => {
      const paths = [...box.querySelectorAll('input:checked')].map((input) => input.value);
      post({ type: 'organizeConfirm', id: detail.id, decks: paths });
    });
    box.querySelector('.link').addEventListener('click', cancel);
    return box;
  }

  /** 补充要点：按课件分组、按页排好；课件以外的放最后。 */
  function supplementsView(list) {
    const box = document.createElement('div');
    box.className = 'supplements';
    const groups = new Map();
    for (const item of list) {
      const key = item.deck || '';
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(item);
    }
    const keys = [...groups.keys()].sort((a, b) => (a === '') - (b === '') || a.localeCompare(b));
    for (const key of keys) {
      const rows = groups.get(key).sort((a, b) => (a.page || 0) - (b.page || 0) || a.t - b.t);
      const section = document.createElement('section');
      section.innerHTML = `<h3>${escape(key ? rows[0].deckTitle : t('未对应课件页', 'Not tied to a slide'))}<span class="count">${rows.length}</span></h3>`;
      for (const item of rows) {
        const row = document.createElement('div');
        row.className = 'supp';
        row.innerHTML = `
          ${item.page ? `<button type="button" class="page" title="${t('在课件中打开此页', 'Open this page')}">p.${item.page}</button>` : '<span class="page none">—</span>'}
          <div class="supp-body">
            <p class="point">${escape(item.point)}</p>
            ${item.quote ? `<p class="quote">“${escape(item.quote)}”</p>` : ''}
          </div>
          <button type="button" class="ts-button" title="${t('从此处播放', 'Play from here')}">${ICON.play}<span>${clock(item.t, detail.duration >= 3600)}</span></button>`;
        const page = row.querySelector('button.page');
        if (page) page.addEventListener('click', () => post({ type: 'openPage', deck: item.deck, page: item.page }));
        row.querySelector('.ts-button').addEventListener('click', () => seek(item.t, true));
        section.appendChild(row);
      }
      box.appendChild(section);
    }
    return box;
  }

  /** 课程安排：按时间排；提到某页时可以打开那一页。 */
  function arrangementsView(list) {
    const box = document.createElement('div');
    box.className = 'supplements arrangements';
    for (const item of list.slice().sort((a, b) => a.t - b.t)) {
      const row = document.createElement('div');
      row.className = 'supp';
      row.innerHTML = `
        <button type="button" class="ts-button lead" title="${t('从此处播放', 'Play from here')}">${ICON.play}<span>${clock(item.t, detail.duration >= 3600)}</span></button>
        <div class="supp-body">
          <p class="point">${escape(item.point)}</p>
          ${item.quote ? `<p class="quote">“${escape(item.quote)}”</p>` : ''}
        </div>
        ${item.page ? `<button type="button" class="page" title="${t('在课件中打开此页', 'Open this page')}">${escape(item.deckTitle || '')} p.${item.page}</button>` : '<span></span>'}`;
      row.querySelector('.ts-button').addEventListener('click', () => seek(item.t, true));
      const page = row.querySelector('button.page');
      if (page) page.addEventListener('click', () => post({ type: 'openPage', deck: item.deck, page: item.page }));
      box.appendChild(row);
    }
    return box;
  }

  // ---------- 菜单 ----------
  // 标题栏右边两个菜单：“导出”（转写、纠正版、补充要点、课程安排、音频）和“更多”（重命名、标签、访达、删除）。

  let menuFor = null;

  function organize() {
    if (!detail || detail.status !== 'ready') return;
    post({ type: 'organize', id: detail.id });
    if (!native) window.__demo.finding();
  }

  function menuEntries(kind) {
    const d = detail;
    if (kind === 'export') {
      const lines = !!(d.lines && d.lines.length);
      const entries = [
        ['exportTab', 'transcript', t('转写', 'Transcript'), t('文本', 'Text'), lines],
        ['exportTab', 'corrected', t('纠正版', 'Corrected transcript'), t('文本', 'Text'), !!d.corrections],
        ['exportTab', 'supplements', t('补充要点', 'Supplements'), 'Markdown', !!d.supplements],
        ['exportTab', 'arrangements', t('课程安排', 'Course arrangements'), 'Markdown', !!d.supplements],
        null,
        ['exportAudio', '', t('音频', 'Audio'), 'm4a', d.status === 'ready' || d.status === 'transcribing'],
      ];
      return `<div class="menu-title">${t('导出', 'Export')}</div>` + entries.map((e) => (e
        ? `<button type="button" role="menuitem" data-action="${e[0]}" data-tab="${e[1]}" ${e[4] ? '' : 'disabled'}><span>${e[2]}…</span><span class="hint">${e[3]}</span></button>`
        : '<hr>')).join('');
    }
    const entries = [
      ['rename', t('重命名…', 'Rename…')],
      ['editTags', t('编辑标签…', 'Edit Tags…')],
      ['reveal', t('在访达中显示', 'Show in Finder')],
      null,
      ['retranscribe', t('重新转写…', 'Re-transcribe…'), '', d.status !== 'ready'],
      null,
      ['delete', t('删除录音…', 'Delete Recording…'), 'danger'],
    ];
    return entries.map((e) => (e ? `<button type="button" role="menuitem" data-action="${e[0]}" class="${e[2] || ''}" ${e[3] ? 'disabled' : ''}>${e[1]}</button>` : '<hr>')).join('');
  }

  function openMenu(kind) {
    if (!detail) return;
    const menu = $('menu');
    if (menuFor === kind) { closeMenu(); return; }
    if (menuFor) $(menuFor).classList.remove('open');
    menu.getAnimations().forEach((a) => a.cancel());
    menuFor = kind;
    menu.innerHTML = menuEntries(kind);
    menu.hidden = false;
    const anchorRect = $(kind).getBoundingClientRect();
    menu.style.top = `${anchorRect.bottom + 6}px`;
    menu.style.left = `${Math.max(8, Math.min(anchorRect.right - menu.offsetWidth, window.innerWidth - menu.offsetWidth - 8))}px`;
    $(kind).classList.add('open');
    animate(menu, [{ opacity: 0, transform: 'translateY(-4px) scale(0.98)' }, { opacity: 1, transform: 'none' }], { duration: 160, easing: EASE });
  }

  function closeMenu() {
    const menu = $('menu');
    if (menu.hidden || menuFor === null) return;
    if (menuFor) $(menuFor).classList.remove('open');
    menuFor = null;
    const a = animate(menu, [{ opacity: 1 }, { opacity: 0, transform: 'translateY(-2px)' }], { duration: 120, easing: 'ease-in' });
    if (a) a.onfinish = () => { if (menuFor === null) menu.hidden = true; };
    else menu.hidden = true;
  }

  let toastTimer = 0;
  function toast(message) {
    const el = $('toast');
    el.textContent = message;
    el.classList.add('visible');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('visible'), 1800);
  }

  // ---------- 没有录音 ----------

  function showEmpty(show) {
    const empty = $('empty');
    if (empty.hidden === !show) return;
    empty.hidden = !show;
    if (!show) return;
    empty.querySelector('.empty-icon').innerHTML = ICON.mic;
    $('empty-text').innerHTML = t(
      '暂无课堂录音<br>打开课件后，点按工具栏中的麦克风或按 <kbd>⇧⌘R</kbd> 开始录音。',
      'No lectures yet<br>Open a deck, then click the microphone in the toolbar or press <kbd>⇧⌘R</kbd>.');
    $('empty-import').textContent = t('导入音频…', 'Import Audio…');
    enter(empty.firstElementChild, 6, 300);
    enter($('empty-text'), 6, 300);
  }

  // ---------- 事件 ----------

  function setup() {
    document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
    $('play').innerHTML = `<span class="i-play">${ICON.play}</span><span class="i-pause">${ICON.pause}</span>`;
    $('back').innerHTML = ICON.back;
    $('forward').innerHTML = ICON.forward;
    $('export').innerHTML = ICON.export;
    $('import').innerHTML = ICON.import;
    const importAudio = () => {
      post({ type: 'import' });
      if (!native) toast(t('（示例）这里会打开文件选择', '(Demo) A file picker would open here'));
    };
    $('import').addEventListener('click', importAudio);
    $('empty-import').addEventListener('click', importAudio);
    $('more').innerHTML = ICON.more;
    $('play').addEventListener('click', togglePlay);
    $('back').addEventListener('click', () => seek(displayTime() - 15));
    $('forward').addEventListener('click', () => seek(displayTime() + 15));
    $('rate').addEventListener('click', cycleRate);
    $('organize').addEventListener('click', organize);
    for (const kind of ['export', 'more']) {
      $(kind).addEventListener('click', (event) => { event.stopPropagation(); openMenu(kind); });
    }
    $('menu').addEventListener('click', (event) => {
      const button = event.target.closest('button');
      if (!button || button.disabled || !detail) return;
      closeMenu();
      const action = button.dataset.action;
      if (action === 'exportTab') post({ type: action, id: detail.id, tab: button.dataset.tab });
      else post({ type: action, id: detail.id });
      if (!native) toast(t('（示例）', '(Demo) ') + (button.firstElementChild || button).textContent);
    });
    document.addEventListener('click', (event) => { if (!event.target.closest('#menu')) closeMenu(); });
    window.addEventListener('blur', closeMenu);
    $('tabs').addEventListener('click', (event) => {
      const button = event.target.closest('button[data-tab]');
      if (button) switchTab(button.dataset.tab);
    });
    let searchTimer = 0;
    $('search-input').addEventListener('input', (event) => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => { query = event.target.value; renderContent(false); }, 180);
    });
    $('content').addEventListener('wheel', () => { manualScrollUntil = Date.now() + 4000; }, { passive: true });
    $('list-search-input').addEventListener('input', (event) => { listQuery = event.target.value; renderList(true); });
    $('meta').addEventListener('click', (event) => {
      const chip = event.target.closest('.tag-filter');
      if (!chip) return;
      listQuery = chip.dataset.tag;
      $('list-search-input').value = listQuery;
      renderList(true);
    });
    document.addEventListener('keydown', (event) => {
      if (event.target.tagName === 'INPUT') return;
      if (event.key === ' ') { event.preventDefault(); togglePlay(); }
      if (event.key === 'Escape') closeMenu();
    });
    window.addEventListener('resize', () => { closeMenu(); moveIndicator(false); });
    setupScrubber();
  }

  // ---------- 原生端接口 ----------

  window.Recordings = {
    setList(payload) {
      const relabel = payload.lang && payload.lang !== lang;
      if (payload.lang) lang = payload.lang;
      items = payload.items || [];
      if (payload.selected !== undefined) selected = payload.selected;
      showEmpty(items.length === 0);
      renderList();
      if (relabel && detail) renderDetail(true);
    },
    showDetail(payload) {
      const same = !!detail && detail.id === payload.id;
      if (!same) { tab = 'transcript'; query = ''; $('search-input').value = ''; closeMenu(); }
      detail = payload;
      selected = payload.id;
      renderList();
      renderDetail(same);
      if (!same) {
        // 换了一条录音：标题淡入，内容淡入并稍微上移
        fadeIn($('title'));
        fadeIn($('meta'));
        enter($('content'), 8, 260);
      }
    },
    setPlayback(payload) { applyPlayback(payload, true); },
    toast(message) { toast(message); },
    setLive(payload) {
      if (!detail) return;
      detail.live = payload;
      const row = $('live');
      if (!row) return;
      // 原地改字：红点的呼吸不会被打断
      row.querySelector('.final').textContent = payload.text || '';
      row.querySelector('.volatile').textContent = payload.volatile || '';
    },
  };

  setup();
  if (native) {
    document.documentElement.classList.add('in-app');
    post({ type: 'ready' });
    return;
  }

  // ---------- 浏览器里直接打开：示例数据 ----------

  const SENTENCES = [
    'Okay, let\'s get started.', 'Today we\'re finishing processes and moving on to threads.',
    'Remember from last week that every process has a process control block, or PCB.',
    'The PCB stores the process state, the program counter and the registers.',
    'When the scheduler decides to run a different process, the kernel performs a context switch.',
    'It saves the registers of the current process into its PCB and loads the registers of the next one.',
    'Context switches are pure overhead, so we want to keep them cheap.',
    'Now, this is not on the slides, but it came up in the exam last year.',
    'A lot of you confused the time quantum with the response time, so please be careful.',
    'The quantum is how long a process may run before it is preempted.',
    'The response time is how long it takes until a process runs for the first time.',
    'Let me draw this on the board.', 'Suppose we have three processes, A, B and C, arriving at time zero.',
    'With a quantum of ten milliseconds, A runs first, then B, then C.',
    'So C waits twenty milliseconds before it gets the CPU for the first time.',
    'If the quantum is too long, round robin behaves like first come, first served.',
    'If it is too short, we spend all our time switching.',
    'In practice, systems use something between ten and a hundred milliseconds.',
    'Any questions so far?', 'Yes, in the back.',
    'Good question: does the kernel itself count as a process?', 'Not quite. The kernel runs on behalf of processes.',
    'Okay, threads.', 'A thread is a unit of execution inside a process.',
    'Threads in the same process share the address space, but each has its own stack and registers.',
    'That is exactly why creating a thread is much cheaper than creating a process.',
    'On page twelve you can see the difference between user-level and kernel-level threads.',
    'With user-level threads, the kernel only sees one process.',
    'So if one thread blocks on I/O, the whole process blocks.',
    'This is the many-to-one model, and almost nobody uses it any more.',
    'Linux uses the one-to-one model: every user thread is a kernel thread.',
    'Next week we\'ll look at synchronization: locks, semaphores and monitors.',
    'Please read chapter five before the lecture.', 'Dijkstra introduced semaphores in nineteen sixty-five.',
    'A semaphore is an integer with two atomic operations, wait and signal.',
  ];

  function demoLines(segments) {
    const lines = [];
    let next = 0;
    let offset = 0;
    for (const segment of segments) {
      if (segment.state !== 'complete') continue;
      if (segment.transcribed) {
        let time = offset + 2;
        const count = Math.min(12, SENTENCES.length - next);
        for (let i = 0; i < count; i += 1) {
          const text = SENTENCES[next++];
          const duration = 1.2 + text.length * 0.055;
          lines.push({ segment: segment.index, start: time - offset, t: time, end: time + duration, text });
          time += duration + (i % 4 === 3 ? 5 : 0.4);
        }
      }
      offset += segment.duration;
    }
    return lines;
  }

  const now = new Date();
  const at = (daysAgo, h, m) => new Date(now.getFullYear(), now.getMonth(), now.getDate() - daysAgo, h, m).getTime();
  const DEMO = {
    live: { id: 'live', title: '第 5 章 CPU 调度', course: '操作系统', tags: ['COMP3021'], startedAt: at(0, 16, 10), duration: 2538, elapsed: 2538, status: 'recording', locale: 'en_US', deck: '05-scheduling.pdf',
      segments: [1, 2, 3, 4, 5, 6, 7, 8].map((i) => ({ index: i, duration: 300, state: 'complete', transcribed: i < 8 })).concat([{ index: 9, duration: 0, state: 'recording', transcribed: false }]),
      live: { text: 'So the shortest job first algorithm is optimal for average waiting time,', volatile: 'but the problem is we usually don\'t know how long' } },
    a: { id: 'a', title: '第 4 章 进程与线程', course: '操作系统', tags: ['COMP3021', 'Week 4'], startedAt: at(0, 14, 30), status: 'ready', locale: 'en_US', deck: '04-processes-threads.pdf',
      segments: [
        { index: 1, duration: 300, state: 'complete', transcribed: true },
        { index: 2, duration: 300, state: 'complete', transcribed: true },
        { index: 3, duration: 0, state: 'damaged', transcribed: false },
        { index: 4, duration: 300, state: 'complete', transcribed: true },
        { index: 5, duration: 214, state: 'complete', transcribed: true },
      ] },
    b: { id: 'b', title: '第 3 章 内存管理', course: '操作系统', tags: ['COMP3021'], startedAt: at(5, 14, 30), duration: 5712, status: 'ready', organized: true, locale: 'en_GB', deck: '03-memory.pdf',
      segments: [{ index: 1, duration: 300, state: 'complete', transcribed: true }, { index: 2, duration: 300, state: 'complete', transcribed: true }], supplements: [] },
    c: { id: 'c', title: 'Red-Black Trees', course: '数据结构与算法', tags: ['ADS205'], startedAt: at(4, 9, 0), duration: 7360, status: 'ready', locale: 'en_GB', deck: 'L07-rbtrees.pdf',
      segments: [{ index: 1, duration: 300, state: 'complete', transcribed: true }] },
  };
  for (const r of Object.values(DEMO)) {
    r.lines = demoLines(r.segments);
    if (r.duration === undefined) r.duration = r.segments.filter((s) => s.state === 'complete').reduce((sum, s) => sum + s.duration, 0);
  }
  DEMO.b.supplements = [
    { deck: '/c/03-memory.pdf', deckTitle: '03-memory', page: 3, point: '早期系统直接用物理地址，一个程序写错就可能改掉别的程序的内存，这是引入 memory protection 的直接原因。', quote: 'back in the day you just used physical addresses, and one bad pointer could overwrite someone else', t: 95 },
    { deck: '/c/03-memory.pdf', deckTitle: '03-memory', page: 9, point: '用图书馆索引卡片类比多级页表：先找到书架（外层页表），再在那一格里找卡片（内层页表）。', quote: 'think of it like the card catalogue in a library', t: 595 },
    { deck: '/c/03-memory.pdf', deckTitle: '03-memory', page: 14, point: 'TLB 命中率从 80% 提到 98% 时 EAT 下降得比把 TLB 做快还多，结论是命中率比 TLB 本身的速度更重要。', quote: 'the hit ratio matters far more than how fast the TLB itself is', t: 2102 },
    { point: 'Linux 在 x86-64 上用四级页表，新的处理器支持五级页表（LA57）。', quote: 'Linux actually uses four levels, and newer chips support five', t: 2530 },
    { kind: 'arrangement', point: '期中考试在第 8 周周三上午 9 点，范围是第 1–4 章，闭卷，可以带一张 A4 手写笔记。', quote: 'the midterm is on Wednesday of week eight at nine', t: 3320 },
    { kind: 'arrangement', deck: '/c/03-memory.pdf', deckTitle: '03-memory', page: 14, point: 'EAT 的计算一定会考，单位（ns）要写清楚，去年很多人漏写被扣分。', quote: 'please write the units, last year a lot of people lost marks', t: 2910 },
    { kind: 'arrangement', point: '作业 3 的截止时间推迟到下周五晚上 11:59。', quote: 'assignment three is now due next Friday', t: 5480 },
  ];
  DEMO.a.corrections = [
    { segment: DEMO.a.lines[2].segment, start: DEMO.a.lines[2].start, text: DEMO.a.lines[2].text.replace('process control block', 'process control block (PCB)') },
    { segment: DEMO.a.lines[5].segment, start: DEMO.a.lines[5].start, text: DEMO.a.lines[5].text.replace('loads', 'restores') },
  ];

  function demoSelect(id) {
    demoPlay(false);
    applyPlayback({ time: id === 'a' ? 41 : 0, playing: false });
    window.Recordings.showDetail({ ...DEMO[id] });
  }

  /** 模拟原生端：播放时每 0.25 秒报一次时间。 */
  let demoTimer = 0;
  function demoPlay(playing) {
    clearInterval(demoTimer);
    if (!playing) return;
    let time = displayTime();
    demoTimer = setInterval(() => {
      time += 0.25 * playback.rate;
      if (time >= detail.duration) { clearInterval(demoTimer); window.Recordings.setPlayback({ time: detail.duration, playing: false }); return; }
      window.Recordings.setPlayback({ time });
    }, 250);
  }

  window.Recordings.setList({
    lang,
    selected: 'a',
    items: [DEMO.live, DEMO.a, DEMO.b, DEMO.c].map(({ id, title, course, tags, startedAt, duration, status, supplements, elapsed }) =>
      ({ id, title, course, tags, startedAt, duration, status, organized: !!supplements, elapsed })),
  });
  demoSelect('a');

  const demoDecks = [
    { path: '/c/04.pdf', title: '04-processes-threads', folder: 'Lectures', readable: true, suggested: true, recorded: true, reason: '讲到了 PCB、上下文切换和线程模型，和这份课件的内容一致。' },
    { path: '/c/05.pdf', title: '05-scheduling', folder: 'Lectures', readable: true, suggested: true, reason: '后半段讲了 round robin 和时间片，对应调度这一章的开头。' },
    { path: '/c/03.pdf', title: '03-memory', folder: 'Lectures', readable: true, suggested: false, reason: '' },
    { path: '/c/t09.pptx', title: 'Tutorial09', folder: 'Tutorial', readable: false, suggested: false, reason: '' },
  ];
  window.__demo = {
    select: demoSelect,
    play: () => { applyPlayback({ playing: true }); demoPlay(true); },
    lang: (code) => { lang = code; document.documentElement.lang = code === 'zh' ? 'zh-CN' : 'en'; renderList(); renderDetail(true); },
    tab: (key) => switchTab(key),
    empty: () => window.Recordings.setList({ items: [] }),
    organize: (state) => window.Recordings.showDetail({ ...detail, organize: state }),
    finding: () => window.__demo.organize({ stage: 'finding' }),
    choosing: () => window.__demo.organize({ stage: 'choosing', decks: demoDecks }),
    running: (step = 2, done = 2, total = 8) => window.__demo.organize({ stage: 'running', step, message: step === 2 ? `纠正转写（第 ${done}/${total} 部分）` : `对照课件找补充要点（第 ${done}/${total} 部分）`, done, total }),
    failed: () => window.__demo.organize({ stage: 'failed', message: '模型没有返回能读懂的结果。' }),
    done: () => window.__demo.organize(undefined),
    menu: (kind) => openMenu(kind),
    detail: () => detail,
  };
  if (/[?&]lang=(zh|en)/.test(location.search)) window.__demo.lang(RegExp.$1);
})();
