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
  proto.pause = function () { this.__fonUserPaused = true; return origPause.call(this); };
  proto.play = function () { this.__fonUserPaused = false; return origPlay.call(this); };

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
    if (fon.realHidden && systemPausedEl && Date.now() - systemPausedAt < 2000) {
      resumeSoon(systemPausedEl);
    }
  };

  // Подстраховка из приложения после ухода в фон.
  fon.resumeIfNeeded = () => {
    if (systemPausedEl && Date.now() - systemPausedAt < 6000) tryResume(systemPausedEl);
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
      case 'pause':  if (v) v.pause(); break;
      case 'toggle': if (v) { v.paused ? v.play().catch(() => {}) : v.pause(); } break;
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
      z-index: 2147483646 !important; background: #000 !important;
    }
    html.fon-full .html5-video-container {
      position: absolute !important; top: 0 !important; left: 0 !important;
      width: 100% !important; height: 100% !important;
    }
    html.fon-full video,
    html.fon-full.fon-music video {
      position: absolute !important; top: 0 !important; left: 0 !important;
      width: 100% !important; height: 100% !important; object-fit: contain !important; opacity: 1 !important;
    }
  `);
  fon.setMini = (on) => { document.documentElement.classList.toggle('fon-mini', !!on); };

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
    fon.post({ type: 'fullscreen', on });
    if (v) fire(v, on ? 'webkitbeginfullscreen' : 'webkitendfullscreen');
    fire(document, 'fullscreenchange');
    fire(document, 'webkitfullscreenchange');
    setTimeout(() => { fire(window, 'resize'); try { applyQuality(); } catch (e) {} }, 300);
  };
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
  setInterval(() => {
    const v = fon.video();
    const id = currentId();
    if (!v || !id) { if (!fon.realHidden) fon.post({ type: 'state', active: false }); return; }

    applyQuality();
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

    if (fon.realHidden) return; // в фоне интерфейс не виден — не тратим энергию на сообщения

    fon.post({
      type: 'state', active: true, id, title, artist, thumb,
      paused: v.paused, loop: !!v.loop, time: v.currentTime || 0, duration: isFinite(v.duration) ? v.duration : 0
    });
  }, 1000);
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
