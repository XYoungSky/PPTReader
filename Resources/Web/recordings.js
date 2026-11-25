// 课堂录音窗口：左边是录音列表（按课程分组），右边是回放、转写，以及整理出的补充要点和课程安排。
// 原生端调用：
//   Recordings.setList({lang, items, selected})
//     items: [{id, title, course, tags, startedAt(毫秒), duration(秒), status: 'recording'|'transcribing'|'ready', organized, elapsed?}]
//   Recordings.showDetail({id, title, startedAt, duration, locale, deck, status, segments, lines, live, supplements, organize})
//     supplements: [{kind: 'supplement'|'arrangement', deck, deckTitle, page, point, quote, t}]（整理过才有）
//     corrections: [{segment, start, text}]：纠正过的句子（整理过才有）；lines 里的 segment + start 对得上
//     segments: [{index, duration, state: 'complete'|'damaged'|'recording', transcribed, queued}]
//     lines: [{t, end, text}]，t 是录音时间（秒，已按分段换算好）；segment 标出所属分段
//   Recordings.setPlayback({time, playing, rate})
//   Recordings.setLive({text, volatile})  正在录音时的实时字幕
//   Recordings.toast(message)
// 发回原生端：ready / select / play / pause / seek / rate / skip / organize / rename / reveal / exportAudio / exportText / delete
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
  /** 上次显示的整理阶段：阶段变了就滚回顶部，让面板露出来。 */
  let shownOrganizeStage = null;

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

  function matchesList(item) {
    const needle = listQuery.trim().toLowerCase();
    if (!needle) return true;
    const when = day(item.startedAt);
    return [item.title, item.course, when.date, ...(item.tags || [])].some((field) => (field || '').toLowerCase().includes(needle));
  }

  function renderList() {
    $('list-title').textContent = t('课堂录音', 'Lectures');
    $('list-search-input').placeholder = t('搜索标题、标签、日期', 'Search titles, tags, dates');
    const list = $('list');
    list.textContent = '';
    const groups = new Map();
    const shown = items.filter(matchesList);
    if (!shown.length && items.length) {
      const none = document.createElement('div');
      none.className = 'group';
      none.textContent = t('没有找到', 'No matches');
      list.appendChild(none);
    }
    for (const item of shown) {
      // 按第一个标签（通常是课程编号）分组，没有标签时按课程文件夹
      const key = (item.tags && item.tags[0]) || item.course || t('未归入课程', 'No course');
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(item);
    }
    for (const [course, group] of groups) {
      const header = document.createElement('div');
      header.className = 'group';
      header.textContent = course;
      header.title = course;
      list.appendChild(header);
      for (const item of group) list.appendChild(listItem(item));
    }
  }

  function listItem(item) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'item' + (item.id === selected ? ' selected' : '');
    const when = day(item.startedAt);
    let status = '';
    if (item.status === 'recording') status = `<span class="badge"><span class="rec-dot"></span>${t('录音中', 'Recording')}</span>`;
    else if (item.status === 'transcribing') status = `<span class="badge"><span class="spinner"></span>${t('转写中', 'Transcribing')}</span>`;
    else if (item.organized) status = `<span class="badge done">${ICON.check}${t('已整理', 'Organized')}</span>`;
    const duration = item.status === 'recording' ? clock(item.elapsed || item.duration, true) : length(item.duration);
    button.innerHTML = `
      <div class="name"><span>${escape(item.title)}</span>${status}</div>
      <div class="sub"><span>${when.date} ${when.time}</span><span>·</span><span>${duration}</span></div>`;
    button.addEventListener('click', () => {
      if (item.id === selected) return;
      selected = item.id;
      renderList();
      post({ type: 'select', id: item.id });
      if (!native) demoSelect(item.id);
    });
    return button;
  }

  // ---------- 详情 ----------

  function renderDetail(keepScroll) {
    const d = detail;
    if (!d) return;
    const recording = d.status === 'recording';
    $('title').textContent = d.title;
    $('title').title = d.title;
    const when = day(d.startedAt);
    const parts = [`${when.date} ${when.time}`, recording ? t('正在录音', 'Recording now') : length(d.duration), localeName(d.locale)];
    if (d.deck) parts.push(escape(d.deck));
    $('meta').innerHTML = (d.tags || []).map((tag) => `<button type="button" class="chip tag-filter" data-tag="${escape(tag)}" title="${t('列出这个标签的录音', 'Show recordings with this tag')}">${escape(tag)}</button>`).join('')
      + parts.map((p) => `<span>${p}</span>`).join('<span class="dot">·</span>');

    const organize = $('organize');
    organize.innerHTML = ICON.sparkles + `<span>${d.supplements ? t('重新整理', 'Organize again') : t('AI 整理', 'Organize with AI')}</span>`;
    organize.disabled = d.status !== 'ready' || !!d.organize;
    organize.title = d.status === 'ready'
      ? t('找出相关课件，再找出课件上没有的内容和课程安排', 'Find the related decks, then what isn\'t on the slides and anything about how the course runs')
      : t('录音和转写完成后可以整理', 'Available once recording and transcription finish');
    $('more').innerHTML = ICON.more;
    $('more').title = t('更多', 'More');

    $('back').innerHTML = ICON.back;
    $('forward').innerHTML = ICON.forward;
    $('back').title = t('后退 15 秒', 'Back 15 seconds');
    $('forward').title = t('前进 15 秒', 'Forward 15 seconds');
    for (const id of ['back', 'forward', 'play', 'rate']) $(id).disabled = recording;
    $('player').style.opacity = recording ? 0.5 : 1;
    $('duration').textContent = clock(d.duration, d.duration >= 3600);
    renderTicks();
    renderPlayback();

    const count = (kind) => (d.supplements || []).filter((item) => (item.kind || 'supplement') === kind).length;
    const fixes = (d.corrections || []).length;
    const tabs = [
      ['transcript', t('转写', 'Transcript'), ''],
      ['corrected', t('纠正版', 'Corrected'), d.corrections ? String(fixes) : ''],
      ['supplements', t('补充要点', 'Supplements'), count('supplement') ? String(count('supplement')) : ''],
      ['arrangements', t('课程安排', 'Course arrangements'), count('arrangement') ? String(count('arrangement')) : ''],
    ];
    $('tabs').innerHTML = tabs.map(([key, label, count]) =>
      `<button type="button" role="tab" data-tab="${key}" class="${key === tab ? 'active' : ''}">${label}${count ? `<span class="count">${count}</span>` : ''}</button>`).join('');
    $('search').style.visibility = tab === 'transcript' || tab === 'corrected' ? 'visible' : 'hidden';
    $('search-input').placeholder = t('搜索转写', 'Search transcript');
    renderContent(keepScroll);
  }

  /** 进度条上标出分段的接缝；损坏的分段在接缝处标红（那段没录下来）。 */
  function renderTicks() {
    const ticks = $('scrubber').querySelector('.ticks');
    ticks.textContent = '';
    const d = detail;
    if (!d || !d.duration) return;
    let offset = 0;
    let gapBefore = false;
    d.segments.forEach((segment, i) => {
      if (segment.state === 'damaged') { gapBefore = true; return; }
      if (segment.state !== 'complete') return;
      if (i > 0 && offset > 0) {
        const tick = document.createElement('div');
        tick.className = 'tick' + (gapBefore ? ' gap' : '');
        tick.style.left = `${(offset / d.duration) * 100}%`;
        if (gapBefore) tick.title = t('这里有一段没有录下', 'A segment is missing here');
        ticks.appendChild(tick);
      }
      gapBefore = false;
      offset += segment.duration;
    });
  }

  function renderPlayback() {
    const d = detail;
    const duration = (d && d.duration) || 1;
    const fraction = Math.min(1, Math.max(0, playback.time / duration));
    $('scrubber').querySelector('.fill').style.width = `${fraction * 100}%`;
    $('scrubber').querySelector('.knob').style.left = `${fraction * 100}%`;
    $('time').textContent = clock(playback.time, duration >= 3600);
    $('play').innerHTML = playback.playing ? ICON.pause : ICON.play;
    $('play').title = playback.playing ? t('暂停', 'Pause') : t('播放', 'Play');
    $('rate').textContent = `${playback.rate}×`;
    $('rate').title = t('播放速度', 'Playback speed');
    highlightCurrent();
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

  /** 整理阶段变了：滚回顶部。返回 true 时不再滚到当前句。 */
  function revealOrganize() {
    const stage = detail && detail.organize ? detail.organize.stage : null;
    const changed = stage !== shownOrganizeStage;
    shownOrganizeStage = stage;
    if (stage && changed) { $('content').scrollTop = 0; return true; }
    return !!stage && $('content').scrollTop === 0;
  }

  function renderContent(keepScroll) {
    const content = $('content');
    content.textContent = '';
    const d = detail;
    if (d.organize) content.appendChild(organizePanel(d.organize));
    if (tab !== 'transcript') revealOrganize();
    if (tab === 'supplements' || tab === 'arrangements') {
      const kind = tab === 'supplements' ? 'supplement' : 'arrangement';
      const items = (d.supplements || []).filter((item) => (item.kind || 'supplement') === kind);
      if (items.length) {
        content.appendChild(kind === 'supplement' ? supplementsView(items) : arrangementsView(items));
      } else if (d.supplements) {
        content.appendChild(kind === 'supplement'
          ? placeholder(t('没有找到补充要点', 'No supplements'), t('老师讲的内容课件上基本都有。', 'Almost everything the lecturer said is already on the slides.'), true)
          : placeholder(t('没有提到课程安排', 'No course arrangements'), t('这节课没有说到考试、作业或进度这类安排。', 'Nothing was said about exams, assignments or the schedule.'), true));
      } else if (!d.organize) {
        content.appendChild(kind === 'supplement'
          ? placeholder(t('还没有补充要点', 'No supplements yet'),
            t('点「AI 整理」后，这里会列出老师讲了、课件上没有的内容，对应到课件的页；点时间可以跳回录音。',
              'After you organize this lecture, what the lecturer said that isn\'t on the slides is listed here, matched to slide pages; click a time to jump back to the recording.'))
          : placeholder(t('还没有课程安排', 'No course arrangements yet'),
            t('点「AI 整理」后，这里会列出考试、作业和截止日期、进度变动这类和课程安排有关的内容。',
              'After you organize this lecture, anything about exams, assignments, deadlines or schedule changes is listed here.')));
      }
      return;
    }

    if (tab === 'corrected' && !d.corrections) {
      if (!d.organize) {
        content.appendChild(placeholder(t('还没有纠正版', 'No corrected version yet'),
          t('点「AI 整理」后，会参照课件改正转写里听错的术语、人名和数字（只改识别错误，不改写），改过的地方会标出来。',
            'After you organize this lecture, misheard terms, names and numbers are fixed using the slides (recognition errors only, no rewriting), and every change is marked.')));
      }
      return;
    }
    const fixedText = new Map((tab === 'corrected' ? d.corrections : []).map((fix) => [`${fix.segment}:${Number(fix.start).toFixed(3)}`, fix.text]));
    if (tab === 'corrected') {
      const summary = document.createElement('p');
      summary.className = 'fix-summary';
      summary.textContent = fixedText.size
        ? t(`改了 ${fixedText.size} 句，改动的词标了底色；鼠标停在上面可以看到原文。`, `${fixedText.size} lines fixed; changed words are highlighted, hover to see the original.`)
        : t('没有发现需要改正的地方。', 'Nothing needed fixing.');
      content.appendChild(summary);
    }
    const bySegment = new Map();
    for (const line of d.lines) {
      if (!bySegment.has(line.segment)) bySegment.set(line.segment, []);
      bySegment.get(line.segment).push(line);
    }
    const needle = query.trim().toLowerCase();
    let matches = 0;
    for (const segment of d.segments) {
      if (segment.state === 'damaged') {
        content.appendChild(notice('gap', t(`第 ${segment.index} 段没有录下来：录音时应用意外退出，这一段的音频和文字都没能保存。`,
          `Segment ${segment.index} was lost: the app quit unexpectedly while recording it.`)));
        continue;
      }
      const lines = bySegment.get(segment.index) || [];
      for (const para of paragraphs(lines)) {
        const row = document.createElement('div');
        row.className = 'para';
        const stamp = document.createElement('span');
        stamp.className = 'stamp clock';
        stamp.textContent = clock(para.t, d.duration >= 3600);
        stamp.title = t('从这里播放', 'Play from here');
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
          if (needle) {
            const re = new RegExp(needle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
            html = html.replace(re, (m) => { matches += 1; return `<mark>${m}</mark>`; });
          }
          span.innerHTML = html + ' ';
          span.addEventListener('click', () => {
            if (window.getSelection().toString()) return;   // 选文字复制时不跳
            seek(line.t, true);
          });
          text.appendChild(span);
        }
        row.append(stamp, text);
        content.appendChild(row);
      }
      if (segment.state === 'complete' && !segment.transcribed) {
        content.appendChild(segment.queued === false
          ? notice('pending', t(`第 ${segment.index} 段还没有转写（上次转写失败），下次打开应用时会重试。`,
            `Segment ${segment.index} isn't transcribed yet (the last attempt failed); it will be retried next time the app opens.`))
          : notice('pending', t(`正在转写第 ${segment.index} 段…`, `Transcribing segment ${segment.index}…`), true));
      }
    }
    if (d.status === 'recording') content.appendChild(liveRow());
    if (!d.lines.length && d.status !== 'recording' && !d.segments.some((s) => s.state === 'complete' && !s.transcribed)) {
      content.appendChild(placeholder(t('没有转写内容', 'No transcript'), t('这段录音里没有识别出说话的声音。', 'No speech was recognized in this recording.')));
    }
    if (needle) toast(matches ? t(`找到 ${matches} 处`, `${matches} matches`) : t('没有找到', 'No matches'));
    if (revealOrganize()) return;
    highlightCurrent(!keepScroll);
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
      <p class="text"><span class="final">${escape(live.text)}</span> <span class="volatile">${escape(live.volatile)}</span></p>`;
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

  // ---------- AI 整理 ----------

  /** 整理的进度：判断课件、选课件、进行中、出错。 */
  function organizePanel(state) {
    const box = document.createElement('div');
    box.className = 'organize';
    const cancel = () => post({ type: 'organizeCancel', id: detail.id });
    if (state.stage === 'finding' || state.stage === 'running') {
      const fraction = state.total ? Math.min(1, state.done / state.total) : 0;
      const step = state.stage === 'finding' ? 1 : Math.min(state.step, 3);
      const message = state.stage === 'finding' ? t('正在判断这节课讲了哪几份课件…', 'Finding which decks this lecture covered…') : state.message;
      box.innerHTML = `
        <div class="org-head"><span class="spinner"></span><strong>${t(`AI 整理 · 第 ${step} 步，共 3 步`, `Organizing · step ${step} of 3`)}</strong><span class="spacer"></span><button type="button" class="link">${t('取消', 'Cancel')}</button></div>
        <p class="org-message">${escape(message)}</p>
        ${state.total ? `<div class="org-bar"><div style="width:${fraction * 100}%"></div></div>` : ''}`;
      box.querySelector('.link').addEventListener('click', cancel);
      return box;
    }
    if (state.stage === 'failed') {
      box.classList.add('failed');
      box.innerHTML = `
        <div class="org-head"><strong>${t('整理没有完成', 'Organizing didn\'t finish')}</strong></div>
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
      <div class="org-head"><strong>${t('这节课讲了哪几份课件？', 'Which decks did this lecture cover?')}</strong></div>
      <p class="org-message">${decks.length
        ? (suggested.length ? t('AI 选出了下面这些，可以增减。', 'These were picked by AI; add or remove as needed.') : t('AI 没有找到明显相关的课件，可以自己勾选。', 'AI found no clearly related deck; pick them yourself.'))
        : t('课程文件夹里没有找到课件：会纠正转写，再从转写里找课程安排。', 'No decks were found in the course folder: the transcript will be corrected and searched for course arrangements only.')}</p>
      <div class="deck-list"></div>
      <p class="org-note">${t('开始后会把转写和勾选课件的文字发给「纠正转写」和「补充要点与课程安排」任务的模型（在「设置 → 模型」里可以单独选），按用量计费。',
        'Starting sends the transcript and the checked decks\' text to the Correct transcript and Lecture supplements models (choose them in Settings → Model); usage is billed.')}</p>
      <div class="org-actions"><button type="button" class="primary start"></button><button type="button" class="link">${t('取消', 'Cancel')}</button></div>`;
    const list = box.querySelector('.deck-list');
    const row = (deck) => {
      const label = document.createElement('label');
      label.className = 'deck' + (deck.readable ? '' : ' unreadable');
      label.innerHTML = `<input type="checkbox" ${deck.suggested && deck.readable ? 'checked' : ''} ${deck.readable ? '' : 'disabled'} value="${escape(deck.path)}">
        <span class="deck-text"><span class="deck-title">${escape(deck.title)}${deck.recorded ? `<span class="tag">${t('录音时打开', 'Open while recording')}</span>` : ''}</span>
        <span class="deck-sub">${escape(deck.reason || (deck.readable ? deck.folder : t('没有转换过，打开一次后才能读到内容', 'Not converted yet; open it once so its text can be read')))}</span></span>`;
      return label;
    };
    suggested.forEach((deck) => list.appendChild(row(deck)));
    if (others.length) {
      const more = document.createElement('details');
      more.open = suggested.length === 0;
      more.innerHTML = `<summary>${t(`其他 ${others.length} 份课件`, `${others.length} other decks`)}</summary>`;
      others.forEach((deck) => more.appendChild(row(deck)));
      list.appendChild(more);
    }
    const start = box.querySelector('.start');
    const update = () => {
      const count = box.querySelectorAll('input:checked').length;
      start.textContent = count ? t(`开始整理（${count} 份课件）`, `Start (${count} ${count === 1 ? 'deck' : 'decks'})`) : t('不对照课件，只找课程安排', 'Course arrangements only');
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
  function supplementsView(items) {
    const box = document.createElement('div');
    box.className = 'supplements';
    const groups = new Map();
    for (const item of items) {
      const key = item.deck || '';
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(item);
    }
    const keys = [...groups.keys()].sort((a, b) => (a === '') - (b === '') || a.localeCompare(b));
    for (const key of keys) {
      const list = groups.get(key).sort((a, b) => (a.page || 0) - (b.page || 0) || a.t - b.t);
      const section = document.createElement('section');
      section.innerHTML = `<h3>${escape(key ? list[0].deckTitle : t('对不上课件的页', 'Not tied to a slide'))}<span class="count">${list.length}</span></h3>`;
      for (const item of list) {
        const row = document.createElement('div');
        row.className = 'supp';
        row.innerHTML = `
          ${item.page ? `<button type="button" class="page" title="${t('在课件里打开这一页', 'Open this page')}">p.${item.page}</button>` : '<span class="page none">—</span>'}
          <div class="supp-body">
            <p class="point">${escape(item.point)}</p>
            ${item.quote ? `<p class="quote">“${escape(item.quote)}”</p>` : ''}
          </div>
          <button type="button" class="ts-button" title="${t('从这里播放', 'Play from here')}">${ICON.play}<span>${clock(item.t, detail.duration >= 3600)}</span></button>`;
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
  function arrangementsView(items) {
    const box = document.createElement('div');
    box.className = 'supplements arrangements';
    for (const item of items.slice().sort((a, b) => a.t - b.t)) {
      const row = document.createElement('div');
      row.className = 'supp';
      row.innerHTML = `
        <button type="button" class="ts-button lead" title="${t('从这里播放', 'Play from here')}">${ICON.play}<span>${clock(item.t, detail.duration >= 3600)}</span></button>
        <div class="supp-body">
          <p class="point">${escape(item.point)}</p>
          ${item.quote ? `<p class="quote">“${escape(item.quote)}”</p>` : ''}
        </div>
        ${item.page ? `<button type="button" class="page" title="${t('在课件里打开这一页', 'Open this page')}">${escape(item.deckTitle || '')} p.${item.page}</button>` : '<span></span>'}`;
      row.querySelector('.ts-button').addEventListener('click', () => seek(item.t, true));
      const page = row.querySelector('button.page');
      if (page) page.addEventListener('click', () => post({ type: 'openPage', deck: item.deck, page: item.page }));
      box.appendChild(row);
    }
    return box;
  }

  /** 高亮正在播放的那句；跟着播放滚动，除非用户刚自己滚过。 */
  function highlightCurrent(force) {
    const spans = $('content').querySelectorAll('.line');
    let current = null;
    for (const span of spans) {
      if (Number(span.dataset.t) <= playback.time + 0.05) current = span;
      else break;
    }
    if (current && playback.time > Number(current.dataset.end) + 4) current = null;
    for (const span of $('content').querySelectorAll('.line.current')) if (span !== current) span.classList.remove('current');
    if (!current) return;
    const changed = !current.classList.contains('current');
    current.classList.add('current');
    if ((changed && playback.playing) || force) {
      if (Date.now() < manualScrollUntil && !force) return;
      const box = $('content').getBoundingClientRect();
      const r = current.getBoundingClientRect();
      if (r.top < box.top + 40 || r.bottom > box.bottom - 60) {
        $('content').scrollBy({ top: r.top - box.top - box.height * 0.35, behavior: force ? 'auto' : 'smooth' });
      }
    }
  }

  // ---------- 播放 ----------

  function seek(time, play) {
    const duration = (detail && detail.duration) || 0;
    playback.time = Math.min(Math.max(0, time), duration);
    manualScrollUntil = 0;
    post({ type: 'seek', time: playback.time, play: !!play });
    if (play && !playback.playing) { playback.playing = true; post({ type: 'play' }); }
    renderPlayback();
    if (!native) demoPlay(playback.playing);
  }

  function togglePlay() {
    playback.playing = !playback.playing;
    post({ type: playback.playing ? 'play' : 'pause' });
    renderPlayback();
    if (!native) demoPlay(playback.playing);
  }

  const RATES = [1, 1.25, 1.5, 1.75, 2, 0.8];

  function cycleRate() {
    playback.rate = RATES[(RATES.indexOf(playback.rate) + 1) % RATES.length];
    post({ type: 'rate', rate: playback.rate });
    renderPlayback();
  }

  function setupScrubber() {
    const scrubber = $('scrubber');
    const timeAt = (event) => {
      const r = scrubber.getBoundingClientRect();
      return ((event.clientX - r.left) / r.width) * ((detail && detail.duration) || 0);
    };
    scrubber.addEventListener('pointerdown', (event) => {
      if (!detail || detail.status === 'recording') return;
      scrubber.setPointerCapture(event.pointerId);
      scrubber.classList.add('dragging');
      playback.time = timeAt(event);
      renderPlayback();
    });
    scrubber.addEventListener('pointermove', (event) => {
      if (!scrubber.classList.contains('dragging')) return;
      playback.time = Math.max(0, Math.min(timeAt(event), detail.duration));
      renderPlayback();
    });
    scrubber.addEventListener('pointerup', () => {
      if (!scrubber.classList.contains('dragging')) return;
      scrubber.classList.remove('dragging');
      seek(playback.time, false);
    });
    scrubber.addEventListener('keydown', (event) => {
      if (event.key === 'ArrowLeft') seek(playback.time - 5);
      if (event.key === 'ArrowRight') seek(playback.time + 5);
    });
  }

  // ---------- 菜单 ----------

  function organize() {
    if (!detail || detail.status !== 'ready') return;
    post({ type: 'organize', id: detail.id });
    if (!native) toast(t('（示例）这里会先列出 AI 判断的相关课件，确认后开始整理', '(Demo) The related decks would be listed for you to confirm first'));
  }

  function openMenu() {
    const menu = $('menu');
    const entries = [
      ['rename', t('重命名…', 'Rename…')],
      ['editTags', t('编辑标签…', 'Edit Tags…')],
      ['reveal', t('在访达中显示', 'Show in Finder')],
      null,
      ['exportAudio', t('导出音频（m4a）…', 'Export Audio (m4a)…')],
      ['exportText', t('导出转写（文本）…', 'Export Transcript (Text)…')],
      null,
      ['delete', t('删除录音…', 'Delete Recording…'), 'danger'],
    ];
    menu.innerHTML = entries.map((e) => (e ? `<button type="button" data-action="${e[0]}" class="${e[2] || ''}">${e[1]}</button>` : '<hr>')).join('');
    menu.hidden = false;
    const r = $('more').getBoundingClientRect();
    menu.style.top = `${r.bottom + 6}px`;
    menu.style.left = `${Math.min(r.right - menu.offsetWidth, window.innerWidth - menu.offsetWidth - 8)}px`;
  }

  function closeMenu() { $('menu').hidden = true; }

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
    $('empty').hidden = !show;
    if (!show) return;
    $('empty').querySelector('.empty-icon').innerHTML = ICON.mic;
    $('empty-text').innerHTML = t(
      '还没有课堂录音。<br>打开课件后，点工具栏里的麦克风或按 <kbd>⌘⇧R</kbd> 开始录音，录下的内容会在本机转写成文字。',
      'No lectures yet.<br>Open a deck, then click the microphone in the toolbar or press <kbd>⌘⇧R</kbd>. Recordings are transcribed on this Mac.');
  }

  // ---------- 事件 ----------

  function setup() {
    document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
    $('play').addEventListener('click', togglePlay);
    $('back').addEventListener('click', () => seek(playback.time - 15));
    $('forward').addEventListener('click', () => seek(playback.time + 15));
    $('rate').addEventListener('click', cycleRate);
    $('organize').addEventListener('click', organize);
    $('more').addEventListener('click', (event) => { event.stopPropagation(); $('menu').hidden ? openMenu() : closeMenu(); });
    $('menu').addEventListener('click', (event) => {
      const action = event.target.closest('button') && event.target.closest('button').dataset.action;
      if (!action || !detail) return;
      closeMenu();
      post({ type: action, id: detail.id });
      if (!native) toast(t('（示例）', '(Demo) ') + event.target.textContent);
    });
    document.addEventListener('click', (event) => { if (!event.target.closest('#menu')) closeMenu(); });
    $('tabs').addEventListener('click', (event) => {
      const button = event.target.closest('button[data-tab]');
      if (!button || button.dataset.tab === tab) return;
      tab = button.dataset.tab;
      renderDetail();
    });
    let searchTimer = 0;
    $('search-input').addEventListener('input', (event) => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(() => { query = event.target.value; renderContent(); }, 180);
    });
    $('content').addEventListener('wheel', () => { manualScrollUntil = Date.now() + 4000; }, { passive: true });
    $('list-search-input').addEventListener('input', (event) => { listQuery = event.target.value; renderList(); });
    $('meta').addEventListener('click', (event) => {
      const chip = event.target.closest('.tag-filter');
      if (!chip) return;
      listQuery = chip.dataset.tag;
      $('list-search-input').value = listQuery;
      renderList();
    });
    document.addEventListener('keydown', (event) => {
      if (event.target.tagName === 'INPUT') return;
      if (event.key === ' ') { event.preventDefault(); togglePlay(); }
      if (event.key === 'Escape') closeMenu();
    });
    setupScrubber();
  }

  // ---------- 原生端接口 ----------

  window.Recordings = {
    setList(payload) {
      if (payload.lang) lang = payload.lang;
      items = payload.items || [];
      if (payload.selected !== undefined) selected = payload.selected;
      showEmpty(items.length === 0);
      renderList();
    },
    showDetail(payload) {
      const same = detail && detail.id === payload.id;
      if (!same) { tab = 'transcript'; query = ''; $('search-input').value = ''; }
      // 同一条录音更新（转写完一段、录完一段）：保留滚动位置，不跳到当前句
      const scroll = $('content').scrollTop;
      detail = payload;
      selected = payload.id;
      renderList();
      renderDetail(same);
      if (same) $('content').scrollTop = scroll;
    },
    setPlayback(payload) {
      playback = { ...playback, ...payload };
      renderPlayback();
    },
    toast(message) { toast(message); },
    setLive(payload) {
      if (!detail) return;
      detail.live = payload;
      const row = $('live');
      if (row) row.replaceWith(liveRow());
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
          const length = 1.2 + text.length * 0.055;
          lines.push({ segment: segment.index, start: time - offset, t: time, end: time + length, text });
          time += length + (i % 4 === 3 ? 5 : 0.4);
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

  function demoSelect(id) {
    demoPlay(false);
    playback = { time: id === 'a' ? 41 : 0, playing: false, rate: playback.rate };
    window.Recordings.showDetail(DEMO[id]);
  }

  let demoTimer = 0;
  function demoPlay(playing) {
    clearInterval(demoTimer);
    if (!playing) return;
    demoTimer = setInterval(() => {
      playback.time += 0.25 * playback.rate;
      if (playback.time >= detail.duration) { playback.time = detail.duration; playback.playing = false; demoPlay(false); }
      renderPlayback();
    }, 250);
  }

  window.Recordings.setList({
    lang,
    selected: 'a',
    items: [DEMO.live, DEMO.a, DEMO.b, DEMO.c].map(({ id, title, course, tags, startedAt, duration, status, supplements, elapsed }) =>
      ({ id, title, course, tags, startedAt, duration, status, organized: !!supplements, elapsed })),
  });
  demoSelect('a');
  DEMO.a.corrections = [
    { segment: DEMO.a.lines[2].segment, start: DEMO.a.lines[2].start, text: DEMO.a.lines[2].text.replace('process control block', 'process control block (PCB)') },
    { segment: DEMO.a.lines[5].segment, start: DEMO.a.lines[5].start, text: DEMO.a.lines[5].text.replace('loads', 'restores') },
  ];

  window.__demo = {
    select: demoSelect,
    play: () => { playback.playing = true; demoPlay(true); renderPlayback(); },
    lang: (code) => { lang = code; document.documentElement.lang = code === 'zh' ? 'zh-CN' : 'en'; renderList(); renderDetail(); },
    tab: (key) => { tab = key; renderDetail(); },
    empty: () => window.Recordings.setList({ items: [] }),
    organize: (state) => { detail.organize = state; renderDetail(); },
    choosing: () => window.__demo.organize({ stage: 'choosing', decks: [
      { path: '/c/04.pdf', title: '04-processes-threads', folder: 'Lectures', readable: true, suggested: true, recorded: true, reason: '讲到了 PCB、上下文切换和线程模型，和这份课件的内容一致。' },
      { path: '/c/05.pdf', title: '05-scheduling', folder: 'Lectures', readable: true, suggested: true, reason: '后半段讲了 round robin 和时间片，对应调度这一章的开头。' },
      { path: '/c/03.pdf', title: '03-memory', folder: 'Lectures', readable: true, suggested: false, reason: '' },
      { path: '/c/t09.pptx', title: 'Tutorial09', folder: 'Tutorial', readable: false, suggested: false, reason: '' },
    ] }),
    running: () => window.__demo.organize({ stage: 'running', step: 2, message: '对照课件找补充要点（第 3/8 段）', done: 2, total: 8 }),
  };
  if (/[?&]lang=(zh|en)/.test(location.search)) window.__demo.lang(RegExp.$1);
})();
