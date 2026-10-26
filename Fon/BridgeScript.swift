import Foundation

/// JavaScript, который встраивается в каждую страницу YouTube до её собственного кода.
enum BridgeScript {
    static let source = #"""
(() => {
  if (window.__fon) return;
  const fon = window.__fon = {
    bg: false,          // приложение свёрнуто
    bgAt: 0,            // когда свернули
    wasPlaying: false,  // играло ли в момент сворачивания
    userPaused: false   // пауза поставлена тобой, а не системой
  };

  // 1. Страница всегда «видна» — YouTube не узнает, что приложение свёрнуто.
  const fake = (name, value) => {
    try { Object.defineProperty(Document.prototype, name, { get: () => value, configurable: true }); } catch (e) {}
  };
  fake('hidden', false);
  fake('webkitHidden', false);
  fake('visibilityState', 'visible');
  fake('webkitVisibilityState', 'visible');
  try { Document.prototype.hasFocus = function () { return true; }; } catch (e) {}

  const swallow = (e) => e.stopImmediatePropagation();
  ['visibilitychange', 'webkitvisibilitychange'].forEach((t) => {
    window.addEventListener(t, swallow, true);
    document.addEventListener(t, swallow, true);
  });
  window.addEventListener('blur', (e) => { if (e.target === window) e.stopImmediatePropagation(); }, true);

  // 2. Основное видео на странице.
  const video = () =>
    document.querySelector('video.html5-main-video') || document.querySelector('#player video') || document.querySelector('video');

  // Окно «Видео приостановлено. Продолжить просмотр?» — нажимаем «Да».
  const clickContinue = () => {
    const buttons = document.querySelectorAll(
      '[role="dialog"] button, ytm-dialog button, tp-yt-paper-dialog button, .dialog button, ytm-button-renderer button'
    );
    for (const b of buttons) {
      const label = (b.innerText || b.getAttribute('aria-label') || '').trim();
      if (/^(yes|да|продолжить|continue)/i.test(label) && b.offsetParent !== null) { b.click(); return true; }
    }
    return false;
  };

  const resume = (v) => setTimeout(() => {
    if (!fon.userPaused && v.paused && !v.ended) v.play().catch(() => {});
  }, 150);

  // 3. Если система или YouTube ставят паузу сразу после сворачивания — включаем обратно.
  document.addEventListener('play', (e) => {
    if (e.target instanceof HTMLVideoElement) fon.userPaused = false;
  }, true);

  document.addEventListener('pause', (e) => {
    const v = e.target;
    if (!(v instanceof HTMLVideoElement) || v.ended) return;
    if (!fon.bg) { fon.userPaused = true; return; }
    if (fon.userPaused) return;
    const justBackgrounded = Date.now() - fon.bgAt < 4000;
    if (justBackgrounded || clickContinue()) resume(v);
  }, true);

  // 4. Вызовы из приложения (сворачивание, экран блокировки, наушники).
  fon.setBackground = (isBg) => {
    fon.bg = isBg;
    if (isBg) {
      fon.bgAt = Date.now();
      const v = video();
      fon.wasPlaying = !!(v && !v.paused);
    }
  };

  fon.resumeIfNeeded = () => {
    const v = video();
    if (v && fon.wasPlaying && !fon.userPaused && v.paused && !v.ended) v.play().catch(() => {});
  };

  const findNextButton = () => {
    const direct = document.querySelector('.ytp-next-button');
    if (direct) return direct;
    for (const b of document.querySelectorAll('button[aria-label]')) {
      if (/next|следующ|далее/i.test(b.getAttribute('aria-label'))) return b;
    }
    return null;
  };

  fon.cmd = (c, arg) => {
    const v = video();
    if (!v) return;
    switch (c) {
      case 'play':   fon.userPaused = false; v.play().catch(() => {}); break;
      case 'pause':  fon.userPaused = true;  v.pause(); break;
      case 'toggle': fon.cmd(v.paused ? 'play' : 'pause'); break;
      case 'seek':   if (typeof arg === 'number') v.currentTime = arg; break;
      case 'next': {
        const btn = findNextButton();
        if (btn) btn.click();
        else if (isFinite(v.duration)) v.currentTime = Math.max(0, v.duration - 0.2); // автоплей включит следующее
        break;
      }
      case 'prev':
        if (v.currentTime > 3) v.currentTime = 0; else history.back();
        break;
    }
  };

  // 5. Раз в секунду отправляем приложению, что играет — для экрана блокировки.
  const videoId = () => {
    try {
      const u = new URL(location.href);
      if (u.searchParams.get('v')) return u.searchParams.get('v');
      const m = u.pathname.match(/\/(shorts|live)\/([\w-]{6,})/);
      return m ? m[2] : null;
    } catch (e) { return null; }
  };

  const post = (msg) => {
    try { window.webkit.messageHandlers.fon.postMessage(msg); } catch (e) {}
  };

  setInterval(() => {
    const v = video();
    if (!v || !(v.currentSrc || v.src)) { post({ type: 'state', active: false }); return; }

    const md = navigator.mediaSession && navigator.mediaSession.metadata;
    let title = md && md.title ? md.title : (document.title || '').replace(/\s*-\s*YouTube\s*$/, '');
    let artist = md && md.artist ? md.artist : '';
    let artwork = '';
    if (md && md.artwork && md.artwork.length) artwork = md.artwork[md.artwork.length - 1].src;
    const id = videoId();
    if (!artwork && id) artwork = 'https://i.ytimg.com/vi/' + id + '/hqdefault.jpg';

    post({
      type: 'state',
      active: true,
      title: title || 'YouTube',
      artist: artist,
      artwork: artwork,
      duration: isFinite(v.duration) ? v.duration : 0,
      time: v.currentTime || 0,
      paused: v.paused,
      rate: v.playbackRate || 1
    });
  }, 1000);
})();
"""#
}
