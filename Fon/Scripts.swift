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
    /* Панель управления YouTube (пауза, перемотка, ⚙ качество, выход) — поверх растянутого видео. */
    html.fon-full #player-control-overlay,
    html.fon-full ytm-custom-control {
      position: fixed !important; top: 0 !important; left: 0 !important;
      width: 100vw !important; height: 100vh !important;
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
  const setFull = (on, el) => {
    on = !!on;
    if (on === fon.isFull) return;
    fon.isFull = on;
    const v = fon.video();
    fullEl = on ? (el || document.getElementById('player-container-id') || v || document.documentElement) : null;
    document.documentElement.classList.toggle('fon-full', on);
    // Вертикальное видео — полный экран остаётся вертикальным (приложение не поворачивает телефон).
    fon.post({ type: 'fullscreen', on, vertical: !!(v && v.videoHeight > v.videoWidth) });
    if (v) fire(v, on ? 'webkitbeginfullscreen' : 'webkitendfullscreen');
    fire(document, 'fullscreenchange');
    fire(document, 'webkitfullscreenchange');
    setTimeout(() => { fire(window, 'resize'); try { applyQuality(); } catch (e) {} }, 300);
    for (const t of [400, 1200]) setTimeout(() => fon.repaint(), t);
  };

  // После поворота, выхода из полного экрана или возврата в приложение WebKit иногда теряет
  // картинку видео (чёрный экран, звук идёт). Заставляем его перерисовать слой видео.
  // Видео на один кадр убираем и возвращаем — WebKit пересоздаёт слой с картинкой (звук не прерывается).
  const raf = window.requestAnimationFrame ? window.requestAnimationFrame.bind(window) : (f) => setTimeout(f, 16);
  let repainting = false;
  let quietUntil = 0; // перестройки страницы в ответ на нашу же перерисовку не считаем — без зацикливания
  fon.repaint = () => {
    const v = fon.video();
    quietUntil = Date.now() + 1200;
    fire(window, 'resize');
    if (!v || repainting) return;
    repainting = true;
    const prev = v.style.display;
    v.style.display = 'none';
    raf(() => raf(() => { v.style.display = prev; repainting = false; }));
  };
  let repaintTimer = null;
  const repaintSoon = (delay) => {
    if (Date.now() < quietUntil) return;
    clearTimeout(repaintTimer);
    repaintTimer = setTimeout(() => { if (!fon.realHidden) fon.repaint(); }, delay || 400);
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
  window.addEventListener('touchend', () => { if (fon.isFull) repaintSoon(500); }, true);
  fon.setFull = setFull;
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

  // --- 5. Ссылки не на видео (канал, поиск) открываем в основном окне.
  window.addEventListener('click', (e) => {
    const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (!a) return;
    const u = fon.absURL(a.getAttribute('href'));
    if (!u || !/youtube\.com$/.test(u.hostname)) return;
    if (u.pathname === '/watch') return;
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

  window.__fonCloud = {
    // { playlistId, tracks: [{ id, title, artist }] } — в порядке плейлиста.
    async list(pid) {
      pid = pid || await findPlaylist();
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
}
