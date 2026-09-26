/* 媒体库首页预览。布局公式与 lib/widgets/media_library_layout_profile.dart、
   media_list_layout_metrics.dart 一致；外观由 tokens.css / tokens-legacy.css 切换。 */
(function () {
  const ENTRIES = [
    { id: "continue", label: "继续学习" },
    { id: "folders", label: "文件夹" },
    { id: "recent", label: "最近添加" },
  ];
  const CARD_COLS = {
    phone: [3, 6],
    compactTablet: [5, 8],
    tablet: [6, 10],
    largeTablet: [7, 11],
    desktop: [8, 12],
  };
  const LIST_COLS = {
    phone: [1, 2],
    compactTablet: [1, 2],
    tablet: [2, 3],
    largeTablet: [2, 3],
    desktop: [2, 4],
  };

  const videos = (prefix, titles) =>
    titles.map((title, i) => ({
      id: prefix + i,
      type: i % 7 === 5 ? "audio" : "video",
      title,
      duration: `${8 + ((i * 3) % 50)}:${String((i * 7) % 60).padStart(2, "0")}`,
      progress: [0.08, 0.42, 0.66, 0, 0.9, 0.15][i % 6],
    }));

  const FOLDERS = [
    { id: "f-jp", type: "folder", title: "日语听力", count: 24 },
    { id: "f-film", type: "folder", title: "电影", count: 11 },
    { id: "f-class", type: "folder", title: "公开课", count: 8 },
    { id: "f-music", type: "folder", title: "音乐", count: 36 },
    { id: "v0", type: "video", title: "深夜食堂 第一集", duration: "24:18", progress: 0.62 },
    { id: "v1", type: "video", title: "城市漫步：京都", duration: "18:02", progress: 0.2 },
    { id: "a0", type: "audio", title: "钢琴夜曲 No.2", duration: "4:41", progress: 0.4 },
    { id: "v2", type: "video", title: "字幕排版示例", duration: "12:06", progress: 0 },
    { id: "f-doc", type: "folder", title: "纪录片", count: 6 },
    { id: "v3", type: "video", title: "语法笔记 第 12 讲：助词的用法", duration: "41:20", progress: 0.33 },
    { id: "v9", type: "video", title: "晨间单词", duration: "15:02", progress: 0.5 },
    { id: "v10", type: "video", title: "排练回放", duration: "33:11", progress: 0 },
    { id: "f-shot", type: "folder", title: "截图素材", count: 4 },
    { id: "v11", type: "video", title: "夜读", duration: "22:40", progress: 0.27 },
    { id: "v4", type: "video", title: "海岸线延时", duration: "6:14", progress: 1 },
    { id: "v5", type: "video", title: "访谈：声音设计", duration: "55:09", progress: 0.11 },
    { id: "f-raw", type: "folder", title: "未整理", count: 3 },
    { id: "v6", type: "video", title: "通勤播客剪辑", duration: "27:44", progress: 0 },
    { id: "v7", type: "audio", title: "环境声：雨", duration: "60:00", progress: 0.05 },
    { id: "v8", type: "video", title: "短片：车站", duration: "9:58", progress: 0.78 },
  ];

  const CHILDREN = {
    "f-jp": videos("jp", ["第 1 课 问候", "第 2 课 数字", "第 3 课 时间", "第 4 课 购物", "第 5 课 旅行", "听力小测"]),
    "f-film": videos("fm", ["海边的房间", "冬日来信", "未完成的地图", "夜车"]),
    "f-class": videos("cl", ["线性代数 01", "线性代数 02", "写作工作坊"]),
    "f-music": videos("mu", ["现场：小馆", "排练录音", "封面曲"]),
    "f-doc": videos("dc", ["河流", "北方的光"]),
    "f-raw": videos("rw", ["导入 2026-09-01", "待命名"]),
    "f-shot": videos("sh", ["封面 A", "封面 B"]),
  };

  const CONTINUE_DAYS = [
    { id: "pin", label: "置顶", items: [FOLDERS[4], FOLDERS[6]] },
    { id: "today", label: "今天", items: [FOLDERS[5], FOLDERS[9], FOLDERS[7]] },
    { id: "yest", label: "昨天", items: [FOLDERS[10], FOLDERS[11], CHILDREN["f-jp"][0], CHILDREN["f-film"][1]] },
  ];
  const RECENT = [
    { id: "b1", label: "今天 16:02", sub: "文件夹导入", items: CHILDREN["f-jp"].slice(0, 4) },
    { id: "b2", label: "昨天 21:18", sub: "批量导入", items: CHILDREN["f-film"] },
  ];

  const params = new URLSearchParams(location.search);
  const state = {
    theme: params.get("theme") === "legacy" ? "legacy" : "new",
    accent: params.get("accent") || "blue",
    entry: params.get("entry") || "folders",
    viewMode: params.get("view") === "list" ? 1 : 0,
    selecting: false,
    selected: new Set(),
    collapsedFab: false,
    seriousOnly: false,
    folderId: null,
    query: null,
    expanded: {},
    pinned: new Set(["v0"]),
    sheet: null,
    styles: loadStyles(),
    folder: Object.assign(
      { paint: "gradientGhost", color: "muted", showText: false, silhouette: 0.83, opacity: 0.94 },
      loadStyles().folder
    ),
  };

  const $ = (id) => document.getElementById(id);
  const isNew = () => state.theme !== "legacy";

  function loadStyles() {
    try {
      return JSON.parse(localStorage.getItem("fp-preview-v2") || "{}");
    } catch (e) {
      return {};
    }
  }
  function persist() {
    const data = loadStyles();
    data[state.theme] = state.styles[state.theme];
    data.folder = state.folder;
    localStorage.setItem("fp-preview-v2", JSON.stringify(data));
  }
  function bucket() {
    if (!state.styles[state.theme]) state.styles[state.theme] = {};
    return state.styles[state.theme];
  }

  function cssNum(name) {
    return parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name));
  }
  function clamp(v, a, b) {
    return Math.min(b, Math.max(a, v));
  }
  function esc(s) {
    return String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }
  function icon(name, cls) {
    return `<span class="ms${cls ? " " + cls : ""}">${name}</span>`;
  }

  /* ---------- 滑块对数映射（与 Flutter 一致） ---------- */
  function log(v) {
    return Math.log(v + 0.0008);
  }
  function exp(v) {
    return Math.max(0, Math.exp(v) - 0.0008);
  }
  function logT(a, b, v) {
    const la = log(a);
    const lb = log(b);
    if (Math.abs(lb - la) < 1e-9) return 1;
    const lv = log(clamp(v, Math.min(a, b), Math.max(a, b)));
    return clamp((lv - la) / (lb - la), 0, 1);
  }
  function logLerp(a, b, t) {
    return exp(log(a) + (log(b) - log(a)) * t);
  }
  function toSlider(min, max, pivot, value) {
    const v = clamp(value, min, max);
    return v <= pivot ? 0.5 * logT(min, pivot, v) : 0.5 + 0.5 * logT(pivot, max, v);
  }
  function fromSlider(min, max, pivot, t) {
    const x = clamp(t, 0, 1);
    return x <= 0.5 ? logLerp(min, pivot, x * 2) : logLerp(pivot, max, (x - 0.5) * 2);
  }

  /* ---------- 尺寸分级与布局公式 ---------- */
  function sizeClass(w, h) {
    const shortest = Math.min(w, h);
    const longest = Math.max(w, h);
    if (shortest < 600) return "phone";
    if (shortest < 800) return "compactTablet";
    if (shortest < 1024) return "tablet";
    if (longest >= 1600 || shortest >= 1100) return "desktop";
    return "largeTablet";
  }
  function profile() {
    const w = window.innerWidth;
    const h = window.innerHeight;
    const compact = w < 600;
    const tabletMini = w >= 600 && w < 1200;
    return {
      w,
      h,
      compact,
      landscape: w + 1 >= h,
      size: sizeClass(w, h),
      bar: compact ? cssNum("--bar-compact") : cssNum("--bar-normal"),
      mini: tabletMini ? cssNum("--default-mini-tablet") : cssNum("--default-mini-phone"),
      inset: cssNum("--mini-inset") || 0,
      fab: Math.min(w, h) >= 600 ? cssNum("--default-fab-desktop") : cssNum("--default-fab-phone"),
    };
  }
  function slotName() {
    return profile().landscape ? "landscape" : "portrait";
  }
  function defaultColumns(list) {
    const p = profile();
    const table = list ? LIST_COLS : CARD_COLS;
    return table[p.size][p.landscape ? 1 : 0];
  }
  function styleOf(list) {
    const slot = slotName();
    const saved = ((bucket()[list ? "list" : "card"] || {})[slot]) || {};
    if (list) {
      return {
        columns: saved.columns ?? defaultColumns(true),
        title: saved.title ?? 0.042,
        height: saved.height ?? 0.1,
        cross: saved.cross ?? cssNum("--default-list-spacing"),
        main: saved.main ?? cssNum("--default-list-spacing"),
        thumb: saved.thumb ?? true,
        index: saved.index ?? false,
      };
    }
    return {
      columns: saved.columns ?? defaultColumns(false),
      title: saved.title ?? 0.104,
      height: saved.height ?? cssNum("--default-card-height"),
      cross: saved.cross ?? cssNum("--default-card-spacing"),
      main: saved.main ?? cssNum("--default-card-spacing"),
    };
  }
  function writeStyle(list, patch) {
    const b = bucket();
    const key = list ? "list" : "card";
    b[key] = b[key] || {};
    const slot = slotName();
    b[key][slot] = Object.assign({}, b[key][slot] || {}, patch);
    persist();
  }

  function distribute(available, columns, spacing) {
    const n = clamp(Math.round(columns), 1, 20);
    const s = clamp(spacing, 0, 0.45);
    const denom = n + Math.max(0, n - 1) * s + 2 * s;
    const cellWidth = Math.max(0.001, available / Math.max(0.001, denom));
    return { columns: n, cellWidth, crossSpacing: n === 1 ? 0 : cellWidth * s, outerPadding: cellWidth * s };
  }
  function cardMetrics(width) {
    const s = styleOf(false);
    const d = distribute(width, s.columns, s.cross);
    const height = clamp(s.height, 0.7, 2.4);
    const main = d.cellWidth * clamp(s.main, 0, 0.45);
    return Object.assign(d, { cellHeight: d.cellWidth * height, mainSpacing: main, topPadding: main, titleScale: clamp(s.title, 0.045, 0.22) });
  }
  function heightAdjustment(setting) {
    const c = clamp(setting, 0.001, 0.15);
    if (c <= 0.1) return 0.45 + ((c - 0.001) / (0.1 - 0.001)) * 0.55;
    return 1 + ((c - 0.1) / (0.15 - 0.1)) * 0.6;
  }
  function referenceTitle(setting) {
    const n = (clamp(setting, 0.001, 0.065) - 0.001) / (0.065 - 0.001);
    return 4 + n * 14;
  }
  function listMetrics(width) {
    const s = styleOf(true);
    const d = distribute(width, s.columns, s.cross);
    const shortest = Math.min(window.innerWidth, window.innerHeight);
    const scale = Math.max(0.001, shortest / 390);
    const desired = (referenceTitle(s.title) / 0.23) * heightAdjustment(s.height) * scale;
    const rowHeight = Math.max(0.001, Math.min(desired, d.cellWidth));
    const main = d.cellWidth * clamp(s.main, 0, 0.45);
    return Object.assign(d, {
      rowHeight,
      mainSpacing: main,
      topPadding: main,
      titleSetting: s.title,
      thumb: s.thumb,
      index: s.index,
      shortest,
    });
  }
  function tileMetrics(m) {
    const requested = (referenceTitle(m.titleSetting) / 0.23) * (m.shortest / 390);
    const unit = Math.max(0.001, Math.min(requested, Math.min(m.cellWidth, m.rowHeight / 0.53)));
    const titleSize = unit * 0.23;
    const visual = Math.min(unit, m.rowHeight);
    return {
      titleSize,
      meta: titleSize * 0.72,
      radius: Math.min(visual * 0.18, cssNum("--list-radius-max")),
      thumb: Math.min(unit * 0.68, m.cellWidth * 0.14),
      hPad: Math.min(unit * 0.14, m.cellWidth * 0.04),
    };
  }
  function currentMetrics() {
    const width = $("main").clientWidth || window.innerWidth;
    return state.viewMode === 0 ? cardMetrics(width) : listMetrics(width);
  }

  /* ---------- 假封面 ---------- */
  function hash(id) {
    let h = 2166136261;
    for (const c of id) {
      h ^= c.charCodeAt(0);
      h = Math.imul(h, 16777619);
    }
    return h >>> 0;
  }
  /* 封面不在本次设计范围内：视频用中性占位，文件夹沿用软件现有的三种画法。 */
  function hue(id) {
    return hash(id) % 360;
  }
  function folderColor(id) {
    const h = hue(id);
    if (state.folder.color === "vivid") return `hsl(${h} 68% 48%)`;
    if (state.folder.color === "pastel") return `hsl(${h} 36% 62%)`;
    return `hsl(${h} 32% 34%)`;
  }
  function placeholder(item) {
    const bg = folderColor(item.id);
    const text = state.folder.showText ? esc(item.title.slice(0, 2)) : "";
    const op = state.folder.opacity;
    if (state.folder.paint === "letterBlock") {
      return `<div class="ph center" style="background:${bg};container-type:size"><span class="letters" style="color:#fff;font-size:30cqh;opacity:${op}">${esc(item.title.slice(0, 2))}</span></div>`;
    }
    if (state.folder.paint === "tintedIcon") {
      return `<div class="ph center" style="background:${bg};container-type:size"><span class="ms" style="color:#fff;font-size:40cqh;opacity:${op}">folder</span></div>`;
    }
    const size = 28 + state.folder.silhouette * 22;
    return `<div class="ph" style="background:linear-gradient(160deg, ${bg} 0%, color-mix(in srgb, ${bg} 55%, #101010) 100%);container-type:size">
      <span class="folder-shape" style="width:${size}%;height:${Math.round(size * 0.72)}%;background:rgba(255,255,255,${0.14 + state.folder.silhouette * 0.08})"></span>
      ${text ? `<span style="position:absolute;left:8%;bottom:8%;font-weight:600;font-size:18cqh;opacity:${op}">${text}</span>` : ""}
    </div>`;
  }
  function neutralCover(item) {
    return `<div class="ph center neutral" style="container-type:size"><span class="ms">${item.type === "audio" ? "music_note" : "movie"}</span></div>`;
  }
  function coverBg(item) {
    return item.type === "folder" ? folderColor(item.id) : "var(--cover-ph)";
  }
  function thumb(item) {
    return item.type === "folder" ? placeholder(item) : neutralCover(item);
  }
  function progressBar(item) {
    if (!item.progress) return "";
    return `<div class="watch"><span style="width:${Math.round(item.progress * 100)}%"></span></div>`;
  }
  function metaText(item) {
    if (item.type === "folder") return `${icon("folder")}${item.count} 个项目`;
    if (item.type === "audio") return `${icon("music_note")}${item.duration}`;
    return item.duration;
  }
  function cardRadius(w) {
    return clamp(w * cssNum("--card-radius-factor"), cssNum("--card-radius-min"), cssNum("--card-radius-max"));
  }
  function findFolder(id) {
    return FOLDERS.find((it) => it.id === id);
  }

  function selbarHeight() {
    return state.selecting ? 60 : 0;
  }
  function bottomPad() {
    const p = profile();
    return p.mini + p.inset * 2 + 8 + selbarHeight();
  }
  function itemsNow() {
    if (state.query !== null) {
      const q = state.query.trim().toLowerCase();
      const all = FOLDERS.concat(...Object.values(CHILDREN));
      return q ? all.filter((it) => it.title.toLowerCase().includes(q)) : [];
    }
    if (state.folderId) return CHILDREN[state.folderId] || [];
    return FOLDERS;
  }

  /* ---------- 卡片 / 列表 ---------- */
  function dock(size, legacy) {
    const style = legacy ? `height:${size}px;border-top-left-radius:${size * 0.39}px` : `height:${size}px`;
    return `<div class="dock" style="${style}">
      <button data-act="card-more" title="更多" style="width:${size}px;height:${size}px">${icon("more_horiz")}</button>
      <button data-act="locate" title="显示所在目录" style="width:${size}px;height:${size}px">${icon("folder_open")}</button>
    </div>`;
  }
  function checkMark(on, style) {
    return `<span class="check ${on ? "on" : ""}" style="${style}">${icon(on ? "check_circle" : "radio_button_unchecked", on ? "fill" : "")}</span>`;
  }
  function cardHTML(item, m) {
    const r = cardRadius(m.cellWidth);
    const title = m.cellWidth * m.titleScale;
    const meta = title * 0.82;
    const on = state.selected.has(item.id);
    const chip = m.cellWidth * 0.19;
    const check = state.selecting ? checkMark(on, `top:${m.cellWidth * 0.04}px;right:${m.cellWidth * 0.04}px;font-size:${m.cellWidth * 0.15}px`) : "";
    if (isNew()) {
      const padTop = clamp(m.cellWidth * 0.05, 4, 8);
      return `<article class="card ${on ? "selected" : ""}" data-id="${item.id}" data-act="open" style="height:${m.cellHeight}px;border-radius:${r}px">
        <div class="cover" style="border-radius:${r}px">${thumb(item)}${progressBar(item)}</div>
        ${check}
        <div class="info" style="padding:${padTop}px 0 0 2px">
          <div class="card-title" style="font-size:${title}px">${esc(item.title)}</div>
          <div class="card-foot"><div class="card-meta" style="font-size:${meta}px">${metaText(item)}</div>${dock(chip, false)}</div>
        </div>
      </article>`;
    }
    const padX = clamp(m.cellWidth * 0.059, 3, 10);
    const padY = clamp(m.cellWidth * 0.035, 2, 6);
    return `<article class="card ${on ? "selected" : ""}" data-id="${item.id}" data-act="open" style="height:${m.cellHeight}px;border-radius:${r}px">
      <div class="cover" style="box-shadow:none">${thumb(item)}${progressBar(item)}</div>
      ${check}
      <div class="info" style="padding:${padY}px ${padX + chip * 0.35}px ${padY}px ${padX}px;justify-content:center">
        <div class="card-title" style="font-size:${title}px">${esc(item.title)}</div>
        <div class="card-meta" style="font-size:${meta}px">${item.type === "folder" ? item.count + " 个项目" : item.duration}</div>
      </div>
      ${dock(chip, true)}
    </article>`;
  }
  function rowHTML(item, m, index) {
    const t = tileMetrics(m);
    const on = state.selected.has(item.id);
    const lead = m.thumb
      ? `<div class="thumb-sq" style="width:${t.thumb}px;height:${t.thumb}px;margin-left:${t.hPad}px">${thumb(item)}</div>`
      : m.index
        ? `<div class="idx" style="width:${t.thumb}px;font-size:${t.titleSize * 0.64}px">${String(index + 1).padStart(2, "0")}</div>`
        : `<div style="width:${t.hPad}px"></div>`;
    const chip = m.rowHeight * 0.47;
    return `<article class="list-row ${on ? "selected" : ""}" data-id="${item.id}" data-act="open" style="height:${m.rowHeight}px;border-radius:${t.radius}px">
      ${lead}
      <div class="list-main" style="padding-right:${chip * 2 + 8}px">
        <div class="list-title" style="font-size:${t.titleSize}px">${esc(item.title)}</div>
        <div class="list-meta" style="font-size:${t.meta}px">${item.type === "folder" ? item.count + " 个项目" : item.duration}</div>
      </div>
      ${state.selecting ? checkMark(on, "left:4px;top:4px;font-size:16px") : ""}
      ${dock(chip, !isNew())}
    </article>`;
  }

  function grid(items, bottom) {
    const width = $("main").clientWidth || window.innerWidth;
    if (state.viewMode === 0) {
      const m = cardMetrics(width);
      const style = `grid-template-columns:repeat(${m.columns}, ${m.cellWidth}px);column-gap:${m.crossSpacing}px;row-gap:${m.mainSpacing}px;padding:${m.topPadding}px ${m.outerPadding}px ${bottom + m.outerPadding}px;`;
      return `<div class="grid" style="${style}">${items.map((it) => cardHTML(it, m)).join("")}</div>`;
    }
    const m = listMetrics(width);
    const style = `grid-template-columns:repeat(${m.columns}, ${m.cellWidth}px);column-gap:${m.crossSpacing}px;row-gap:${m.mainSpacing}px;padding:${m.topPadding}px ${m.outerPadding}px ${bottom + m.outerPadding}px;`;
    return `<div class="grid" style="${style}">${items.map((it, i) => rowHTML(it, m, i)).join("")}</div>`;
  }

  function sideInset() {
    const m = currentMetrics();
    return isNew() ? Math.max(8, m.outerPadding) : 12;
  }
  function groupHead(id, label, sub, items) {
    const open = state.expanded[id] !== false;
    const covers = items
      .slice(0, 4)
      .map((it) => {
        const bg = coverBg(it);
        return `<i style="background:${bg}"></i>`;
      })
      .join("");
    const rest = !open && items.length > 1 ? `<span class="g-rest">其余 ${items.length - 1}</span>` : "";
    const x = sideInset();
    const pad = isNew() ? `padding:var(--group-pad-y) ${x}px` : "padding:10px 8px 10px 12px";
    return `<button class="group-head" data-act="expand" data-id="${id}" style="${pad}">
      <span class="stack">${covers}</span>
      <span class="g-text"><span class="g-title">${esc(label)}</span><span class="g-sub">${esc(sub)}</span></span>
      ${rest}
      ${icon("expand_more", open ? "chev open" : "chev")}
    </button>`;
  }
  function groupBlock(g, bottom, last) {
    const open = state.expanded[g.id] !== false;
    const shown = open || g.items.length <= 1 ? g.items : g.items.slice(0, 1);
    const sub = g.sub ? `${g.sub} · ${g.items.length} 项` : `${g.items.length} 项`;
    return groupHead(g.id, g.label, sub, g.items) + grid(shown, last ? bottom : 4);
  }

  function renderSurface() {
    const bottom = bottomPad();
    let html = "";
    if (state.query !== null) {
      const items = itemsNow();
      html = items.length
        ? grid(items, bottom)
        : `<div class="empty">${icon("search")}<div>${state.query ? "没有匹配的内容" : "输入文件夹或媒体名称"}</div></div>`;
    } else if (state.folderId) {
      html = grid(itemsNow(), bottom);
    } else if (state.entry === "folders") {
      html = FOLDERS.length ? grid(FOLDERS, bottom) : `<div class="empty">${icon("folder_open")}<div>还没有内容</div></div>`;
    } else if (state.entry === "recent") {
      html = `<div class="hint-chip">有新添加内容</div>` + RECENT.map((g, i) => groupBlock(g, bottom, i === RECENT.length - 1)).join("");
    } else {
      const groups = state.seriousOnly
        ? [
            { id: "now", label: "最近在看", items: CONTINUE_DAYS[1].items },
            { id: "old", label: "之前未看完", items: CONTINUE_DAYS[2].items.filter((it) => it.progress && it.progress < 0.95) },
          ]
        : CONTINUE_DAYS;
      const x = sideInset();
      html = `<div class="filter-row" style="padding:8px ${Math.max(0, x - 8)}px 0">
        <button class="pill ${state.seriousOnly ? "on" : ""}" data-act="filter">${icon("filter_list")}<span>${state.seriousOnly ? "继续观看" : "全部记录"}</span>${icon("expand_more", "caret")}</button></div>`;
      html += groups.map((g, i) => groupBlock(g, bottom, i === groups.length - 1)).join("");
    }
    $("surface").innerHTML = html;
  }

  /* ---------- 顶栏 ---------- */
  function renderBar() {
    const p = profile();
    const nested = state.folderId || state.query !== null;
    let lead = state.viewMode === 1 ? "grid_view" : "view_list";
    let leadAct = "toggle-view";
    let leadTitle = state.viewMode === 1 ? "切换到卡片" : "切换到列表";
    if (state.selecting) {
      lead = "close";
      leadAct = "exit-select";
      leadTitle = "退出批量管理";
    } else if (nested) {
      lead = "arrow_back";
      leadAct = "back";
      leadTitle = "返回";
    }
    let center;
    if (state.selecting) center = `<div class="page-title">已选 ${state.selected.size} 项</div>`;
    else if (state.query !== null) center = `<div class="page-title">搜索结果<small>“${esc(state.query)}”</small></div>`;
    else if (state.folderId) {
      const f = findFolder(state.folderId);
      center = `<div class="page-title">${esc(f.title)}<small>${f.count} 个项目</small></div>`;
    } else {
      center = `<div class="tabs">${ENTRIES.map((e) => `<button class="tab ${state.entry === e.id ? "active" : ""}" data-act="tab" data-id="${e.id}">${e.label}</button>`).join("")}</div>`;
    }
    const btn = (act, name, title) => `<button class="icon-btn" data-act="${act}" title="${title}">${icon(name)}</button>`;
    const sep = isNew() ? `<span class="sep"></span>` : "";
    let actions;
    if (state.selecting) actions = btn("select-all", "select_all", "全选");
    else if (p.compact) actions = btn("search", "search", "搜索媒体库") + btn("sleep", "schedule", "定时关闭") + btn("recycle", "delete", "回收站") + btn("overflow", "more_horiz", "更多");
    else
      actions =
        btn("fullscreen", "fullscreen", "全屏") + btn("datadir", "folder_open", "大文件目录") + btn("transfer", "swap_vert", "导入与导出") + sep +
        btn("search", "search", "搜索媒体库") + btn("sleep", "schedule", "定时关闭") + btn("recycle", "delete", "回收站") + sep +
        btn("style", "tune", "调整卡片样式") + btn("settings", "settings", "媒体库设置") + btn("select-mode", "checklist", "批量管理");
    const bar = $("bar");
    bar.classList.toggle("wide", !p.compact);
    bar.innerHTML = `<button class="icon-btn lead" data-act="${leadAct}" title="${leadTitle}">${icon(lead)}</button>${center}<div class="actions">${actions}</div>`;
    bar.style.height = p.bar + "px";
  }

  /* ---------- 迷你播放器 ---------- */
  function renderMini() {
    const p = profile();
    const el = $("mini");
    const W = $("app").clientWidth;
    const width = p.inset ? (W >= 900 ? Math.min(W - p.inset * 2, 760) : W - p.inset * 2) : W;
    const big = p.mini > 100;
    const pad = big ? 14 : 10;
    const thumbPx = big ? 46 : 38;
    const btnPx = big ? 34 : 30;
    Object.assign(el.style, {
      height: p.mini + "px",
      width: width + "px",
      left: (W - width) / 2 + "px",
      bottom: selbarHeight() + p.inset + "px",
      padding: `0 ${pad - 4}px 0 ${pad}px`,
    });
    const b = (name, extra, title) =>
      `<button class="icon-btn ${extra || ""}" data-act="mini" data-id="${name}" title="${title}" style="width:${btnPx}px;height:${btnPx}px">${icon(name, name === "pause" ? "fill" : "")}</button>`;
    el.innerHTML = `
      <div class="mini-row">
        <div class="mini-thumb ph center neutral" style="position:relative;width:${thumbPx}px;height:${thumbPx}px">${icon("movie")}</div>
        <div class="mini-text">
          <div class="mini-title" style="font-size:${big ? 15 : 14}px">深夜食堂 第一集</div>
          <div class="mini-sub">「いらっしゃい。今日は何にする？」</div>
        </div>
        ${b("queue_music", "", "播放列表")}
      </div>
      <div class="mini-row" style="gap:8px">
        <span class="mini-time">10:12</span>
        <div class="mini-track"><span></span></div>
        <span class="mini-time">24:18</span>
        <div class="mini-controls">${b("skip_previous", "", "上一个")}${b("pause", "play", "暂停")}${b("skip_next", "", "下一个")}${b("volume_up", "", "静音")}</div>
      </div>`;
  }

  /* ---------- 悬浮按钮 ---------- */
  function renderFabs() {
    const p = profile();
    const el = $("fabs");
    if (state.selecting) {
      el.style.display = "none";
      return;
    }
    el.style.display = "flex";
    el.style.bottom = selbarHeight() + p.inset + p.mini + 12 + "px";
    const size = isNew() ? p.fab - 8 : p.fab;
    const items = state.collapsedFab
      ? []
      : [
          ["closed_caption", "", "批量字幕生成", "batch-sub"],
          ["create_new_folder", "", "新建合集", "new-folder"],
          ["video_call", "", "导入视频或音频", "import"],
          ["tv", "bili", "B站视频下载", "bili"],
          ["ondemand_video", "yt", "YT-DLP 视频下载", "ytdlp"],
          ["playlist_add", "batch", "批量导入媒体及对应字幕", "batch-import"],
        ];
    const s = `width:${size}px;height:${size}px`;
    el.innerHTML =
      items.map(([name, cls, title, act]) => `<button class="fab ${cls}" data-act="fab" data-id="${act}" title="${title}" style="${s}">${icon(name)}${act === "batch-import" ? '<i class="badge"></i>' : ""}</button>`).join("") +
      (items.length ? `<span class="rail-sep"></span>` : "") +
      `<button class="fab collapse" data-act="collapse" title="${state.collapsedFab ? "展开" : "收起"}" style="${s}">${icon(state.collapsedFab ? "keyboard_arrow_up" : "keyboard_arrow_down")}</button>`;
  }

  function renderSel() {
    const el = $("selbar");
    el.classList.toggle("show", state.selecting);
    if (!state.selecting) return;
    const one = state.selected.size === 1;
    el.innerHTML = `
      <button class="sel-btn danger" data-act="sel-delete">${icon("delete")}<span>移入回收站</span></button>
      <button class="sel-btn export" data-act="sel-export">${icon("unarchive")}<span>${profile().compact ? "导出" : "以 FluentPack 文件导出"}</span></button>
      ${one ? `<button class="sel-btn accent" data-act="sel-rename">${icon("edit")}<span>重命名</span></button>` : ""}`;
  }

  function render() {
    const root = document.documentElement;
    root.dataset.theme = isNew() ? "new" : "legacy";
    root.dataset.accent = state.accent;
    const toggle = $("themeToggle");
    if (toggle) toggle.textContent = isNew() ? "当前：笔记风" : "当前：现有样式";
    renderBar();
    renderSurface();
    renderMini();
    renderFabs();
    renderSel();
    syncScrolled();
  }
  function syncScrolled() {
    $("bar").classList.toggle("scrolled", $("main").scrollTop > 2);
  }

  /* ---------- 弹层 ---------- */
  function closeLayer() {
    $("layer").innerHTML = "";
    state.sheet = null;
  }
  function toast(text, kind) {
    const node = document.createElement("div");
    node.className = "toast" + (kind === "ok" ? " ok" : "");
    node.innerHTML = `${icon(kind === "ok" ? "check_circle" : "info")}<span>${esc(text)}</span>`;
    $("layer").appendChild(node);
    setTimeout(() => node.remove(), 2400);
  }
  function sheet(title, sub, body) {
    state.sheet = title;
    const center = window.innerWidth >= 900;
    $("layer").innerHTML = `<div class="scrim ${center ? "center" : ""}" data-act="scrim">
      <div class="sheet" data-act="stop">
        <div class="grabber"></div>
        <div class="sheet-head"><h2>${esc(title)}${sub ? `<span class="sub">${esc(sub)}</span>` : ""}</h2>
          <button class="text-btn" data-act="close">完成</button></div>
        <div class="sheet-body">${body}</div>
      </div></div>`;
  }
  function dialog(title, body, actions) {
    state.sheet = title;
    $("layer").innerHTML = `<div class="scrim center" data-act="scrim">
      <div class="dialog" data-act="stop" style="width:min(400px, 100%)">
        <div class="dialog-head"><h2>${esc(title)}</h2></div>
        <div class="dialog-body">${body}</div>
        <div class="dialog-actions">${actions}</div>
      </div></div>`;
  }
  function popover(anchor, items) {
    const rect = anchor.getBoundingClientRect();
    const html = items
      .map((it) =>
        it.sep
          ? `<div class="menu-sep"></div>`
          : `<button class="menu-item ${it.danger ? "danger" : ""}" data-act="${it.act}" ${it.id ? `data-id="${it.id}"` : ""}>${icon(it.icon)}<span>${esc(it.label)}</span>${it.checked ? icon("check", "trail") : ""}</button>`
      )
      .join("");
    $("layer").innerHTML = `<div class="scrim clear" data-act="scrim"></div>`;
    const menu = document.createElement("div");
    menu.className = "popover";
    menu.dataset.act = "stop";
    menu.innerHTML = html;
    $("layer").appendChild(menu);
    const mw = menu.offsetWidth;
    const mh = menu.offsetHeight;
    let left = rect.right - mw > 8 && rect.left + mw > window.innerWidth - 8 ? rect.right - mw : rect.left;
    left = clamp(left, 8, window.innerWidth - mw - 8);
    let top = rect.bottom + 4;
    if (top + mh > window.innerHeight - 8) {
      top = Math.max(8, rect.top - mh - 4);
      menu.style.transformOrigin = "bottom left";
    }
    menu.style.left = left + "px";
    menu.style.top = top + "px";
  }

  function sliderRow(key, label, valueText, min, max, pivot, value) {
    const t = Math.round(toSlider(min, max, pivot, value) * 1000);
    return `<div class="slider-row"><div class="slider-top"><span>${label}</span><span class="val">${valueText}</span></div>
      <input type="range" min="0" max="1000" value="${t}" style="--p:${t / 10}%" data-slider="${key}" data-min="${min}" data-max="${max}" data-pivot="${pivot}"></div>`;
  }
  function switchRow(key, label, desc, on) {
    return `<button class="row" data-act="switch" data-key="${key}"><span class="grow"><div class="t">${label}</div>${desc ? `<div class="d">${desc}</div>` : ""}</span><span class="switch ${on ? "on" : ""}"><i></i></span></button>`;
  }
  function linkRow(act, label, desc, id, lead) {
    return `<button class="row" data-act="${act}" ${id ? `data-id="${esc(id)}"` : ""}>${lead ? icon(lead) : ""}<span class="grow"><div class="t">${label}</div>${desc ? `<div class="d">${desc}</div>` : ""}</span>${icon("chevron_right", "go")}</button>`;
  }

  function sliderLabel(key, value) {
    const m = currentMetrics();
    if (state.viewMode === 0) {
      if (key === "columns") return `${Math.round(value)} 列 · 宽 ${Math.round(m.cellWidth)}`;
      if (key === "title") return `${Math.round(value * 100)}% · ${Math.round(m.cellWidth * value)}px`;
      if (key === "height") return `${value.toFixed(2)} × 宽`;
      const px = key === "cross" ? m.crossSpacing : m.mainSpacing;
      return `${Math.round(value * 100)}% · ${Math.round(px)}px`;
    }
    if (key === "columns") return `${Math.round(value)} 列`;
    if (key === "title") return `${referenceTitle(value).toFixed(1)}px @390`;
    if (key === "height") return `行高 ${Math.round(m.rowHeight)}px`;
    const px = key === "cross" ? m.crossSpacing : m.mainSpacing;
    return `${Math.round(value * 100)}% · ${Math.round(px)}px`;
  }

  const PAINTS = { gradientGhost: "渐变剪影", letterBlock: "色块大字", tintedIcon: "染色图标" };
  function openStyle() {
    const list = state.viewMode === 1;
    const s = styleOf(list);
    const orient = profile().landscape ? "横屏" : "竖屏";
    const title = list ? "列表样式" : "卡片样式";
    const pivotH = cssNum("--default-card-height");
    const pivotS = cssNum("--default-card-spacing");
    let rows;
    if (!list) {
      rows = [
        sliderRow("columns", "每行卡片数量", sliderLabel("columns", s.columns), 1, 20, 8, s.columns),
        sliderRow("title", "标题字号", sliderLabel("title", s.title), 0.045, 0.22, 0.104, s.title),
        sliderRow("height", "卡片高度", sliderLabel("height", s.height), 0.7, 2.4, pivotH, s.height),
        sliderRow("cross", "横向间距", sliderLabel("cross", s.cross), 0, 0.45, pivotS, s.cross),
        sliderRow("main", "纵向间距", sliderLabel("main", s.main), 0, 0.45, pivotS, s.main),
      ].join("");
    } else {
      rows = [
        sliderRow("columns", "每行数量", sliderLabel("columns", s.columns), 1, 20, 2, s.columns),
        sliderRow("height", "卡片高度", sliderLabel("height", s.height), 0.001, 0.15, 0.1, s.height),
        sliderRow("cross", "横向间距", sliderLabel("cross", s.cross), 0, 0.45, cssNum("--default-list-spacing"), s.cross),
        sliderRow("main", "纵向间距", sliderLabel("main", s.main), 0, 0.45, cssNum("--default-list-spacing"), s.main),
        sliderRow("title", "标题字号", sliderLabel("title", s.title), 0.001, 0.065, 0.042, s.title),
      ].join("");
    }
    const extra = list ? `<div class="glabel">显示</div><div class="gcard">${switchRow("thumb", "缩略图", "", s.thumb)}${switchRow("index", "序号", "关闭缩略图时显示", s.index)}</div>` : "";
    sheet(title, `${orient} · 只影响当前方向，另一方向单独保存`, `
      <div class="glabel">布局</div>
      <div class="gcard">${rows}</div>
      ${extra}
      <div class="glabel">封面</div>
      <div class="gcard">${linkRow("placeholder", "文件夹占位", PAINTS[state.folder.paint])}</div>
      <div style="padding-top:14px;display:flex;justify-content:flex-start"><button class="text-btn muted" data-act="reset-style">恢复当前方向默认</button></div>`);
  }

  function openSettings() {
    const flags = state.settings || { copy: false, queue: true, audio: false };
    state.settings = flags;
    sheet("媒体库设置", "", `
      <div class="glabel">导入与播放</div>
      <div class="gcard">
        ${switchRow("copy", "导入时复制到应用私有目录", "关闭时直接引用原文件", flags.copy)}
        ${switchRow("queue", "搜索结果作为播放队列", "", flags.queue)}
        ${switchRow("audio", "后台播放哔哩哔哩时只加载音频", "", flags.audio)}
      </div>
      <div class="glabel">存储</div>
      <div class="gcard">
        ${linkRow("toast", "清除播放记录", "", "已清除播放记录")}
        ${linkRow("toast", "Bilibili 在线视频缓存", "128 MB · 查看明细或清除", "缓存 128 MB")}
      </div>`);
  }

  function openPolicy() {
    const p = state.policy || { mode: "easier", age: "不限", exclude: true };
    state.policy = p;
    const ages = ["不限", "7 天", "14 天", "30 天", "90 天", "1 年"];
    sheet("继续观看门槛", "决定哪些记录出现在「继续观看」里", `
      <div class="glabel">判定方式</div>
      <div class="segmented">
        <button data-act="segment" data-key="mode" data-id="easier" class="${p.mode === "easier" ? "on" : ""}">满足任一项</button>
        <button data-act="segment" data-key="mode" data-id="both" class="${p.mode === "both" ? "on" : ""}">两项都满足</button>
      </div>
      <div class="glabel">条件</div>
      <div class="gcard">
        ${sliderRow("minWatch", "最少看满", "30 秒", 0, 600, 30, 30)}
        ${switchRow("exclude", "排除已看完", "", p.exclude)}
      </div>
      <div class="glabel">时间范围</div>
      <div class="gcard"><div class="chips" style="padding-top:12px">${ages.map((a) => `<button class="chip ${p.age === a ? "on" : ""}" data-act="age" data-id="${a}">${a}</button>`).join("")}</div></div>`);
  }

  function openImport() {
    const rows = [
      ["photo_library", "从相册导入", ""],
      ["folder_open", "从文件管理导入", ""],
      ["link", "导入 Bilibili 链接", "仅在线播放；下载请用小电视按钮"],
      ["folder_zip", "导入压缩包", ""],
      ["folder", "导入文件夹", ""],
      ["inventory_2", "从 FluentPack 文件导入", ""],
    ];
    sheet("导入", "", `<div class="gcard">${rows.map(([ic, t, d]) => linkRow("toast", t, d, t, ic)).join("")}</div>`);
  }

  function openPlaceholder() {
    const colors = [
      ["muted", "柔和"],
      ["vivid", "鲜艳"],
      ["pastel", "淡彩"],
    ];
    const demo = (paint) => {
      const prev = state.folder.paint;
      state.folder.paint = paint;
      const html = placeholder({ id: "f-film", type: "folder", title: "电影" });
      state.folder.paint = prev;
      return html;
    };
    dialog("文件夹占位", `
      <div class="glabel" style="margin-top:0">画法</div>
      <div class="paint-grid">${Object.entries(PAINTS).map(([id, label]) => `<button class="paint ${state.folder.paint === id ? "on" : ""}" data-act="paint" data-id="${id}"><div class="demo">${demo(id)}</div>${label}</button>`).join("")}</div>
      <div class="glabel">颜色</div>
      <div class="segmented">${colors.map(([id, label]) => `<button class="${state.folder.color === id ? "on" : ""}" data-act="fcolor" data-id="${id}">${label}</button>`).join("")}</div>
      <div class="glabel">细节</div>
      <div class="gcard">
        ${switchRow("showText", state.folder.paint === "tintedIcon" ? "显示字母徽章" : "显示封面文字", "", state.folder.showText)}
        ${sliderRow("opacity", "文字不透明度", Math.round(state.folder.opacity * 100) + "%", 0, 1, 0.94, state.folder.opacity)}
        ${sliderRow("silhouette", "剪影大小", Math.round(state.folder.silhouette * 100) + "%", 0.04, 2.8, 0.83, state.folder.silhouette)}
      </div>`, `<button class="btn primary" data-act="close">完成</button>`);
  }

  function openSearch() {
    state.sheet = "search";
    $("layer").innerHTML = `<div class="scrim top" data-act="scrim" style="${window.innerWidth < 600 ? "padding:8px" : ""}">
      <div class="search-panel" data-act="stop">
        <div class="search-box">${icon("search")}<input id="q" placeholder="搜索文件夹或媒体名称" autocomplete="off"></div>
        <div class="search-foot"><span><kbd>Enter</kbd>搜索</span><span><kbd>Esc</kbd>关闭</span></div>
      </div></div>`;
    const input = $("q");
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        state.query = input.value;
        state.folderId = null;
        closeLayer();
        render();
      }
    });
    setTimeout(() => input.focus(), 30);
  }

  function openPlaylist() {
    const rows = ["深夜食堂 第一集", "城市漫步：京都", "语法笔记 第 12 讲"];
    sheet("播放列表", "3 项", `<div class="gcard">${rows
      .map((t, i) => `<button class="row" data-act="toast" data-id="正在播放 ${esc(t)}">${icon(i === 0 ? "equalizer" : "play_arrow")}<span class="grow"><div class="t" style="${i === 0 ? "color:var(--accent-text)" : ""}">${esc(t)}</div><div class="d">${i === 0 ? "正在播放" : "队列"}</div></span></button>`)
      .join("")}</div>`);
  }

  function itemById(id) {
    return FOLDERS.concat(...Object.values(CHILDREN), ...CONTINUE_DAYS.flatMap((g) => g.items)).find((it) => it.id === id);
  }

  /* ---------- 交互 ---------- */
  function onClick(e) {
    const el = e.target.closest("[data-act]");
    if (!el) return;
    const act = el.dataset.act;
    if (act === "stop") return;
    if (act === "scrim") {
      if (e.target === el) closeLayer();
      return;
    }
    if (act === "close") {
      closeLayer();
      return;
    }
    if (act === "tab") {
      state.entry = el.dataset.id;
      state.folderId = null;
      state.query = null;
      render();
      return;
    }
    if (act === "toggle-view") {
      state.viewMode = state.viewMode === 0 ? 1 : 0;
      render();
      return;
    }
    if (act === "back" || act === "exit-select") {
      if (act === "exit-select") {
        state.selecting = false;
        state.selected.clear();
      } else {
        state.folderId = null;
        state.query = null;
      }
      render();
      return;
    }
    if (act === "expand") {
      const id = el.dataset.id;
      state.expanded[id] = state.expanded[id] === false;
      renderSurface();
      return;
    }
    if (act === "open") {
      const item = itemById(el.dataset.id);
      if (!item) return;
      if (state.selecting) {
        if (state.selected.has(item.id)) state.selected.delete(item.id);
        else state.selected.add(item.id);
        render();
        return;
      }
      if (item.type === "folder") {
        state.folderId = item.id;
        state.entry = "folders";
        render();
        $("main").scrollTop = 0;
      } else toast("打开「" + item.title + "」");
      return;
    }
    if (act === "card-more") {
      e.stopPropagation();
      const id = el.closest("[data-id]").dataset.id;
      const pinned = state.pinned.has(id);
      popover(el, [
        { act: "pin", id, icon: "push_pin", label: pinned ? "取消置顶" : "置顶到继续学习" },
        { act: "locate", id, icon: "folder_open", label: "显示所在目录" },
      ]);
      return;
    }
    if (act === "pin") {
      if (state.pinned.has(el.dataset.id)) state.pinned.delete(el.dataset.id);
      else state.pinned.add(el.dataset.id);
      closeLayer();
      toast(state.pinned.has(el.dataset.id) ? "已置顶到继续学习" : "已取消置顶", "ok");
      return;
    }
    if (act === "locate") {
      e.stopPropagation();
      closeLayer();
      state.entry = "folders";
      state.folderId = null;
      state.query = null;
      render();
      toast("已定位到所在目录", "ok");
      return;
    }
    if (act === "overflow") {
      popover(el, [
        { act: "transfer", icon: "swap_vert", label: "导入与导出" },
        { act: "datadir", icon: "folder_open", label: "大文件目录" },
        { sep: true },
        { act: "style", icon: "tune", label: "调整卡片样式" },
        { act: "settings", icon: "settings", label: "媒体库设置" },
        { act: "select-mode", icon: "checklist", label: "批量管理" },
      ]);
      return;
    }
    if (act === "filter") {
      popover(el, [
        { act: "serious-off", icon: "history", label: "全部记录", checked: !state.seriousOnly },
        { act: "serious-on", icon: "play_circle", label: "继续观看", checked: state.seriousOnly },
        { sep: true },
        { act: "policy", icon: "tune", label: "门槛设置…" },
      ]);
      return;
    }
    if (act === "serious-on" || act === "serious-off") {
      state.seriousOnly = act === "serious-on";
      closeLayer();
      render();
      return;
    }
    if (act === "style") { closeLayer(); openStyle(); return; }
    if (act === "settings") { closeLayer(); openSettings(); return; }
    if (act === "policy") { closeLayer(); openPolicy(); return; }
    if (act === "search") { openSearch(); return; }
    if (act === "select-mode") {
      closeLayer();
      state.selecting = true;
      render();
      return;
    }
    if (act === "select-all") {
      itemsNow().forEach((it) => state.selected.add(it.id));
      render();
      return;
    }
    if (act === "recycle") { toast("打开回收站"); return; }
    if (act === "transfer") { closeLayer(); toast("打开导入与导出"); return; }
    if (act === "fullscreen") { toast("全屏"); return; }
    if (act === "sleep") {
      state.sleep = state.sleep || "30 分钟";
      const opts = ["15 分钟", "30 分钟", "60 分钟", "播完当前"];
      dialog("定时关闭", `<div class="chips" style="padding:4px 0 0">${opts.map((t) => `<button class="chip ${state.sleep === t ? "on" : ""}" data-act="sleep-pick" data-id="${t}">${t}</button>`).join("")}</div>`,
        `<button class="btn ghost" data-act="close">取消</button><button class="btn primary" data-act="toast" data-id="将在 ${state.sleep} 后关闭">开始</button>`);
      return;
    }
    if (act === "sleep-pick") {
      state.sleep = el.dataset.id;
      el.parentElement.querySelectorAll(".chip").forEach((c) => c.classList.toggle("on", c === el));
      const go = $("layer").querySelector(".btn.primary");
      if (go) go.dataset.id = `将在 ${state.sleep} 后关闭`;
      return;
    }
    if (act === "datadir") {
      closeLayer();
      dialog("大文件目录", `<div style="color:var(--text-3);font-size:12px;margin-bottom:6px">当前位置</div><div class="field" style="display:flex;align-items:center;font-size:13px;color:var(--text-2)">D:\\FluentPlayer\\Data</div>`,
        `<button class="btn ghost" data-act="close">恢复默认</button><button class="btn primary" data-act="toast" data-id="已选择目录">选择目录</button>`);
      return;
    }
    if (act === "collapse") {
      state.collapsedFab = !state.collapsedFab;
      renderFabs();
      return;
    }
    if (act === "fab") {
      const id = el.dataset.id;
      if (id === "import") openImport();
      else if (id === "new-folder") {
        dialog("新建合集", `<input class="field" id="fname" placeholder="合集名称">`, `<button class="btn ghost" data-act="close">取消</button><button class="btn primary" data-act="create-folder">创建</button>`);
        setTimeout(() => $("fname") && $("fname").focus(), 30);
      } else if (id === "bili") toast("打开 B站视频下载");
      else if (id === "ytdlp") toast("打开 YT-DLP 视频下载");
      else if (id === "batch-sub") toast("打开批量字幕生成");
      else toast("打开批量导入");
      return;
    }
    if (act === "create-folder") {
      const name = ($("fname") && $("fname").value.trim()) || "未命名合集";
      closeLayer();
      toast("已创建「" + name + "」", "ok");
      return;
    }
    if (act === "placeholder") { openPlaceholder(); return; }
    if (act === "paint") {
      state.folder.paint = el.dataset.id;
      persist();
      openPlaceholder();
      renderSurface();
      return;
    }
    if (act === "fcolor") {
      state.folder.color = el.dataset.id;
      persist();
      openPlaceholder();
      renderSurface();
      return;
    }
    if (act === "switch") {
      const key = el.dataset.key;
      const sw = el.querySelector(".switch");
      if (key === "thumb" || key === "index") {
        const s = styleOf(true);
        writeStyle(true, { [key]: !s[key] });
        sw.classList.toggle("on", !s[key]);
        renderSurface();
        return;
      }
      if (key === "showText") {
        state.folder.showText = !state.folder.showText;
        persist();
        openPlaceholder();
        renderSurface();
        return;
      }
      if (key === "exclude") {
        state.policy.exclude = !state.policy.exclude;
        sw.classList.toggle("on", state.policy.exclude);
        return;
      }
      state.settings[key] = !state.settings[key];
      sw.classList.toggle("on", state.settings[key]);
      return;
    }
    if (act === "segment") {
      state.policy[el.dataset.key] = el.dataset.id;
      el.parentElement.querySelectorAll("button").forEach((b) => b.classList.toggle("on", b === el));
      return;
    }
    if (act === "age") {
      state.policy.age = el.dataset.id;
      el.parentElement.querySelectorAll(".chip").forEach((c) => c.classList.toggle("on", c === el));
      return;
    }
    if (act === "reset-style") {
      const b = bucket();
      const key = state.viewMode === 1 ? "list" : "card";
      if (b[key]) delete b[key][slotName()];
      persist();
      renderSurface();
      openStyle();
      return;
    }
    if (act === "sel-delete") {
      toast(state.selected.size ? `已将 ${state.selected.size} 项移入回收站` : "还没有选中内容", state.selected.size ? "ok" : "");
      state.selected.clear();
      state.selecting = false;
      render();
      return;
    }
    if (act === "sel-export") { toast("打开 FluentPack 导出"); return; }
    if (act === "sel-rename") {
      const item = itemById([...state.selected][0]);
      dialog("重命名", `<input class="field" id="rname" value="${esc(item ? item.title : "")}">`, `<button class="btn ghost" data-act="close">取消</button><button class="btn primary" data-act="toast" data-id="已重命名">保存</button>`);
      setTimeout(() => $("rname") && $("rname").select(), 30);
      return;
    }
    if (act === "toast") {
      closeLayer();
      toast(el.dataset.id || "已完成", "ok");
      return;
    }
    if (act === "mini") {
      if (el.dataset.id === "queue_music") openPlaylist();
      else toast("播放控制");
    }
  }

  function onInput(e) {
    const el = e.target.closest("[data-slider]");
    if (!el) return;
    el.style.setProperty("--p", el.value / 10 + "%");
    const key = el.dataset.slider;
    let value = fromSlider(parseFloat(el.dataset.min), parseFloat(el.dataset.max), parseFloat(el.dataset.pivot), el.value / 1000);
    const label = el.parentElement.querySelector(".val");
    if (key === "columns") value = clamp(Math.round(value), 1, 20);
    if (key === "opacity" || key === "silhouette") {
      state.folder[key] = value;
      persist();
      if (label) label.textContent = Math.round(value * 100) + "%";
      renderSurface();
      return;
    }
    if (key === "minWatch") {
      if (label) label.textContent = value < 60 ? `${Math.round(value)} 秒` : `${(value / 60).toFixed(1)} 分钟`;
      return;
    }
    writeStyle(state.viewMode === 1, { [key]: value });
    renderSurface();
    if (label) label.textContent = sliderLabel(key, value);
  }

  let swipe = null;
  $("main").addEventListener("pointerdown", (e) => {
    if (e.pointerType === "mouse") return;
    if (e.target.closest("button")) return;
    swipe = { x: e.clientX, y: e.clientY, t: Date.now() };
  });
  $("main").addEventListener("pointerup", (e) => {
    if (!swipe || state.folderId || state.query !== null) {
      swipe = null;
      return;
    }
    const dx = e.clientX - swipe.x;
    const dy = e.clientY - swipe.y;
    const dt = Math.max(1, Date.now() - swipe.t);
    const pass = Math.abs(dx) > Math.abs(dy) * 1.2 && (Math.abs(dx) > window.innerWidth * 0.36 || Math.abs(dx) / dt > 0.95);
    if (pass) {
      const i = ENTRIES.findIndex((en) => en.id === state.entry);
      const next = dx < 0 ? Math.min(ENTRIES.length - 1, i + 1) : Math.max(0, i - 1);
      if (next !== i) {
        state.entry = ENTRIES[next].id;
        render();
      }
    }
    swipe = null;
  });
  $("main").addEventListener("scroll", syncScrolled, { passive: true });

  document.addEventListener("click", onClick);
  document.addEventListener("input", onInput);
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeLayer();
  });
  window.addEventListener("resize", () => {
    const reopen = state.sheet === "卡片样式" || state.sheet === "列表样式";
    render();
    if (reopen) openStyle();
  });
  window.addEventListener("message", (e) => {
    if (!e.data) return;
    if (e.data.type === "set-theme") state.theme = e.data.theme === "legacy" ? "legacy" : "new";
    else if (e.data.type === "set-accent") state.accent = e.data.accent || "blue";
    else return;
    closeLayer();
    render();
  });

  const drop = $("drop");
  window.addEventListener("dragover", (e) => {
    e.preventDefault();
    drop.classList.add("show");
  });
  window.addEventListener("dragleave", (e) => {
    if (e.target === drop) drop.classList.remove("show");
  });
  window.addEventListener("drop", (e) => {
    e.preventDefault();
    drop.classList.remove("show");
    toast("已加入导入队列", "ok");
  });

  $("themeToggle").addEventListener("click", () => {
    state.theme = isNew() ? "legacy" : "new";
    closeLayer();
    render();
  });

  if (params.get("embed") === "1") document.body.classList.add("embed");
  if (params.get("still") === "1") document.body.classList.add("still");
  render();
  const open = params.get("open");
  if (open === "style") openStyle();
  else if (open === "settings") openSettings();
  else if (open === "policy") openPolicy();
  else if (open === "search") openSearch();
  else if (open === "import") openImport();
  else if (open === "placeholder") openPlaceholder();
  else if (open === "select") {
    state.selecting = true;
    FOLDERS.slice(0, 2).forEach((it) => state.selected.add(it.id));
    render();
  } else if (open === "menu") {
    const btn = document.querySelector('[data-act="card-more"]');
    if (btn) btn.click();
  }
  if (window.parent !== window) window.parent.postMessage({ type: "preview-ready" }, "*");
})();
