# Fon — контекст проекта для Claude

## Что это
Личное iOS-приложение: обёртка над m.youtube.com, чтобы слушать музыку с YouTube в фоне на iPhone (как Background Play в Brave). Только для себя, не для App Store. Общение с владельцем — на русском.

## Ограничения окружения (важно)
- **Mac нет.** Владелец на Windows. Xcode локально недоступен.
- **Сборка — только в облаке:** `.github/workflows/build.yml` на `macos-15-intel` (arm64-машины GitHub бывают перегружены — сборка отменялась, не дождавшись runner): XcodeGen → `xcodebuild` без подписи (версия `1.<run_number>`, build `<run_number>`) → `Fon.ipa` в Artifacts (`Fon-ipa`) **и в Releases** (тег `build-N`, вместе с `apps.json`). `apps.json` — источник SideStore: `https://github.com/esasabiyatov-afk/fon/releases/latest/download/apps.json`; по нему SideStore показывает обновления Fon. Работает, только когда репозиторий публичный (владелец согласился сделать его публичным 27.10.2026). Сборка запускается на каждый push в `main` (только main) и вручную (workflow_dispatch).
- Проект Xcode **не хранится** в репозитории — его генерирует XcodeGen из `project.yml`. Новые `.swift` в папке `Fon/` подхватываются автоматически. Не создавай `.js`-файлы в `Fon/` (Xcode может положить их в Compile Sources) — JS живёт строками в `Scripts.swift`.
- **Установка на телефон:** iloader (Windows) с бесплатным Apple ID, подпись живёт 7 дней. Sideloadly с конца октября 2026 не работает (ошибка Apple -80046).
- **Продление (с 27.10.2026):** владелец перешёл на SideStore (установлен через iloader) + LocalDevVPN из App Store; вход в Apple ID в SideStore заработал после выбора anisette-сервера «SideStore (New)» и Reset adi.pb. Fon ставится в SideStore через «+» из скачанного IPA; автопродление — автоматизация «Команд» (Refresh All). Fon стоит и на устройствах семьи — у каждого нужен свой SideStore.
- Проверить на настоящем айфоне можно только руками владельца — проси скриншоты и описание поведения.
- Логи GitHub Actions могут быть недоступны для чтения из облачной сессии; при ошибке сборки проси владельца скопировать текст ошибки.

