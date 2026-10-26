# Fon — контекст проекта для Claude

## Что это
Личное iOS-приложение: обёртка над m.youtube.com, чтобы слушать музыку с YouTube в фоне на iPhone (как Background Play в Brave). Только для себя, не для App Store. Общение с владельцем — на русском.

## Ограничения окружения (важно)
- **Mac нет.** Владелец на Windows. Xcode локально недоступен.
- **Сборка — только в облаке:** `.github/workflows/build.yml` на `macos-latest`: XcodeGen → `xcodebuild` без подписи → `Fon.ipa` в Artifacts (`Fon-ipa`). Сборка запускается на каждый push в `main`.
- Проект Xcode **не хранится** в репозитории — его генерирует XcodeGen из `project.yml`. Новые `.swift` в папке `Fon/` подхватываются автоматически. Не создавай `.js`-файлы в `Fon/` (Xcode может положить их в Compile Sources) — JS живёт строками в `Scripts.swift`.
- **Установка на телефон:** iloader (Windows) с бесплатным Apple ID, подпись живёт 7 дней. Sideloadly с конца октября 2026 не работает (ошибка Apple -80046).
- Проверить на настоящем айфоне можно только руками владельца — проси скриншоты и описание поведения.
- Логи GitHub Actions могут быть недоступны для чтения из облачной сессии; при ошибке сборки проси владельца скопировать текст ошибки.

## Архитектура
| Файл | Роль |
| --- | --- |
| `Fon/AppDelegate.swift` | `AVAudioSession .playback`, корневой `MainViewController` (без SceneDelegate) |
| `Fon/MainViewController.swift` | Лента: **свой WKWebView на каждую вкладку** (создаётся лениво, не перезагружается при переключении; повторное нажатие — наверх, затем к корню). Нативный `UITabBar`: Главная/Поиск/Подписки/Вы/«Музыка·Видео» (последняя — переключатель режима). `PlayerView` поверх; уход в фон, прерывания (звонки) |
| `Fon/Settings.swift` | `Settings.musicMode` (UserDefaults `musicMode`, по умолчанию вкл.) — общий для плеера и вкладок |
| `Fon/PlayerView.swift` | Отдельный WKWebView со страницей `/watch`. Режимы: мини-полоска (64pt над вкладками) и развёрнутый. Кнопки: ♪ — режим музыки, PiP («картинка в картинке» через `webkitSetPresentationMode`) |
| `Fon/SearchViewController.swift` | Нативный поиск: история (UserDefaults `searchHistory`) + подсказки `suggestqueries.google.com` (client=firefox, ds=yt) |
| `Fon/Scripts.swift` | JS, внедряемый в начале документа: `common` (оба окна), `player`, `browse` |
| `Fon/WebViewFactory.swift` | Общая конфигурация WKWebView, Safari User-Agent, правила переходов |
| `project.yml` | XcodeGen; `UIBackgroundModes: [audio]`, iOS 16+, iPhone + iPad (`TARGETED_DEVICE_FAMILY 1,2`), bundle id `com.personal.fon` |

Оба WKWebView используют `WKWebsiteDataStore.default()` — вход в Google общий.

## Ключевые приёмы
- **Видимость:** `document.hidden`/`visibilityState` всегда «visible», события `visibilitychange` перехватываются на window (capture) и не доходят до YouTube; настоящее состояние — `__fon.realHidden`.
- **Автопродолжение в фоне (как Brave `MediaBackgroundingScript.js`):** `HTMLMediaElement.prototype.pause/play` обёрнуты — пауза из JS = пауза пользователя (`__fonUserPaused`). Пауза без JS (от WebKit при сворачивании) + переход в hidden в пределах 2 с → вызываем оригинальный `play()`. Плюс `PlayerView.kickResume()` после `didEnterBackground`.
- **Экран блокировки:** Now Playing ведёт сам WebKit через `navigator.mediaSession`. `setActionHandler` перехвачен: наши play/pause/nexttrack/previoustrack/seekto, `seekforward/seekbackward = null`, YouTube их не перезапишет. Нативного `MPRemoteCommandCenter` нет — он конфликтовал с WebKit.
- **Лента → плеер:** клик по `a[href]` с путём `/watch` в ленте перехватывается и уходит в плеер (`{type:'open'}`); запасной путь — KVO на `url` ленты. В плеере ссылки не на `/watch` уходят в ленту (`{type:'browse'}`).
- **Мини-режим:** класс `fon-mini` на `<html>` растягивает `#player-container-id/.player-container/#player` и `video` на весь viewport; webview в мини-полоске 16:9.
- **Режим музыки / экономия:** класс `fon-music` прячет `video` (opacity 0) и показывает обложку `i.ytimg.com/vi/<id>/hqdefault.jpg`; качество — минимальное через `movie_player.setPlaybackQualityRange/setPlaybackQuality`. В фоне качество тоже падает до минимума (кроме PiP). YouTube запоминает качество в `localStorage['yt-player-quality']` — из-за этого 144p «прилипало»; теперь в режиме видео ключ стирается в начале документа, а после понижения качество явно ставится в hd720 (iPhone) / hd1080 (iPad). Чистый «только звук» в веб-плеере невозможен (протокол YouTube), это осознанный компромисс.
- **Режим музыки — контент:** главная вкладка грузит музыкальный раздел `/channel/UC-9-kyTW8ZkZNDHQJ6FgpwQ`; видео открывается с Mix-плейлистом `&list=RD<id>` (похожая музыка, как радио в YT Music); под плеером скрыты комментарии и Shorts.
- Скрываем родную нижнюю панель m.youtube (`ytm-pivot-bar-renderer`).

## Проверено владельцем на iPhone (версия «режим музыки»)
- Фон работает (короткая ~1 с пауза при сворачивании), экран блокировки, next/prev, мини-плеер, обложка — ок.
- Было: 144p залипало после выключения ♪ — исправлено (см. выше), ждёт проверки.
- Известное ограничение: если долго стоять на паузе в фоне, ▶ в пункте управления иногда не срабатывает — iOS усыпляет процесс WebKit; нужно открыть приложение. Нативный `MPRemoteCommandCenter` раньше конфликтовал с WebKit.

## Что ещё НЕ проверено на устройстве
- Вкладки с отдельными WKWebView, переключатель режима, музыкальная главная, Mix `list=RD`, скрытие комментариев.
- PiP из кнопки в плеере; iPad-раскладка.
- Срабатывает ли автопродолжение после сворачивания (в симуляции jsdom — да).
- Селекторы мини-режима и обложки на реальной вёрстке m.youtube.
- Команды качества `movie_player` на мобильном плеере; не застревает ли 144p после возврата в режиме видео.
- «Следующий» на экране блокировки (кнопка следующего в плейлисте или первое видео из рекомендаций).
- Кодировка подсказок поиска для кириллицы.

## Как работать
1. Правки → проверка JS: вырезать строки из `Scripts.swift` и прогнать `node --check`; логику можно гонять в jsdom со стабами `play/pause/visibilityState/mediaSession`.
2. Коммит и push в `main` → дождаться зелёной сборки в Actions → дать владельцу ссылку на run (Artifacts → Fon-ipa).
3. Владелец ставит через iloader поверх старой версии и присылает результат.
