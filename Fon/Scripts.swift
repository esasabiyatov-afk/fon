import Foundation

/// JavaScript, который встраивается в страницы YouTube до их собственного кода.
enum Scripts {

    // MARK: - Общее для обоих окон

    /// Страница всегда «видна» и «в фокусе», но сами мы знаем настоящее состояние.
    static let common = #"""
(() => {
  if (window.__fon) return;
  const fon = window.__fon = { realHidden: false, hiddenAt: 0, onVisibility: null };

  fon.post = (msg) => { try { window.webkit.messageHandlers.fon.postMessage(msg); } catch (e) {} };

  const desc = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState');
  const realState = desc && desc.get ? () => desc.get.call(document) : () => 'visible';

  const fake = (name, value) => {
    try { Object.defineProperty(Document.prototype, name, { get: () => value, configurable: true }); } catch (e) {}
  };
  fake('hidden', false);
  fake('webkitHidden', false);
  fake('visibilityState', 'visible');
  fake('webkitVisibilityState', 'visible');
  try { Document.prototype.hasFocus = function () { return true; }; } catch (e) {}

  // Мы видим смену видимости первыми и не пропускаем её дальше к YouTube.
  const onVis = (e) => {
    if (e.type === 'visibilitychange') {
      fon.realHidden = realState() !== 'visible';
      if (fon.realHidden) fon.hiddenAt = Date.now();
      try { fon.onVisibility && fon.onVisibility(); } catch (err) {}
    }
    e.stopImmediatePropagation();
  };
  window.addEventListener('visibilitychange', onVis, true);
  window.addEventListener('webkitvisibilitychange', onVis, true);
  window.addEventListener('blur', (e) => { if (e.target === window) e.stopImmediatePropagation(); }, true);

  fon.video = () =>
    document.querySelector('video.html5-main-video') || document.querySelector('#player video') || document.querySelector('video');

  fon.addStyle = (css) => {
    const add = () => {
      const s = document.createElement('style');
      s.textContent = css;
      (document.head || document.documentElement).appendChild(s);
    };
    if (document.documentElement) add(); else document.addEventListener('DOMContentLoaded', add);
  };

  fon.absURL = (href) => { try { return new URL(href, location.href); } catch (e) { return null; } };

  // --- Контекст API YouTube (версия клиента и т.п.) — для облачного окна «Понравившихся»,
  // где своей страницы YouTube нет. Сохраняем, когда страница его выдаст.
  const saveContext = () => {
    try {
      const ctx = window.ytcfg && ytcfg.get && ytcfg.get('INNERTUBE_CONTEXT');
      if (ctx && ctx.client) localStorage.setItem('fon-ctx', JSON.stringify({ client: ctx.client }));
    } catch (e) {}
  };
  setTimeout(saveContext, 4000);
  setTimeout(saveContext, 15000);

  // --- Shorts не нужны: прячем полки, карточки и фильтр «Shorts» в ленте, поиске и под видео.
  fon.addStyle(`
    ytm-reel-shelf-renderer, ytm-shorts-shelf-renderer, ytm-reel-item-renderer,
    ytm-shorts-lockup-view-model, ytm-shorts-lockup-view-model-v2,
    .fon-hidden { display: none !important; }
  `);
  // :has() — отдельным блоком: если браузер его не поймёт, первый блок всё равно сработает.
  fon.addStyle(`
    ytm-rich-section-renderer:has(ytm-reel-shelf-renderer),
    ytm-rich-section-renderer:has(ytm-shorts-lockup-view-model),
    ytm-rich-section-renderer:has(ytm-shorts-lockup-view-model-v2),
    ytm-item-section-renderer:has(> ytm-reel-shelf-renderer),
    ytm-rich-item-renderer:has(a[href^="/shorts/"]),
    ytm-video-with-context-renderer:has(a[href^="/shorts/"]),
    ytm-compact-video-renderer:has(a[href^="/shorts/"]) { display: none !important; }
  `);
  // Запасной путь, если YouTube переименует элементы: прячем секции с заголовком «Shorts».
  const SHORTS = /^(shorts|шортс)$/i;
  const SECTION = 'ytm-rich-section-renderer, ytm-item-section-renderer, ytm-reel-shelf-renderer, ytm-shelf-renderer, ytm-horizontal-card-list-renderer';
  setInterval(() => {
    if (fon.realHidden || !document.body) return;
    for (const el of document.querySelectorAll('h2, h3, h4, .reel-shelf-title, [role="heading"]')) {
      if (!SHORTS.test((el.textContent || '').trim())) continue;
      const section = el.closest(SECTION);
      if (section) section.classList.add('fon-hidden');
    }
    for (const chip of document.querySelectorAll('ytm-chip-cloud-chip-renderer, yt-chip-cloud-chip-renderer')) {
      if (SHORTS.test((chip.textContent || '').trim())) chip.classList.add('fon-hidden');
    }
  }, 1500);

  // --- Лупа в шапке YouTube открывает поиск приложения, а не веб-поиск.
  const currentQuery = () => {
    try { return new URL(location.href).searchParams.get('search_query') || ''; } catch (e) { return ''; }
  };
  const openSearch = () => fon.post({ type: 'search', query: currentQuery() });
  window.addEventListener('click', (e) => {
    const b = e.target && e.target.closest ? e.target.closest('button, [role="button"], a') : null;
    if (!b || !b.closest('ytm-mobile-topbar-renderer, header, #header-bar, .mobile-topbar-header')) return;
    const label = (b.getAttribute('aria-label') || '') + ' ' + (b.getAttribute('title') || '');
    if (!/search|поиск/i.test(label)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    openSearch();
  }, true);
  // Если веб-поиск всё же открылся (поле получило фокус) — закрываем его и открываем свой.
  document.addEventListener('focusin', (e) => {
    const input = e.target;
    if (!(input instanceof HTMLInputElement)) return;
    if (!(input.type === 'search' || input.name === 'search' || input.classList.contains('searchbox-input'))) return;
    input.blur();
    const back = document.querySelector('ytm-search button[aria-label], .searchbox-back-button, button[aria-label="Back"], button[aria-label="Назад"]');
    if (back) back.click();
    openSearch();
  }, true);
})();
"""#

    // MARK: - Окно плеера

    static let player = #"""
(() => {
  const fon = window.__fon;
  if (!fon || fon.role) return;
  fon.role = 'player';

  // --- 1. Отличаем «пауза от тебя» (YouTube вызывает pause() из JS) от «пауза от системы» (WebKit сам).
  const proto = HTMLMediaElement.prototype;
  const origPause = proto.pause;
  const origPlay = proto.play;
  // Пока приложение свёрнуто, pause() из JS YouTube чаще всего реакция на отказ WebKit играть в фоне,
  // а не решение пользователя. Настоящая пауза в фоне — только наша команда (экран блокировки).
  fon.explicitPause = false;
  proto.pause = function () {
    this.__fonUserPaused = !fon.realHidden || fon.explicitPause;
    if (fon.explicitPause) this.__fonHardPause = true;
    return origPause.call(this);
  };
  proto.play = function () { this.__fonUserPaused = false; this.__fonHardPause = false; return origPlay.call(this); };

  let systemPausedEl = null;
  let systemPausedAt = 0;

  const tryResume = (v) => {
    if (v && v.paused && !v.ended && !v.__fonUserPaused) {
      const p = origPlay.call(v);
      if (p && p.catch) p.catch(() => {});
    }
  };

  document.addEventListener('play', (e) => {
    if (e.target instanceof HTMLMediaElement) { e.target.__fonUserPaused = false; applyActions(); }
  }, true);
  document.addEventListener('playing', (e) => {
    if (!(e.target instanceof HTMLMediaElement)) return;
    e.target.__fonPlayed = true;
    if (!e.target.ended) endedInBg = null; // следующий трек пошёл
  }, true);

  // Сворачивание: WebKit ставит видео на паузу, потом страница становится скрытой.
  // В этот момент снова включаем — так делает Brave.
  document.addEventListener('pause', (e) => {
    const v = e.target;
    if (!(v instanceof HTMLMediaElement) || v.ended || v.__fonUserPaused) return;
    systemPausedEl = v;
    systemPausedAt = Date.now();
    if (fon.realHidden && Date.now() - fon.hiddenAt < 2000) resumeSoon(v);
  }, true);

  // Сразу и ещё раз чуть позже: так пауза при сворачивании почти не слышна.
  const resumeSoon = (v) => {
    tryResume(v);
    setTimeout(() => tryResume(v), 250);
  };

  fon.onVisibility = () => {
    setTimeout(() => { try { applyQuality(); } catch (e) {} }, 1500); // после того, как звук снова пошёл
    if (!fon.realHidden) for (const t of [300, 1000]) setTimeout(() => { try { fon.repaint(); } catch (e) {} }, t);
    if (fon.realHidden && systemPausedEl && Date.now() - systemPausedAt < 2000) {
      resumeSoon(systemPausedEl);
    }
  };

  // --- 1b. Ушли из приложения, пока видео ещё грузилось. Приложение раз в секунду (до ~25 с)
  // вызывает backgroundTick — это заодно будит WebKit — а мы помогаем видео начать играть.
  // Возвращаем 'playing', 'waiting' или 'idle' (пользователь сам поставил паузу — ничего не делаем).
  let wantPlay = false;
  const shouldForce = (v) =>
    !v.ended && !v.__fonHardPause && (!v.__fonUserPaused || !v.__fonPlayed);
  // Трек доиграл в фоне: { id, at }. Пока грузится следующий, звука нет — iOS может усыпить
  // приложение, поэтому приложение держится (trackEnding), а мы при необходимости жмём «следующий».
  let endedInBg = null;
  const nearEnd = (v) => !v.loop && isFinite(v.duration) && v.duration > 0 && v.duration - v.currentTime < 6;
  document.addEventListener('ended', (e) => {
    const v = e.target;
    if (!(v instanceof HTMLMediaElement) || !fon.realHidden || v.loop) return;
    endedInBg = { id: currentId(), at: Date.now() };
    wantPlay = true;
    fon.post({ type: 'trackEnding' });
  }, true);

  fon.backgroundTick = (first) => {
    const v = fon.video();
    // Видео ещё нет — значит, страница грузится; трек доиграл в фоне — ждём следующий.
    if (first) wantPlay = !v || !v.paused || shouldForce(v) || !!endedInBg;
    if (!wantPlay) return 'idle';
    // Трек вот-вот закончится — ещё не «играет стабильно»: держимся до начала следующего.
    if (v && !v.paused && v.readyState >= 3) return nearEnd(v) ? 'waiting' : 'playing';
    clickContinue();
    // YouTube сам не включил следующий трек (например, выключено автовоспроизведение) — включаем.
    if (endedInBg && v && v.ended && currentId() === endedInBg.id && Date.now() - endedInBg.at > 3000) {
      endedInBg.at = Date.now();
      fon.cmd('next');
      return 'waiting';
    }
    if (v && v.paused && shouldForce(v)) {
      const p = origPlay.call(v);
      if (p && p.catch) p.catch(() => {});
    }
    return 'waiting';
  };
  // --- 1c. Плеер открывается не нажатием на его странице, поэтому YouTube считает это автозапуском
  // и включает видео без звука. Возвращаем звук — если только пользователь сам не нажал «без звука».
  let lastTouch = 0;
  let unmutes = [];
  document.addEventListener('touchstart', () => { lastTouch = Date.now(); }, true);
  document.addEventListener('pointerdown', () => { lastTouch = Date.now(); }, true);
  const unmute = (v) => {
    if (!v || !v.muted || v.__fonUserMuted) return;
    const now = Date.now();
    unmutes = unmutes.filter((t) => now - t < 10000);
    if (unmutes.length >= 5) return; // YouTube упорно выключает звук — не спорим бесконечно
    unmutes.push(now);
    try {
      const p = ytPlayer();
      if (p && typeof p.unMute === 'function') p.unMute();
      if (p && typeof p.getVolume === 'function' && p.getVolume() === 0 && p.setVolume) p.setVolume(100);
    } catch (e) {}
    v.muted = false;
  };
  fon.unmute = unmute;
  document.addEventListener('volumechange', (e) => {
    const v = e.target;
    if (!(v instanceof HTMLMediaElement)) return;
    // Звук выключили сразу после нажатия на странице — это решение пользователя, запоминаем.
    if (v.muted && Date.now() - lastTouch < 1500) v.__fonUserMuted = true;
    if (!v.muted) v.__fonUserMuted = false;
    setTimeout(() => unmute(v), 50);
  }, true);
  document.addEventListener('playing', (e) => {
    if (e.target instanceof HTMLMediaElement) unmute(e.target);
  }, true);

  // Наушники отключили — это пауза пользователя, в фоне не включаем звук сами.
  fon.markUserPaused = () => {
    wantPlay = false;
    const v = fon.video();
    if (v) { v.__fonUserPaused = true; v.__fonHardPause = true; }
  };

  // Окно «Видео приостановлено. Продолжить?» в фоне — нажимаем «Да».
  const clickContinue = () => {
    const buttons = document.querySelectorAll('[role="dialog"] button, ytm-dialog button, tp-yt-paper-dialog button, .dialog button');
    for (const b of buttons) {
      const label = (b.innerText || b.getAttribute('aria-label') || '').trim();
      if (/^(yes|да|продолжить|continue)/i.test(label)) { b.click(); return true; }
    }
    return false;
  };
  setInterval(() => {
    if (clickContinue()) setTimeout(() => { const v = fon.video(); if (v) { v.__fonUserPaused = false; tryResume(v); } }, 300);
  }, 3000);

  // --- 2. Команды плеера.
  const currentId = () => {
    try {
      const u = new URL(location.href);
      if (u.searchParams.get('v')) return u.searchParams.get('v');
      const m = u.pathname.match(/\/(shorts|live)\/([\w-]{6,})/);
      return m ? m[2] : null;
    } catch (e) { return null; }
  };

  const findNext = () => {
    const direct = document.querySelector('.ytp-next-button');
    if (direct) return direct;
    for (const b of document.querySelectorAll('button[aria-label]')) {
      if (/next|следующ|далее/i.test(b.getAttribute('aria-label'))) return b;
    }
    const id = currentId();
    for (const a of document.querySelectorAll('a[href*="/watch?v="]')) {
      const u = fon.absURL(a.getAttribute('href'));
      if (u && u.searchParams.get('v') && u.searchParams.get('v') !== id && a.offsetParent !== null) return a;
    }
    return null;
  };

  fon.cmd = (c, arg) => {
    const v = fon.video();
    switch (c) {
      case 'play':   if (v) v.play().catch(() => {}); break;
      case 'pause':
        if (v) { fon.explicitPause = true; try { v.pause(); } finally { fon.explicitPause = false; } }
        break;
      case 'toggle':
        if (!v) break;
        if (v.paused) { v.play().catch(() => {}); break; }
        fon.explicitPause = true;
        try { v.pause(); } finally { fon.explicitPause = false; }
        break;
      case 'seek':   if (v && typeof arg === 'number') v.currentTime = arg; break;
      case 'next': {
        const el = findNext();
        if (el) el.click();
        else if (v && isFinite(v.duration)) v.currentTime = Math.max(0, v.duration - 0.3);
        break;
      }
      case 'loop': if (v) v.loop = !v.loop; break;
      case 'pip': {
        if (!v) break;
        try { v.disablePictureInPicture = false; v.removeAttribute('disablepictureinpicture'); } catch (e) {}
        if (typeof v.webkitSetPresentationMode === 'function') {
          v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
        } else if (document.pictureInPictureElement) {
          document.exitPictureInPicture().catch(() => {});
        } else if (v.requestPictureInPicture) {
          v.requestPictureInPicture().catch(() => {});
        }
        break;
      }
      case 'prev':
        if (v && v.currentTime > 3) v.currentTime = 0; else history.back();
        break;
    }
  };

  // --- 3. Экран блокировки: «следующий / предыдущий» вместо перемотки на 10 секунд.
  const ms = navigator.mediaSession;
  const ours = {
    play: () => fon.cmd('play'),
    pause: () => fon.cmd('pause'),
    nexttrack: () => fon.cmd('next'),
    previoustrack: () => fon.cmd('prev'),
    seekto: (d) => fon.cmd('seek', d && d.seekTime),
    seekforward: null,
    seekbackward: null
  };
  let rawSet = null;
  function applyActions() {
    if (!rawSet) return;
    for (const a in ours) { try { rawSet(a, ours[a]); } catch (e) {} }
  }
  if (ms && ms.setActionHandler) {
    rawSet = ms.setActionHandler.bind(ms);
    try {
      ms.setActionHandler = function (action, handler) {
        if (action in ours) return; // YouTube не перезапишет наши кнопки
        try { return rawSet(action, handler); } catch (e) {}
      };
    } catch (e) {}
    applyActions();
  }

  // --- 4. Мини-режим: на странице остаётся только видео на весь экран.
  fon.addStyle(`
    html.fon-mini, html.fon-mini body { overflow: hidden !important; background: #000 !important; }
    html.fon-mini #player-container-id,
    html.fon-mini .player-container,
    html.fon-mini #player {
      position: fixed !important; top: 0 !important; left: 0 !important;
      width: 100vw !important; height: 100vh !important; max-height: none !important;
      margin: 0 !important; padding: 0 !important; transform: none !important;
      z-index: 2147483646 !important; background: #000 !important;
    }
    html.fon-mini video {
      position: fixed !important; top: 0 !important; left: 0 !important;
      width: 100vw !important; height: 100vh !important; object-fit: cover !important;
    }
    html.fon-mini #player-control-overlay,
    html.fon-mini .player-controls-content,
    html.fon-mini .ytp-unmute { display: none !important; }
    ytm-pivot-bar-renderer { display: none !important; }

    html.fon-music #player-container-id,
    html.fon-music .player-container,
    html.fon-music #player,
    html.fon-music .html5-video-player {
      background: #000 var(--fon-thumb, none) center / cover no-repeat !important;
    }
    html.fon-music video { opacity: 0 !important; }

    /* В режиме музыки под плеером только очередь и похожие треки — без комментариев и Shorts. */
    html.fon-music ytm-comments-entry-point-header-renderer,
    html.fon-music ytm-comment-section-renderer,
    html.fon-music [section-identifier="comments-entry-point"],
    html.fon-music [section-identifier="comment-item-section"],
    html.fon-music ytm-engagement-panel-section-list-renderer[target-id*="comment"],
    html.fon-music ytm-reel-shelf-renderer,
    html.fon-music ytm-shorts-lockup-view-model { display: none !important; }

    /* Свой полный экран: плеер YouTube на всё окно — с его субтитрами и настройками. */
    html.fon-full, html.fon-full body { overflow: hidden !important; background: #000 !important; }
    html.fon-full #player-container-id,
    html.fon-full .player-container,
    html.fon-full #player,
    html.fon-full .html5-video-player {
      position: fixed !important; top: 0 !important; left: 0 !important;
      width: 100vw !important; height: 100vh !important; max-height: none !important;
      margin: 0 !important; padding: 0 !important; transform: none !important;
      z-index: 2147483600 !important; background: #000 !important;
    }
    html.fon-full .html5-video-container {
      position: absolute !important; top: 0 !important; left: 0 !important;
      width: 100% !important; height: 100% !important;
    }
    /* Панель управления YouTube (пауза, перемотка, ⚙ качество, выход) — поверх растянутого видео.
       Видео — на весь экран, а панель — внутри безопасной области (не под «чёлкой» и не у полоски
       «домой»): отступы передаёт приложение (--fon-safe-*). */
    html.fon-full #player-control-overlay,
    html.fon-full ytm-custom-control {
      position: fixed !important;
      top: var(--fon-safe-top, 0px) !important; left: var(--fon-safe-left, 0px) !important;
      width: calc(100vw - var(--fon-safe-left, 0px) - var(--fon-safe-right, 0px)) !important;
      height: calc(100vh - var(--fon-safe-top, 0px) - var(--fon-safe-bottom, 0px)) !important;
      z-index: 2147483610 !important;
    }
    /* Меню, которые открывают кнопки панели (⚙ качество и скорость, субтитры, «ещё»), YouTube
       добавляет отдельно в страницу — без этого они оказывались под растянутым плеером. */
    html.fon-full bottom-sheet-container,
    html.fon-full .bottom-sheet-container,
    html.fon-full ytm-bottom-sheet-renderer,
    html.fon-full bottom-sheet-layout,
    html.fon-full ytm-menu-popup-renderer,
    html.fon-full ytm-dialog,
    html.fon-full .dialog-container,
    html.fon-full [role="dialog"],
    html.fon-full ytm-select,
    html.fon-full .player-settings-menu,
    html.fon-full ytm-engagement-panel-section-list-renderer,
    html.fon-full tp-yt-paper-dialog,
    html.fon-full c3-overlay,
    html.fon-full .c3-overlay,
    html.fon-full .ytm-popup-container {
      z-index: 2147483647 !important;
    }
    /* «Фоновая подсветка» (размытое свечение вокруг видео) в полном экране не нужна: вокруг и так
       чёрные поля, а лишний слой тратит батарею и мешает отрисовке видео. */
    html.fon-full ytm-cinematic-container-renderer,
    html.fon-full #cinematics,
    html.fon-full #cinematics-container,
    html.fon-full .cinematic-container { display: none !important; }
    html.fon-full video,
    html.fon-full.fon-music video {
      position: absolute !important; top: 0 !important; left: 0 !important;
      width: 100% !important; height: 100% !important; object-fit: contain !important; opacity: 1 !important;
    }
    /* Субтитры в полном экране — по центру ширины (YouTube считал их место по старому размеру плеера). */
    html.fon-full .ytp-caption-window-container {
      position: absolute !important; top: 0 !important; left: 0 !important; width: 100% !important; height: 100% !important;
    }
    html.fon-full .caption-window {
      left: 50% !important; right: auto !important; margin-left: 0 !important;
      transform: translateX(-50%) !important; width: auto !important; max-width: 90% !important; text-align: center !important;
    }
    /* Вертикальный полный экран: субтитры сразу под картинкой, а не внизу экрана. */
    /* Ряд «Нравится/Поделиться/Сохранить» и «Другие видео» в полном экране наезжали на время и главу. */
    html.fon-full .fon-hidden-full { display: none !important; }
    html.fon-full.fon-cap-below .caption-window {
      top: var(--fon-cap-top, auto) !important; bottom: auto !important;
    }
  `);
  // После мини-полоски YouTube может не заметить, что окно снова большое, и оставить видео
  // маленьким в углу — несколько раз сообщаем ему о новом размере.
  fon.setMini = (on) => {
    on = !!on;
    const root = document.documentElement;
    if (root.classList.contains('fon-mini') === on) return;
    root.classList.toggle('fon-mini', on);
    for (const t of [60, 350, 900]) setTimeout(() => fire(window, 'resize'), t);
  };

  // --- 4a. Полный экран. На iPhone YouTube включает системный полноэкранный плеер iOS —
  // в нём нет субтитров YouTube и меню качества. Подменяем его своим: плеер растягивается
  // на всё окно, а приложение прячет шапку, статус-бар и поворачивает экран.
  fon.isFull = false;
  let fullEl = null;
  const fire = (target, name) => { try { target.dispatchEvent(new Event(name, { bubbles: true })); } catch (e) {} };
  let exitedAt = 0;
  const setFull = (on, el) => {
    on = !!on;
    if (on === fon.isFull) return;
    // Сразу после выхода YouTube мог тут же снова запросить полный экран (его состояние ещё «внутри») —
    // и выход кнопкой/свайпом будто не срабатывал. Повторный вход в ближайшие 1,5 с не принимаем.
    if (on && Date.now() - exitedAt < 1500) return;
    if (!on) exitedAt = Date.now();
    fon.isFull = on;
    const v = fon.video();
    fullEl = on ? (el || document.getElementById('player-container-id') || v || document.documentElement) : null;
    document.documentElement.classList.toggle('fon-full', on);
    // Вертикальное видео — полный экран остаётся вертикальным (приложение не поворачивает телефон).
    fon.post({ type: 'fullscreen', on, vertical: !!(v && v.videoHeight > v.videoWidth) });
    if (v) fire(v, on ? 'webkitbeginfullscreen' : 'webkitendfullscreen');
    fire(document, 'fullscreenchange');
    fire(document, 'webkitfullscreenchange');
    setTimeout(() => { fire(window, 'resize'); try { applyQuality(); } catch (e) {} try { fon.placeCaptions(); fon.tidyFullscreen(); } catch (e) {} }, 300);
    for (const t of [400, 1200]) setTimeout(() => fon.repaint(), t);
  };

  // После поворота, выхода из полного экрана или возврата в приложение WebKit иногда теряет
  // картинку видео (чёрный экран, звук идёт). Заставляем его перерисовать слой видео.
  // Видео на один кадр убираем и возвращаем — WebKit пересоздаёт слой с картинкой (звук не прерывается).
  // Чтобы это не мигало, на эти кадры поверх видео кладём снимок текущего кадра (canvas).
  const raf = window.requestAnimationFrame ? window.requestAnimationFrame.bind(window) : (f) => setTimeout(f, 16);
  let repainting = false;
  let quietUntil = 0; // перестройки страницы в ответ на нашу же перерисовку не считаем — без зацикливания
  let cover = null;
  const showCover = (v) => {
    try {
      const cs = getComputedStyle(v);
      if (v.readyState < 2 || !v.videoWidth || cs.opacity === '0' || !v.parentNode) return false;
      const w = v.offsetWidth, h = v.offsetHeight;
      if (w < 2 || h < 2) return false;
      // Кадр вписан в элемент так же, как его рисует видео (object-fit: contain или cover).
      const fit = cs.objectFit === 'cover' ? Math.max : Math.min;
      const k = fit(w / v.videoWidth, h / v.videoHeight);
      const fw = v.videoWidth * k, fh = v.videoHeight * k;
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      if (!cover) cover = document.createElement('canvas');
      // Снимок — соседний с видео элемент на том же месте: панель управления и меню YouTube остаются над ним.
      const fixed = cs.position === 'fixed';
      const r = fixed ? v.getBoundingClientRect() : null;
      cover.style.cssText = 'pointer-events:none;margin:0;padding:0;background:#000;display:block;' +
        'position:' + (fixed ? 'fixed' : 'absolute') + ';' +
        'left:' + (fixed ? r.left : v.offsetLeft) + 'px;top:' + (fixed ? r.top : v.offsetTop) + 'px;' +
        'width:' + w + 'px;height:' + h + 'px;z-index:' + (cs.zIndex === 'auto' ? '0' : cs.zIndex) + ';';
      cover.width = Math.round(w * dpr);
      cover.height = Math.round(h * dpr);
      const ctx = cover.getContext('2d');
      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, cover.width, cover.height);
      ctx.drawImage(v, (w - fw) / 2 * dpr, (h - fh) / 2 * dpr, fw * dpr, fh * dpr);
      v.parentNode.insertBefore(cover, v.nextSibling);
      return true;
    } catch (e) {
      if (cover) cover.remove();
      return false;
    }
  };
  fon.repaint = () => {
    const v = fon.video();
    quietUntil = Date.now() + 1200;
    fire(window, 'resize');
    if (!v || repainting) return;
    repainting = true;
    const covered = showCover(v);
    const prev = v.style.display;
    v.style.display = 'none';
    raf(() => raf(() => {
      v.style.display = prev;
      repainting = false;
      // Снимок убираем, когда видео уже снова нарисовалось.
      if (covered) raf(() => raf(() => { if (cover) cover.remove(); }));
    }));
  };
  let repaintTimer = null;
  // Только в полном экране: там пропадала картинка после меню ⚙. В обычном плеере YouTube перестраивает
  // страницу почти на каждое касание — перерисовка там была лишней и заметно мигала.
  const repaintSoon = (delay) => {
    if (!fon.isFull || Date.now() < quietUntil) return;
    clearTimeout(repaintTimer);
    repaintTimer = setTimeout(() => { if (fon.isFull && !fon.realHidden) fon.repaint(); }, delay || 400);
  };
  // Меню ⚙ и другие окна YouTube меняют классы/стили body и добавляют в него элементы —
  // после этого картинка видео пропадала. Ловим такие перестройки и перерисовываем.
  const watchLayout = () => {
    try {
      new MutationObserver(() => repaintSoon()).observe(document.body, { attributes: true, attributeFilter: ['class', 'style'], childList: true });
      new MutationObserver(() => repaintSoon()).observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
    } catch (e) {}
  };
  if (document.body) watchLayout(); else document.addEventListener('DOMContentLoaded', watchLayout);
  // Прокрутка в полном экране (например, списка в меню) — тоже повод перерисовать.
  window.addEventListener('touchend', () => repaintSoon(500), true);
  // Под видео (вертикальный полный экран) достаточно места — субтитры ставим сразу под картинкой.
  const placeCaptions = () => {
    const root = document.documentElement;
    const v = fon.video();
    if (!fon.isFull || !v || !v.videoWidth || !v.videoHeight) { root.classList.remove('fon-cap-below'); return; }
    const W = window.innerWidth, H = window.innerHeight;
    const k = Math.min(W / v.videoWidth, H / v.videoHeight);
    const bottom = (H + v.videoHeight * k) / 2;
    const below = H - bottom > 70;
    root.style.setProperty('--fon-cap-top', Math.round(bottom + 10) + 'px');
    root.classList.toggle('fon-cap-below', below);
  };
  window.addEventListener('resize', () => setTimeout(placeCaptions, 50));
  document.addEventListener('loadedmetadata', placeCaptions, true);
  document.addEventListener('resize', placeCaptions, true); // у video: сменились размеры кадра
  fon.placeCaptions = placeCaptions;

  // Полный экран: YouTube рисует поверх видео ряд «Нравится / Не нравится / Поделиться / Сохранить»
  // и «Другие видео» — они наезжали на время и название главы. Прячем их (только в полном экране):
  // остаются время, глава, прогресс, ⚙, субтитры и кнопки плеера.
  const ACTION = /^(нравится|не нравится|поделиться|сохранить|like|dislike|share|save)/i;
  const MORE = /^(другие видео|more videos)$/i;
  const tidyFullscreen = () => {
    if (!fon.isFull) return;
    for (const root of [document.getElementById('player-control-overlay'), document.getElementById('player-container-id')]) {
      if (!root) continue;
      const buttons = Array.from(root.querySelectorAll('button[aria-label], [role="button"][aria-label]'))
        .filter((b) => ACTION.test((b.getAttribute('aria-label') || '').trim()));
      if (buttons.length >= 2) {
        let row = buttons[0].parentElement;
        while (row && row !== root && !buttons.every((b) => row.contains(b))) row = row.parentElement;
        if (row && row !== root) row.classList.add('fon-hidden-full');
      } else {
        for (const b of buttons) b.classList.add('fon-hidden-full');
      }
      for (const el of root.querySelectorAll('span, div, button, a, yt-formatted-string')) {
        if (el.children.length || !MORE.test((el.textContent || '').trim())) continue;
        const box = el.closest('button, [role="button"], a') || el.parentElement;
        let target = box;
        // Подняться до блока с превью рядом с надписью, но не выше самой панели.
        while (target && target.parentElement && target.parentElement !== root && target.parentElement.querySelector('img') && !target.querySelector('img')) {
          target = target.parentElement;
        }
        if (target && target !== root) target.classList.add('fon-hidden-full');
      }
    }
  };
  setInterval(tidyFullscreen, 1000);
  fon.tidyFullscreen = tidyFullscreen;

  // Видео «зависло» на загрузке (часто после долгой паузы в свёрнутом приложении: WebKit выгружает буфер).
  // Если должно играть, а время не идёт: через 6 с — перемотка на то же место, через 12 с — перезагрузить
  // поток с этой секунды, через 20 с — перезагрузить страницу с этой секунды.
  let stallSince = 0, stallStep = 0, lastTime = -1;
  setInterval(() => {
    const v = fon.video();
    const mp = document.getElementById('movie_player');
    let state = -2;
    try { state = mp && mp.getPlayerState ? mp.getPlayerState() : -2; } catch (e) {}
    const shouldPlay = v && !v.ended && !v.__fonUserPaused && (!v.paused || state === 3);
    const t = v ? v.currentTime : 0;
    if (!shouldPlay || fon.realHidden || t !== lastTime) {
      lastTime = t;
      stallSince = 0;
      stallStep = 0;
      return;
    }
    if (!stallSince) stallSince = Date.now();
    const stuck = Date.now() - stallSince;
    const id = currentId();
    try {
      if (stuck > 6000 && stallStep === 0) {
        stallStep = 1;
        if (mp && mp.seekTo) mp.seekTo(t, true); else v.currentTime = t;
      } else if (stuck > 12000 && stallStep === 1 && id) {
        stallStep = 2;
        if (mp && mp.loadVideoById) mp.loadVideoById({ videoId: id, startSeconds: Math.floor(t) });
      } else if (stuck > 20000 && stallStep === 2 && id) {
        stallStep = 3;
        const u = new URL(location.href);
        u.searchParams.set('t', Math.floor(t) + 's');
        location.replace(u.href);
      }
    } catch (e) {}
  }, 1000);

  // Открыто меню YouTube (⚙, субтитры, «ещё»): тянуть его вниз — значит закрыть меню,
  // а не выйти из полного экрана или свернуть плеер. Сообщаем приложению, когда меню открыто.
  const MENUS = 'bottom-sheet-container, .bottom-sheet-container, ytm-bottom-sheet-renderer, bottom-sheet-layout, ' +
    'ytm-menu-popup-renderer, ytm-dialog, .dialog-container, [role="dialog"], tp-yt-paper-dialog, ytm-select';
  // Меню считается открытым, только если оно действительно сверху (а не пустой контейнер за плеером):
  // ложное «открыто» отключало свайп выхода из полного экрана. Приложению сообщаем верх меню —
  // свайп отключается только на самом меню.
  let menuOpen = false, menuTop = -1;
  const onTop = (el, r) => {
    const x = Math.min(Math.max(r.left + r.width / 2, 0), window.innerWidth - 1);
    const y = Math.min(Math.max(r.top + Math.min(r.height / 2, 30), 0), window.innerHeight - 1);
    const hit = document.elementFromPoint(x, y);
    return !!hit && (el === hit || el.contains(hit));
  };
  const checkMenu = () => {
    let open = false, top = -1;
    try {
      for (const el of document.querySelectorAll(MENUS)) {
        const r = el.getBoundingClientRect();
        const cs = getComputedStyle(el);
        if (r.height > 40 && r.width > 40 && r.bottom > 0 && r.top < window.innerHeight &&
            cs.display !== 'none' && cs.visibility !== 'hidden' && cs.opacity !== '0' && onTop(el, r)) {
          open = true;
          const t = Math.max(0, Math.round(r.top));
          top = top < 0 ? t : Math.min(top, t);
        }
      }
    } catch (e) {}
    if (open !== menuOpen || top !== menuTop) {
      menuOpen = open;
      menuTop = top;
      fon.post({ type: 'menu', open, top });
    }
  };
  window.addEventListener('touchstart', checkMenu, true);
  window.addEventListener('touchend', () => { for (const t of [150, 450, 900]) setTimeout(checkMenu, t); }, true);
  // Меню добавляются в страницу новыми элементами; проверяем не чаще 4 раз в секунду (субтитры тоже добавляют строки).
  let menuTimer = null;
  const checkMenuSoon = () => {
    if (menuTimer || fon.realHidden) return;
    menuTimer = setTimeout(() => { menuTimer = null; checkMenu(); }, 250);
  };
  const watchMenus = () => { try { new MutationObserver(checkMenuSoon).observe(document.body, { childList: true, subtree: true }); } catch (e) {} };
  if (document.body) watchMenus(); else document.addEventListener('DOMContentLoaded', watchMenus);
  fon.setFull = setFull;
  fon.setSafe = (top, right, bottom, left) => {
    const st = document.documentElement.style;
    st.setProperty('--fon-safe-top', top + 'px');
    st.setProperty('--fon-safe-right', right + 'px');
    st.setProperty('--fon-safe-bottom', bottom + 'px');
    st.setProperty('--fon-safe-left', left + 'px');
  };
  const getter = (obj, name, get) => { try { Object.defineProperty(obj, name, { get, configurable: true }); } catch (e) {} };
  const VP = HTMLVideoElement.prototype;
  for (const n of ['webkitEnterFullscreen', 'webkitEnterFullScreen']) VP[n] = function () { setFull(!fon.isFull, this); };
  for (const n of ['webkitExitFullscreen', 'webkitExitFullScreen']) VP[n] = function () { setFull(false); };
  getter(VP, 'webkitDisplayingFullscreen', () => fon.isFull);
  getter(VP, 'webkitSupportsFullscreen', () => true);
  for (const n of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']) {
    Element.prototype[n] = function () { setFull(true, this); return Promise.resolve(); };
  }
  for (const n of ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen']) {
    Document.prototype[n] = function () { setFull(false); return Promise.resolve(); };
  }
  for (const n of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement']) getter(Document.prototype, n, () => fullEl);
  for (const n of ['fullscreen', 'webkitIsFullScreen']) getter(Document.prototype, n, () => fon.isFull);
  for (const n of ['fullscreenEnabled', 'webkitFullscreenEnabled']) getter(Document.prototype, n, () => true);
  // Кнопка полного экрана YouTube в нашем полном экране не выводила из него (владелец: «кнопка свернуть
  // не работает») — YouTube снова просил «войти». Пока полный экран включён, нажатие на неё — выход.
  const FULL_BUTTON = /полноэкран|full\s?screen/i;
  const shown = (el) => {
    for (let n = el; n && n !== document.body; n = n.parentElement) {
      const cs = getComputedStyle(n);
      if (cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) < 0.1) return false;
    }
    return true;
  };
  const fullButton = (target) => {
    if (!fon.isFull || !target || !target.closest) return null;
    const b = target.closest('.fullscreen-icon, button, [role="button"]');
    if (!b) return null;
    const label = b.getAttribute('aria-label') || b.getAttribute('title') || '';
    if (!b.classList.contains('fullscreen-icon') && !FULL_BUTTON.test(label)) return null;
    return shown(b) ? b : null; // панель скрыта — касание лишь показывает её
  };
  window.addEventListener('click', (e) => {
    if (!fullButton(e.target)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    setFull(false);
  }, true);
  // Если YouTube гасит click после касания — выходим по самому касанию (без сдвига пальца).
  let tapX = 0, tapY = 0;
  window.addEventListener('touchstart', (e) => { const t = e.touches && e.touches[0]; if (t) { tapX = t.clientX; tapY = t.clientY; } }, true);
  window.addEventListener('touchend', (e) => {
    const t = e.changedTouches && e.changedTouches[0];
    if (!t || Math.abs(t.clientX - tapX) > 12 || Math.abs(t.clientY - tapY) > 12 || !fullButton(e.target)) return;
    setTimeout(() => { if (fon.isFull) setFull(false); }, 350);
  }, true);

  // --- 4b. Режим музыки и экономия: самое низкое качество видео, когда картинка не нужна.
  // YouTube запоминает выбранное качество в localStorage — из-за этого 144p «прилипало»
  // и к следующим видео. В режиме видео стираем эту память ещё до загрузки плеера.
  const QUALITY_STORE = 'yt-player-quality';
  try { if (localStorage.getItem('fon-music') !== '1') localStorage.removeItem(QUALITY_STORE); } catch (e) {}

  fon.musicMode = false;
  fon.setMusic = (on) => {
    fon.musicMode = !!on;
    try { localStorage.setItem('fon-music', fon.musicMode ? '1' : '0'); } catch (e) {}
    document.documentElement.classList.toggle('fon-music', fon.musicMode);
    applyQuality();
  };

  const ytPlayer = () => document.getElementById('movie_player') || document.querySelector('.html5-video-player');
  const ORDER = ['tiny', 'small', 'medium', 'large', 'hd720', 'hd1080', 'hd1440', 'hd2160', 'highres'];
  const rank = (q) => ORDER.indexOf(q);
  const inPip = () => {
    const v = fon.video();
    return !!v && (v.webkitPresentationMode === 'picture-in-picture' || document.pictureInPictureElement === v);
  };
  // Чёткое качество для экрана: на iPhone до 720p, на iPad до 1080p.
  const goodQuality = (levels) => {
    const cap = rank(Math.min(screen.width, screen.height) >= 700 ? 'hd1080' : 'hd720');
    const fit = levels.filter((q) => rank(q) >= 0 && rank(q) <= cap).sort((a, b) => rank(b) - rank(a));
    return fit[0] || levels[levels.length - 1];
  };
  let qualityKey = null; // что и для какого видео уже выставили
  let loweredOnce = false; // мы хоть раз ставили минимум — значит, надо будет поднимать

  function setQuality(p, q) {
    if (p.setPlaybackQualityRange) p.setPlaybackQualityRange(q, q);
    if (p.setPlaybackQuality) p.setPlaybackQuality(q);
  }

  function applyQuality() {
    const p = ytPlayer();
    const id = currentId();
    if (!p || !id || typeof p.getAvailableQualityLevels !== 'function') return;
    // В фоне картинку никто не видит; в «картинке в картинке» — видит.
    const low = !inPip() && !fon.isFull && (fon.musicMode || fon.realHidden);
    const key = id + ':' + (low ? 'low' : 'high');
    if (key === qualityKey) return;
    let levels = [];
    try { levels = (p.getAvailableQualityLevels() || []).filter((q) => q && q !== 'auto'); } catch (e) {}
    if (!levels.length) return; // плеер ещё не готов — попробуем на следующем тике
    try {
      if (low) {
        setQuality(p, levels[levels.length - 1]);
        loweredOnce = true;
      } else {
        let current = '';
        try { current = p.getPlaybackQuality ? p.getPlaybackQuality() : ''; } catch (e) {}
        const stuckLow = rank(current) >= 0 && rank(current) <= rank('small');
        if (loweredOnce || stuckLow) {
          try { localStorage.removeItem(QUALITY_STORE); } catch (e) {}
          setQuality(p, goodQuality(levels));
        } else if (rank(current) < 0) {
          return; // качество ещё неизвестно — проверим на следующем тике
        }
      }
      qualityKey = key;
    } catch (e) {}
  }
  document.addEventListener('webkitpresentationmodechanged', () => setTimeout(applyQuality, 300), true);
  document.addEventListener('enterpictureinpicture', () => setTimeout(applyQuality, 300), true);
  document.addEventListener('leavepictureinpicture', () => setTimeout(applyQuality, 300), true);

  // --- 5. Ссылки на каналы, поиск, плейлисты и ленты открываем в основном окне.
  // Только они: остальное (ответы в комментариях, описание, меню) YouTube показывает сам на этой странице.
  const BROWSE_PATH = /^\/(@|channel\/|c\/|user\/|results|playlist|feed\/|hashtag\/|shorts\/|gaming|premium|account)/;
  window.addEventListener('click', (e) => {
    const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (!a) return;
    const u = fon.absURL(a.getAttribute('href'));
    if (!u || !/youtube\.com$/.test(u.hostname)) return;
    if (u.pathname === '/watch' || !BROWSE_PATH.test(u.pathname)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    fon.post({ type: 'browse', url: u.href });
  }, true);

  // --- 6. Раз в секунду сообщаем приложению, что играет (для мини-плеера).
  let ownMeta = false;
  let lastId = null;
  let lastThumbId = null;
  let nearEndId = null;
  let playedId = null;   // трек, который сейчас считаем для истории «Недавно слушали»
  let playedSecs = 0;
  setInterval(() => {
    const v = fon.video();
    const id = currentId();
    if (!v || !id) { if (!fon.realHidden) fon.post({ type: 'state', active: false }); return; }

    applyQuality();
    unmute(v);
    if (id !== lastThumbId) {
      lastThumbId = id;
      document.documentElement.style.setProperty('--fon-thumb', 'url("https://i.ytimg.com/vi/' + id + '/hqdefault.jpg")');
    }

    let md = ms && ms.metadata;
    if (id !== lastId) { lastId = id; if (ownMeta && ms) { ms.metadata = null; md = null; ownMeta = false; } }

    const pageTitle = (document.title || '').replace(/\s*-\s*YouTube\s*$/, '');
    const title = (md && md.title) || pageTitle || 'YouTube';
    const ownerEl = document.querySelector('.slim-owner-channel-name, .ytm-slim-owner-renderer .slim-owner-channel-name, ytm-slim-owner-renderer h3');
    const artist = (md && md.artist) || (ownerEl ? ownerEl.textContent.trim() : '');
    const thumb = 'https://i.ytimg.com/vi/' + id + '/hqdefault.jpg';

    if (ms && !ms.metadata && window.MediaMetadata && pageTitle) {
      try {
        ms.metadata = new MediaMetadata({ title, artist, artwork: [{ src: thumb, sizes: '480x360', type: 'image/jpeg' }] });
        ownMeta = true;
      } catch (e) {}
    }

    // Трек отыграл 20 секунд (в том числе в фоне) — в историю «Недавно слушали».
    if (!v.paused) {
      if (playedId !== id) { playedId = id; playedSecs = 0; }
      if (++playedSecs === 20) fon.post({ type: 'played', id, title, artist });
    }

    // В фоне за несколько секунд до конца трека просим приложение не засыпать на смене трека.
    if (fon.realHidden && !v.paused && nearEnd(v) && nearEndId !== id) {
      nearEndId = id;
      fon.post({ type: 'trackEnding' });
    }

    if (fon.realHidden) return; // в фоне интерфейс не виден — не тратим энергию на сообщения

    fon.post({
      type: 'state', active: true, id, title, artist, thumb,
      paused: v.paused, loop: !!v.loop, time: v.currentTime || 0, duration: isFinite(v.duration) ? v.duration : 0
    });
  }, 1000);
})();
"""#

    // MARK: - Облако: плейлист «Fon — музыка» в аккаунте YouTube

    /// Выполняется в скрытом окне m.youtube.com (CloudLikes). Внутренний API YouTube (как у кнопки
    /// «Сохранить в плейлист» на сайте) с авторизацией по куки вошедшего аккаунта (SAPISIDHASH).
    static let cloud = #"""
(() => {
  if (window.__fonCloud) return;
  const TITLE = 'Fon — музыка';
  const PROBE = 'jNQXAC9IVRw'; // любое публичное видео — чтобы получить список своих плейлистов

  const cookie = (name) => {
    const m = document.cookie.match(new RegExp('(?:^|; )' + name.replace(/[-_.]/g, '\\$&') + '=([^;]*)'));
    return m ? decodeURIComponent(m[1]) : null;
  };
  const sha1 = async (s) => {
    const buf = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(s));
    return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
  };
  const context = () => {
    try { if (window.ytcfg && ytcfg.get && ytcfg.get('INNERTUBE_CONTEXT')) return ytcfg.get('INNERTUBE_CONTEXT'); } catch (e) {}
    try { const saved = localStorage.getItem('fon-ctx'); if (saved) return JSON.parse(saved); } catch (e) {}
    return { client: { clientName: 'MWEB', clientVersion: '2.20251020.01.00', hl: 'ru' } };
  };
  const api = async (endpoint, body) => {
    const sapisid = cookie('SAPISID') || cookie('__Secure-3PAPISID');
    if (!sapisid) throw new Error('signed-out');
    const ctx = context();
    const origin = location.origin;
    const ts = Math.floor(Date.now() / 1000);
    const hash = await sha1(ts + ' ' + sapisid + ' ' + origin);
    const res = await fetch('/youtubei/v1/' + endpoint + '?prettyPrint=false', {
      method: 'POST',
      credentials: 'include',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'SAPISIDHASH ' + ts + '_' + hash,
        'X-Origin': origin,
        'X-Goog-AuthUser': '0',
        'X-Youtube-Client-Name': '2',
        'X-Youtube-Client-Version': (ctx.client && ctx.client.clientVersion) || ''
      },
      body: JSON.stringify(Object.assign({ context: ctx }, body))
    });
    if (res.status === 401 || res.status === 403) throw new Error('signed-out');
    if (!res.ok) throw new Error('http-' + res.status);
    return res.json();
  };
  const findAll = (obj, key, out) => {
    out = out || [];
    if (obj && typeof obj === 'object') {
      for (const k in obj) {
        if (k === key) out.push(obj[k]);
        findAll(obj[k], key, out);
      }
    }
    return out;
  };
  const text = (t) => (t ? (t.simpleText || (t.runs || []).map((r) => r.text).join('')) : '');
  const findPlaylist = async () => {
    const r = await api('playlist/get_add_to_playlist', { videoIds: [PROBE], excludeWatchLater: true });
    const option = findAll(r, 'playlistAddToOptionRenderer').find((o) => text(o.title) === TITLE);
    return option ? option.playlistId : null;
  };
  const RENDERERS = ['playlistVideoRenderer', 'playlistPanelVideoRenderer', 'videoWithContextRenderer', 'compactVideoRenderer'];

  // Видео из ответа YouTube (старая и новая вёрстка), без Shorts и плейлистов.
  // Значок официального исполнителя или «аудио» у видео — признак музыки.
  const musicBadge = (v) => findAll(v, 'iconType').concat(findAll(v, 'imageName'))
    .some((t) => typeof t === 'string' && /OFFICIAL_ARTIST|AUDIO_BADGE|MUSIC/.test(t));
  const collectVideos = (r, out, seen) => {
    const add = (v) => { if (v.id && !seen.has(v.id) && v.title) { seen.add(v.id); out.push(v); } };
    for (const name of ['videoWithContextRenderer', 'videoRenderer', 'gridVideoRenderer', 'compactVideoRenderer']) {
      for (const v of findAll(r, name)) {
        if (!v || !v.videoId || findAll(v, 'reelWatchEndpoint').length) continue;
        const by = v.shortBylineText || v.longBylineText || v.ownerText;
        add({ id: v.videoId, title: text(v.headline || v.title), channel: text(by),
              channelId: findAll(by, 'browseId')[0] || '', published: text(v.publishedTimeText), music: musicBadge(v) });
      }
    }
    for (const l of findAll(r, 'lockupViewModel')) {
      if (!l || !l.contentId || (l.contentType && l.contentType !== 'LOCKUP_CONTENT_TYPE_VIDEO')) continue;
      if (findAll(l, 'reelWatchEndpoint').length) continue;
      const meta = findAll(l, 'lockupMetadataViewModel')[0] || {};
      const rows = (findAll(meta, 'metadataRows')[0] || []).map((row) =>
        (row.metadataParts || []).map((p) => p.text && p.text.content).filter(Boolean));
      add({ id: l.contentId, title: (meta.title && meta.title.content) || '',
            channel: (rows[0] && rows[0][0]) || '',
            channelId: findAll(l, 'browseId').find((b) => /^UC/.test(b)) || '',
            published: (rows[1] && rows[1][rows[1].length - 1]) || '', music: musicBadge(l) });
    }
    return out;
  };
  // Миксы YouTube («Микс: …») — плейлисты RD с первым видео.
  const collectMixes = (r, out, seen) => {
    const add = (m) => {
      if (!m.playlistId || !m.videoId || !m.title || seen.has(m.playlistId)) return;
      seen.add(m.playlistId);
      out.push(m);
    };
    for (const name of ['radioRenderer', 'compactRadioRenderer']) {
      for (const m of findAll(r, name)) {
        const w = findAll(m, 'watchEndpoint')[0] || {};
        add({ title: text(m.title || m.headline), playlistId: m.playlistId || w.playlistId, videoId: w.videoId });
      }
    }
    for (const l of findAll(r, 'lockupViewModel')) {
      if (!l || l.contentType !== 'LOCKUP_CONTENT_TYPE_PLAYLIST' || !/^RD/.test(l.contentId || '')) continue;
      const meta = findAll(l, 'lockupMetadataViewModel')[0] || {};
      const w = findAll(l, 'watchEndpoint')[0] || {};
      add({ title: (meta.title && meta.title.content) || '', playlistId: l.contentId, videoId: w.videoId });
    }
    return out;
  };

  window.__fonCloud = {
    // { playlistId, tracks: [{ id, title, artist }] } — в порядке плейлиста.
    // Плейлист ищем по названию каждый раз: если лишний удалили в YouTube, берём оставшийся.
    async list(pid) {
      pid = (await findPlaylist()) || pid;
      if (!pid) return { playlistId: null, tracks: [] };
      const tracks = [];
      const seen = new Set();
      let r = await api('browse', { browseId: 'VL' + pid });
      for (let page = 0; page < 10 && r; page++) {
        for (const name of RENDERERS) {
          for (const v of findAll(r, name)) {
            if (!v || !v.videoId || seen.has(v.videoId)) continue;
            seen.add(v.videoId);
            tracks.push({ id: v.videoId, title: text(v.title || v.headline), artist: text(v.shortBylineText || v.longBylineText) });
          }
        }
        const next = findAll(r, 'continuationCommand')[0];
        r = next && next.token ? await api('browse', { continuation: next.token }) : null;
      }
      return { playlistId: pid, tracks };
    },
    // Добавить треки; плейлиста ещё нет — создать (приватный). Возвращает id плейлиста.
    async like(pid, ids) {
      pid = pid || await findPlaylist();
      if (!pid) {
        const r = await api('playlist/create', { title: TITLE, privacyStatus: 'PRIVATE', videoIds: ids });
        return r.playlistId || findAll(r, 'playlistId')[0] || null;
      }
      await api('browse/edit_playlist', {
        playlistId: pid,
        actions: ids.map((id) => ({ action: 'ACTION_ADD_VIDEO', addedVideoId: id }))
      });
      return pid;
    },
    // Лента подписок без Shorts: [{ id, title, channel, channelId, published }], новые сверху.
    async subscriptionVideos(pages) {
      const out = [];
      const seen = new Set();
      let r = await api('browse', { browseId: 'FEsubscriptions' });
      for (let page = 0; page < (pages || 3) && r; page++) {
        collectVideos(r, out, seen);
        const next = findAll(r, 'continuationCommand')[0];
        r = next && next.token ? await api('browse', { continuation: next.token }) : null;
      }
      return out;
    },
    // Запасные подборки, если YouTube Music недоступен: главная YouTube с фильтром «Музыка».
    // { chip, videos: [...], mixes: [{ title, playlistId, videoId }] }
    async musicFeed() {
      const home = await api('browse', { browseId: 'FEwhat_to_watch' });
      const chips = findAll(home, 'chipCloudChipRenderer').concat(findAll(home, 'chipViewModel'));
      const chip = chips.find((c) => /музык|music/i.test(text(c.text) || (typeof c.text === 'string' ? c.text : '')));
      let r = null;
      if (chip) {
        const cc = findAll(chip, 'continuationCommand')[0];
        const be = findAll(chip, 'browseEndpoint')[0];
        if (cc && cc.token) r = await api('browse', { continuation: cc.token });
        else if (be) r = await api('browse', be);
      }
      if (!r) return { chip: false, videos: [], mixes: [] };
      const videos = [], mixes = [], seen = new Set();
      for (let page = 0; page < 3 && r; page++) {
        collectVideos(r, videos, seen);
        collectMixes(r, mixes, seen);
        const next = findAll(r, 'continuationCommand').filter((c) => c && c.token).pop();
        r = null;
        if (next && videos.length < 40) { try { r = await api('browse', { continuation: next.token }); } catch (e) {} }
      }
      return { chip: true, videos, mixes };
    },
    async unlike(pid, id) {
      pid = pid || await findPlaylist();
      if (pid) {
        await api('browse/edit_playlist', {
          playlistId: pid,
          actions: [{ action: 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID', removedVideoId: id }]
        });
      }
      return pid;
    }
  };
})();
"""#

    // MARK: - Основное окно (лента, поиск, подписки)

    /// Подборки YouTube Music (тот же аккаунт Google) — из скрытого окна music.youtube.com.
    static let music = #"""
(() => {
  if (window.__fonMusic) return;
  const cookie = (name) => {
    const m = document.cookie.match(new RegExp('(?:^|; )' + name.replace(/[-_.]/g, '\\$&') + '=([^;]*)'));
    return m ? decodeURIComponent(m[1]) : null;
  };
  const sapisid = () => cookie('SAPISID') || cookie('__Secure-3PAPISID');
  const sha1 = async (s) => {
    const buf = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(s));
    return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
  };
  // Версия клиента — по дате (как делают сторонние клиенты YouTube Music); пара дней назад — точно существует.
  const day = new Date(Date.now() - 2 * 86400000).toISOString().slice(0, 10).replace(/-/g, '');
  const CONTEXT = { client: { clientName: 'WEB_REMIX', clientVersion: '1.' + day + '.01.00', hl: 'ru' }, user: {} };
  const api = async (endpoint, body, query) => {
    const headers = {
      'Content-Type': 'application/json',
      'X-Origin': location.origin,
      'X-Goog-AuthUser': '0',
      'X-Youtube-Client-Name': '67',
      'X-Youtube-Client-Version': CONTEXT.client.clientVersion
    };
    const sid = sapisid();
    if (sid) {
      const ts = Math.floor(Date.now() / 1000);
      headers['Authorization'] = 'SAPISIDHASH ' + ts + '_' + await sha1(ts + ' ' + sid + ' ' + location.origin);
    }
    const res = await fetch('/youtubei/v1/' + endpoint + '?prettyPrint=false' + (query || ''), {
      method: 'POST', credentials: 'include', headers,
      body: JSON.stringify(Object.assign({ context: CONTEXT }, body))
    });
    if (res.status === 401 || res.status === 403) throw new Error('signed-out');
    if (!res.ok) throw new Error('http-' + res.status);
    return res.json();
  };
  const findAll = (obj, key, out) => {
    out = out || [];
    if (obj && typeof obj === 'object') {
      for (const k in obj) {
        if (k === key) out.push(obj[k]);
        findAll(obj[k], key, out);
      }
    }
    return out;
  };
  const text = (t) => (t ? (t.simpleText || (t.runs || []).map((r) => r.text).join('')) : '');
  const thumb = (obj, size) => {
    const list = findAll(obj, 'thumbnails')[0] || [];
    const t = list[list.length - 1];
    if (!t || !t.url) return null;
    const url = t.url.startsWith('//') ? 'https:' + t.url : t.url;
    // Картинки googleusercontent отдаются нужного размера по параметру в адресе.
    return url.replace(/=w\d+-h\d+/, '=w' + size + '-h' + size);
  };
  const pageType = (nav) => {
    try { return nav.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType || ''; } catch (e) { return ''; }
  };
  const isArtist = (nav) => /ARTIST|USER_CHANNEL/.test(pageType(nav));
  const nextCont = (r) => { const c = findAll(r, 'nextContinuationData')[0]; return c && c.continuation; };
  const contQuery = (c) => '&ctoken=' + encodeURIComponent(c) + '&continuation=' + encodeURIComponent(c) + '&type=next';

  // Карточка или строка трека → { title, subtitle, thumb, videoId, playlistId, params, browseId, artist }.
  const parseItem = (wrap) => {
    const two = wrap && wrap.musicTwoRowItemRenderer;
    const row = wrap && wrap.musicResponsiveListItemRenderer;
    if (two) {
      const nav = two.navigationEndpoint || {};
      const p = nav.watchEndpoint || nav.watchPlaylistEndpoint ||
        findAll(two.thumbnailOverlay, 'watchPlaylistEndpoint')[0] || findAll(two.thumbnailOverlay, 'watchEndpoint')[0] || {};
      return {
        title: text(two.title), subtitle: text(two.subtitle), thumb: thumb(two.thumbnailRenderer, 544),
        videoId: p.videoId || null, playlistId: p.playlistId || null, params: p.params || null,
        browseId: (nav.browseEndpoint && nav.browseEndpoint.browseId) || null, artist: isArtist(nav)
      };
    }
    if (row) {
      const cols = (row.flexColumns || []).map((c) =>
        text(c.musicResponsiveListItemFlexColumnRenderer && c.musicResponsiveListItemFlexColumnRenderer.text)).filter(Boolean);
      const nav = row.navigationEndpoint || {};
      const p = findAll(row.overlay, 'watchEndpoint')[0] || findAll(row.flexColumns, 'watchEndpoint')[0] || {};
      return {
        title: cols[0] || '', subtitle: cols.slice(1).join(' • '), thumb: thumb(row.thumbnail, 226),
        videoId: (row.playlistItemData && row.playlistItemData.videoId) || p.videoId || null,
        playlistId: p.playlistId || null, params: p.params || null,
        browseId: (nav.browseEndpoint && nav.browseEndpoint.browseId) || null, artist: isArtist(nav)
      };
    }
    return null;
  };
  const playable = (i) => i && i.title && (i.videoId || i.playlistId || i.browseId);

  // Полки главной YouTube Music по порядку: { title, kind: songs | cards | artists, items }.
  // Ищем полки по всему ответу (вёрстка у разных клиентов разная), внутрь найденной полки не спускаемся.
  const SHELVES = ['musicCarouselShelfRenderer', 'musicImmersiveCarouselShelfRenderer', 'musicShelfRenderer', 'gridRenderer'];
  const walkShelves = (obj, out) => {
    if (obj && typeof obj === 'object') {
      for (const k in obj) {
        if (SHELVES.includes(k)) out.push(obj[k]);
        else walkShelves(obj[k], out);
      }
    }
    return out;
  };
  const parseShelves = (r) => {
    const out = [];
    for (const s of walkShelves(r, [])) {
      const contents = s.contents || s.items || [];
      const items = contents.map(parseItem).filter(playable);
      if (!items.length) continue;
      const songs = contents.some((c) => c.musicResponsiveListItemRenderer);
      out.push({
        title: text(findAll(s.header, 'title')[0]) || text(s.title) || 'Подборка',
        kind: items.every((i) => i.artist) ? 'artists' : (songs ? 'songs' : 'cards'),
        items
      });
    }
    return out;
  };
  // Коротко, что ответил YouTube, — если полок не нашлось (для скриншота владельца).
  const describe = (r) => {
    try {
      const keys = Object.keys(r || {}).filter((k) => k !== 'responseContext' && k !== 'trackingParams');
      const body = JSON.stringify(r.contents || r.alerts || r.error || r).replace(/"(clickTrackingParams|trackingParams)":"[^"]*",?/g, '');
      return keys.join(',') + ' ' + body.slice(0, 140);
    } catch (e) { return String(e); }
  };

  window.__fonMusic = {
    signedIn: () => !!sapisid(),
    async home() {
      const first = await api('browse', { browseId: 'FEmusic_home' });
      let r = first;
      const shelves = parseShelves(r);
      let c = nextCont(r);
      for (let page = 0; page < 3 && c; page++) {
        try { r = await api('browse', {}, contQuery(c)); } catch (e) { break; }
        shelves.push(...parseShelves(r));
        c = nextCont(r);
      }
      return { signedIn: !!sapisid(), shelves, diag: shelves.length ? '' : describe(first) };
    },
    // Исполнители, на которых вы подписаны (Медиатека YouTube Music → Подписки).
    async artists() {
      if (!sapisid()) throw new Error('signed-out');
      const out = [];
      const seen = new Set();
      let r = await api('browse', { browseId: 'FEmusic_library_corpus_artists' });
      for (let page = 0; page < 6 && r; page++) {
        for (const w of findAll(r, 'musicResponsiveListItemRenderer')) {
          const it = parseItem({ musicResponsiveListItemRenderer: w });
          if (!it || !it.title || !it.browseId || seen.has(it.browseId)) continue;
          seen.add(it.browseId);
          it.artist = true;
          out.push(it);
        }
        const c = nextCont(r);
        r = null;
        if (c) { try { r = await api('browse', {}, contQuery(c)); } catch (e) {} }
      }
      return out;
    },
    // Что включить по карточке: { videoId, playlistId } (у альбома/плейлиста — первый трек, у исполнителя — его радио).
    async resolve(it) {
      if (it.videoId) return { videoId: it.videoId, playlistId: it.playlistId || null };
      let pid = it.playlistId;
      let params = it.params;
      if (!pid && it.browseId) {
        const r = await api('browse', { browseId: it.browseId });
        const radio = findAll(r, 'startRadioButton')[0];
        const w = (radio && findAll(radio, 'watchPlaylistEndpoint')[0]) ||
          findAll(r, 'watchPlaylistEndpoint')[0] || findAll(r, 'watchEndpoint')[0];
        if (!w) return null;
        if (w.videoId) return { videoId: w.videoId, playlistId: w.playlistId || null };
        pid = w.playlistId;
        params = w.params;
      }
      if (!pid) return null;
      const body = { playlistId: pid, enablePersistentPlaylistPanel: true, isAudioOnly: true };
      if (params) body.params = params;
      const n = await api('next', body);
      const first = findAll(n, 'playlistPanelVideoRenderer')[0];
      return first && first.videoId ? { videoId: first.videoId, playlistId: pid } : null;
    }
  };
})();
"""#

    static let browse = #"""
(() => {
  const fon = window.__fon;
  if (!fon || fon.role) return;
  fon.role = 'browse';

  // Главная в режиме музыки (приложение открывает «/#fon-music»): обычные рекомендации,
  // но с включённым фильтром «Музыка» вверху ленты.
  if (location.pathname === '/' && location.hash === '#fon-music') {
    try { history.replaceState(history.state, '', '/' + location.search); } catch (e) {}
    let tries = 0;
    const timer = setInterval(() => {
      if (++tries > 40 || location.pathname !== '/') { clearInterval(timer); return; }
      const chips = document.querySelectorAll('ytm-chip-cloud-chip-renderer, yt-chip-cloud-chip-renderer');
      for (const chip of chips) {
        const label = (chip.innerText || chip.textContent || '').trim();
        if (/^(music|музыка)$/i.test(label)) {
          (chip.querySelector('button, a, [role="button"], [role="tab"]') || chip).click();
          clearInterval(timer);
          return;
        }
      }
    }, 500);
  }

  // Своя нижняя панель YouTube не нужна — у приложения есть своя.
  fon.addStyle(`
    ytm-pivot-bar-renderer { display: none !important; }
    ytm-miniplayer, .ytm-miniplayer { display: none !important; }
  `);

  // Нажатие на видео — открываем в плеере, а лента остаётся на месте.
  window.addEventListener('click', (e) => {
    const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (!a) return;
    const u = fon.absURL(a.getAttribute('href'));
    if (!u || !/youtube\.com$/.test(u.hostname) || u.pathname !== '/watch') return;
    e.preventDefault();
    e.stopImmediatePropagation();
    fon.post({ type: 'open', url: u.href });
  }, true);

  // Превью в ленте не играют. Shorts играют здесь же — тогда ставим плеер на паузу.
  document.addEventListener('play', (e) => {
    const v = e.target;
    if (!(v instanceof HTMLMediaElement)) return;
    if (location.pathname.startsWith('/shorts')) { fon.post({ type: 'browsePlaying' }); return; }
    try { v.muted = true; v.pause(); } catch (err) {}
  }, true);
})();
"""#

    /// Скрытое окно www.youtube.com (`HiddenPage.desktop`): защитный токен (PO token) для потока системного
    /// плеера. Без него googlevideo отвечает 403 (1.57: HLS нашёлся, но AVPlayer -12660). Токен выдаёт
    /// BotGuard Google — его скрипт запускается здесь, как на странице YouTube (схема — как в BgUtils/yt-dlp):
    /// Create → интерпретатор BotGuard → снимок → GenerateIT (integrity token) → minter(идентификатор).
    static let potoken = #"""
(() => {
  if (window.__fonPot) return;
  const REQUEST_KEY = 'O43z0dpjhgX20SCx4KAo';
  const HEADERS = {
    'content-type': 'application/json+protobuf',
    'x-goog-api-key': 'AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw',
    'x-user-agent': 'grpc-web-javascript/0.1'
  };
  const b64ToU8 = (s) => {
    const bin = atob(String(s).replace(/-/g, '+').replace(/_/g, '/').replace(/\./g, '='));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  };
  const u8ToB64 = (u) => {
    let bin = '';
    for (let i = 0; i < u.length; i++) bin += String.fromCharCode(u[i]);
    return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_');
  };
  const descramble = (s) => new TextDecoder().decode(b64ToU8(s).map((b) => (b + 97) & 255));
  const timeout = (promise, ms, what) => Promise.race([promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(what + ': нет ответа')), ms))]);
  const loadScript = (src) => new Promise((resolve, reject) => {
    const el = document.createElement('script');
    el.src = src;
    el.onload = resolve;
    el.onerror = () => reject(new Error('скрипт BotGuard не загрузился'));
    (document.head || document.documentElement).appendChild(el);
  });
  const post = async (path, body) => {
    const res = await fetch(path, { method: 'POST', headers: HEADERS, body: JSON.stringify(body), credentials: 'include' });
    if (!res.ok) throw new Error(path.split('/').pop() + ' HTTP ' + res.status);
    return res.json();
  };
  let minter = null, minterUntil = 0;
  const createMinter = async () => {
    const raw = await post('/api/jnn/v1/Create', [REQUEST_KEY]);
    let data = [];
    if (raw.length > 1 && typeof raw[1] === 'string') data = JSON.parse(descramble(raw[1]) || '[]');
    else if (raw.length && typeof raw[0] === 'object') data = raw[0];
    const pick = (w) => (Array.isArray(w) ? w.find((x) => x && typeof x === 'string') : null);
    const script = pick(data[1]), url = pick(data[2]), program = data[4], globalName = data[5];
    if (!program || !globalName) throw new Error('Create: нет программы');
    if (!window[globalName]) {
      if (script) (0, eval)(script);
      else if (url) await timeout(loadScript(url.startsWith('//') ? 'https:' + url : url), 15000, 'скрипт BotGuard');
      else throw new Error('Create: нет интерпретатора');
    }
    const vm = window[globalName];
    if (!vm || typeof vm.a !== 'function') throw new Error('нет BotGuard');
    let snapshot = null;
    const callback = (asyncSnapshot) => { snapshot = asyncSnapshot; };
    await vm.a(program, callback, true, undefined, () => {}, [[], []])[0];
    for (let i = 0; i < 40 && !snapshot; i++) await new Promise((r) => setTimeout(r, 50));
    if (typeof snapshot !== 'function') throw new Error('BotGuard: нет снимка');
    const signal = [];
    const response = await timeout(new Promise((resolve) => snapshot(resolve, [undefined, undefined, signal, undefined])), 15000, 'снимок BotGuard');
    const it = await post('/api/jnn/v1/GenerateIT', [REQUEST_KEY, response]);
    const integrity = it && it[0];
    if (typeof integrity !== 'string') throw new Error('GenerateIT: нет токена');
    const getMinter = signal[0];
    if (typeof getMinter !== 'function') throw new Error('BotGuard: нет minter');
    const mint = await getMinter(b64ToU8(integrity));
    if (typeof mint !== 'function') throw new Error('BotGuard: minter не функция');
    minter = mint;
    minterUntil = Date.now() + Math.max(600, (Number(it[1]) || 3600) - 300) * 1000;
  };
  window.__fonPot = {
    // Токен для идентификатора (dataSyncId аккаунта или visitorData) и сколько секунд он годен.
    async mint(identifier) {
      if (!minter || Date.now() > minterUntil) await timeout(createMinter(), 40000, 'BotGuard');
      const out = await minter(new TextEncoder().encode(identifier));
      if (!(out instanceof Uint8Array)) throw new Error('токен не получен');
      return { token: u8ToB64(out), ttl: Math.round((minterUntil - Date.now()) / 1000) };
    }
  };
})();
"""#

    /// Скрытое окно `SafariStream`: компьютерная версия www.youtube.com (`app=desktop`) на iPhone играет видео
    /// системным плеером iOS по обычной ссылке HLS (наблюдение владельца). Ловим эту ссылку, звук не нужен.
    static let safariSource = #"""
(() => {
  const send = (u) => {
    try {
      if (u && /^https?:/.test(String(u))) window.webkit.messageHandlers.fonSrc.postMessage({ src: String(u), title: document.title || '' });
    } catch (e) {}
  };
  const proto = HTMLMediaElement.prototype;
  const desc = Object.getOwnPropertyDescriptor(proto, 'src');
  if (desc && desc.set) {
    Object.defineProperty(proto, 'src', {
      configurable: true,
      get() { return desc.get.call(this); },
      set(value) { send(value); try { this.muted = true; } catch (e) {} desc.set.call(this, value); }
    });
  }
  const setAttr = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function (name, value) {
    if ((this instanceof HTMLMediaElement || this instanceof HTMLSourceElement) && String(name).toLowerCase() === 'src') send(value);
    return setAttr.call(this, name, value);
  };
  setInterval(() => {
    for (const v of document.querySelectorAll('video, audio')) {
      try { v.muted = true; } catch (e) {}
      send(v.currentSrc || v.src);
    }
  }, 300);
})();
"""#
}