## Архитектура
| Файл | Роль |
| --- | --- |
| `Fon/AppDelegate.swift` | `AVAudioSession .playback`; `SceneDelegate` (там же) создаёт окно с `MainViewController`. Сцены нужны, чтобы окно на iPad растягивалось на весь экран (`UIRequiresFullScreen` убран) |
| `Fon/MainViewController.swift` | Лента: **свой WKWebView на каждую вкладку** (создаётся лениво, не перезагружается при переключении; повторное нажатие — наверх, затем к корню). Своя панель вкладок `TabBarView` (системный `UITabBar` на iOS 26 рисовал иконки выше своей границы — они налезали на мини-плеер): Главная/Поиск/Подписки/Вы/«Музыка·Видео» (последняя — переключатель режима). В режиме музыки «Вы» → нативная «Медиатека» (`LibraryViewController` в `UINavigationController`, дочерний VC в `browseContainer`). Свои плейлисты играются через `/watch_videos?video_ids=…` (временный плейлист YouTube, до 50 id). `PlayerView` поверх; уход в фон, прерывания (звонки) |
| `Fon/Settings.swift` | `Settings.musicMode` (UserDefaults `musicMode`, по умолчанию вкл.) — общий для плеера и вкладок |
| `Fon/PlayerView.swift` | Отдельный WKWebView со страницей `/watch`. Режимы: мини-полоска (64pt над вкладками) и развёрнутый. В режиме музыки развёрнутый = нативный `MusicPlayerView` поверх веб-плеера (webview играет под ним); кнопка «список» показывает страницу YouTube, ♪ — назад к плееру. В режиме видео: шапка с PiP и ♪. Свайп вниз по видео/обложке (`UIPanGestureRecognizer`, плеер едет за пальцем) сворачивает; в полном экране — выходит из него |
| `Fon/MusicPlayerView.swift` | Плеер в стиле Spotify: квадратная обложка, градиент под её средний цвет, ♡, ⊕ в плейлист, ползунок (плавно интерполируется между сообщениями раз в 1 с), prev/play/next, повтор трека (`video.loop`) |
| `Fon/Library.swift` | `Library` — понравившиеся и плейлисты (JSON в Application Support), `ArtworkLoader` — квадратные обложки из `i.ytimg.com` (maxres→sd→hq): кадр 16:9; если поля по бокам однотонные (обложка альбома в центре) — центральный квадрат, иначе картинка целиком + размытая копия сверху/снизу; средний цвет. `TrackTitle.clean` — «Исполнитель - Песня (Official Video)» → песня + исполнитель (в режиме музыки: плеер, мини-полоска, медиатека) |
| `Fon/LibraryViewController.swift` | Медиатека и список треков (слушать/перемешать, удалить, поменять порядок) |
| `Fon/Signature.swift` | Срок подписи из `embedded.mobileprovision` (`ExpirationDate`): при <48 ч — алерт (не чаще раза в 12 ч) с кнопкой «Открыть SideStore» (`sidestore://`); дата в подвале медиатеки |
| `Fon/TabBarView.swift` | Своя нижняя панель: 50 pt кнопок (иконка над подписью) + safe area; `setItem(_:title:icon:color:)`, `select(_:)` |
| `Fon/SearchViewController.swift` | Нативный поиск: «Недавние» (UserDefaults `searchHistory`, кнопка «Очистить») + подсказки `suggestqueries.google.com` (client=firefox, ds=yt), «↖» подставляет строку в поле; `initialText` — текущий запрос. Лупа в шапке m.youtube (оба окна) перехватывается скриптом `common` → `{type:'search'}` → этот экран |
| `Fon/Scripts.swift` | JS, внедряемый в начале документа: `common` (оба окна), `player`, `browse` |
| `Fon/WebViewFactory.swift` | Общая конфигурация WKWebView, Safari User-Agent, правила переходов |
| `project.yml` | XcodeGen; `UIBackgroundModes: [audio]`, iOS 16+, iPhone + iPad (`TARGETED_DEVICE_FAMILY 1,2`), bundle id `com.personal.fon` |

Оба WKWebView используют `WKWebsiteDataStore.default()` — вход в Google общий.

## Ключевые приёмы
- **Видимость:** `document.hidden`/`visibilityState` всегда «visible», события `visibilitychange` перехватываются на window (capture) и не доходят до YouTube; настоящее состояние — `__fon.realHidden`.
- **Автопродолжение в фоне (как Brave `MediaBackgroundingScript.js`):** `HTMLMediaElement.prototype.pause/play` обёрнуты — пауза из JS **при видимой странице** = пауза пользователя (`__fonUserPaused`); в фоне пауза из JS YouTube не считается пользовательской (обычно это реакция на отказ WebKit), настоящая пауза в фоне — только наша команда (`fon.explicitPause` → `__fonHardPause`). Пауза без JS (от WebKit при сворачивании) + переход в hidden в пределах 2 с → вызываем оригинальный `play()`.
- **Старт в фоне (видео ещё грузилось при сворачивании):** без звука iOS усыпляет приложение и WebKit, видео не стартует. `PlayerView.watchBackgroundStart` держит `beginBackgroundTask` и раз в 1 с (до 25 с) зовёт `__fon.backgroundTick(first)` — вызов `evaluateJavaScript` будит WebKit, страница жмёт `play()`; стоп при 'playing' 2 тика подряд или 'idle' (пауза пользователя). Отключение наушников (`routeChange .oldDeviceUnavailable`) → `markUserPaused`, чтобы не включить звук в динамик.
- **Звук при открытии:** плеер открывается не нажатием на его странице, поэтому YouTube считает это автозапуском и включает видео muted. В `player` на `playing`/`volumechange`/тик раз в секунду вызываем `movie_player.unMute()` + `video.muted=false` (WebKit позволяет — `mediaTypesRequiringUserActionForPlayback = []`). Если muted случился в пределах 1,5 с после касания страницы — это пользователь (`__fonUserMuted`), не трогаем. Не больше 5 включений за 10 с.
- **Экран блокировки:** Now Playing ведёт сам WebKit через `navigator.mediaSession`. `setActionHandler` перехвачен: наши play/pause/nexttrack/previoustrack/seekto, `seekforward/seekbackward = null`, YouTube их не перезапишет. Нативного `MPRemoteCommandCenter` нет — он конфликтовал с WebKit.
- **Лента → плеер:** клик по `a[href]` с путём `/watch` в ленте перехватывается и уходит в плеер (`{type:'open'}`); запасной путь — KVO на `url` ленты. В плеере ссылки не на `/watch` уходят в ленту (`{type:'browse'}`).
- **Мини-режим:** класс `fon-mini` на `<html>` растягивает `#player-container-id/.player-container/#player` и `video` на весь viewport; webview в мини-полоске 16:9.
- **Режим музыки / экономия:** класс `fon-music` прячет `video` (opacity 0) и показывает обложку `i.ytimg.com/vi/<id>/hqdefault.jpg`; качество — минимальное через `movie_player.setPlaybackQualityRange/setPlaybackQuality`. В фоне качество тоже падает до минимума (кроме PiP). YouTube запоминает качество в `localStorage['yt-player-quality']` — из-за этого 144p «прилипало»; теперь в режиме видео ключ стирается в начале документа, а после понижения качество явно ставится в hd720 (iPhone) / hd1080 (iPad). Чистый «только звук» в веб-плеере невозможен (протокол YouTube), это осознанный компромисс.
- **Режим музыки — контент:** видео открывается с Mix-плейлистом `&list=RD<id>` (похожая музыка, как радио в YT Music); под плеером скрыты комментарии и Shorts.
- **Свой полный экран:** m.youtube на iPhone включает системный AVKit-фулскрин (без субтитров YouTube и меню качества). В `player` подменены `webkitEnterFullscreen/requestFullscreen/exitFullscreen` и геттеры `fullscreenElement/fullscreenEnabled/webkitDisplayingFullscreen`: класс `fon-full` растягивает плеер на окно, шлются `webkitbeginfullscreen/fullscreenchange`, приложение получает `{type:'fullscreen'}` — прячет шапку и статус-бар, на iPhone поворачивает в landscape (`requestGeometryUpdate`). В полном экране качество не понижается и видео видно даже в режиме музыки.
- **Главная в режиме музыки:** грузится `/#fon-music`; скрипт `browse` убирает хэш и нажимает чип «Music/Музыка» (`ytm-chip-cloud-chip-renderer`) — обычные рекомендации, но только музыка.
- Скрываем родную нижнюю панель m.youtube (`ytm-pivot-bar-renderer`).
- **Shorts скрыты везде** (`common`): CSS по `ytm-reel-shelf-renderer`/`ytm-shorts-lockup-view-model*`/карточкам со ссылкой `/shorts/` (правила с `:has()` — отдельным блоком) + раз в 1,5 с прячем секции с заголовком «Shorts» и чип «Shorts».
- **Свой плейлист закончился** — YouTube включает похожее; `PlayerView.queueIDs` замечает id не из очереди и меняет «Играет из» на «Похожие треки».

## Проверено владельцем на iPhone (версия «режим музыки»)
- Фон работает (короткая ~1 с пауза при сворачивании), экран блокировки, next/prev, мини-плеер, обложка — ок.
- Было: 144p залипало после выключения ♪ — исправлено (см. выше), ждёт проверки.
- Известное ограничение: если долго стоять на паузе в фоне, ▶ в пункте управления иногда не срабатывает — iOS усыпляет процесс WebKit; нужно открыть приложение. Нативный `MPRemoteCommandCenter` раньше конфликтовал с WebKit.

## Проверено владельцем (версия «вкладки, Mix, PiP, iPad»)
- Mix-плейлист (`list=RD`) в плеере работает, лента не перезагружается.
- Жалобы, исправленные в следующей версии: в полном экране не было субтитров и настроек (системный AVKit-плеер); на iPad окно не разворачивалось на весь экран; свайп сворачивания был только по шапке; музыкальный канал на главной не понравился — хочет обычные рекомендации, но музыку.

## Что ещё НЕ проверено на устройстве
- Старт воспроизведения в фоне, если свернуть приложение, пока видео грузится (жалоба владельца: видео «пропадало»).
- Нативный музыкальный плеер, медиатека, `watch_videos` для своих плейлистов, чип «Музыка» на главной.
- Свой полный экран (субтитры, меню качества, поворот), свайп вниз по видео, окно iPad на весь экран со сценами.
- Скрытие комментариев в режиме музыки.
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
