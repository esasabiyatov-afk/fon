# Fon

**Русский** · [English](#english)

Неофициальный открытый музыкальный плеер для YouTube на iPhone и iPad. Музыка играет в фоне и на экране блокировки,
есть режим музыки с обложкой вместо видео, своя медиатека, рекомендации, музыка без интернета и настраиваемый
«живой» фон плеера. Собирается бесплатно в облаке GitHub — Mac не нужен.

> Проект **не связан с Google и YouTube** и не одобрен ими. YouTube и YouTube Music — товарные знаки Google LLC.
> Приложение — личный проект с открытым кодом, используйте его на свой риск и в рамках правил сервисов, которыми пользуетесь.

## Возможности

- Музыка играет при свёрнутом приложении и заблокированном экране, управление с экрана блокировки и наушников.
- Режим музыки: обложка вместо видео, нативный плеер в стиле Apple Music, «Далее», другие версии трека (slowed / lyrics / sped up).
- Системный плеер (AVPlayer): стабильно в фоне, своя громкость, мгновенная смена треков.
- Медиатека: «Понравившиеся» в вашем аккаунте YouTube, история, скачанные треки для прослушивания без интернета.
- «Открытия»: новое, ниша и тренды в вашем вкусе.
- Режим видео: свои ленты «Главная» и «Подписки», предпоказ видео в ленте, мини-плеер как в приложении YouTube.
- **Оформление плеера:** фон Мягкий / Неон / Чёрный, подложка матовая / глянец / без, ореол обложки.
- iPad: боковая панель и жесты по обложке.

## Установка (SideStore)

1. Поставьте [SideStore](https://sidestore.io) по их инструкции (нужен бесплатный Apple ID).
2. В SideStore: **Sources → «+»** и вставьте:
   ```
   https://github.com/esasabiyatov-afk/fon/releases/latest/download/apps.json
   ```
3. Установите Fon, обновления приходят кнопкой **Update**. Подпись бесплатного Apple ID живёт 7 дней — SideStore продлевает её сам.

Либо скачайте `Fon.ipa` из [Releases](../../releases) и поставьте любым способом (AltStore, Sideloadly и т. п.).

## Сделать свою версию (форк)

Лицензия MIT: берите код, меняйте, выпускайте свою версию — это приветствуется.

1. Нажмите **Fork** на GitHub.
2. В своём форке откройте **Actions** и разрешите запуск workflow.
3. Любой push в `main` собирает `Fon.ipa` и публикует **Release** с `apps.json` — у вашего форка получится **свой источник SideStore**:
   `https://github.com/<вы>/<репозиторий>/releases/latest/download/apps.json`
4. Поменяйте название и bundle id (чтобы ваша версия не конфликтовала с оригиналом):
   `PRODUCT_BUNDLE_IDENTIFIER` и `bundleIdPrefix` в `project.yml`, поля в `.github/workflows/build.yml` (`apps.json`), иконку в `Fon/Assets.xcassets`.
5. Репозиторий должен быть публичным, чтобы SideStore мог скачать `apps.json` и `.ipa`.

Mac и Xcode локально не нужны: проект описан в `project.yml`, а проект Xcode генерирует XcodeGen в облаке.

## Как это устроено

Swift, UIKit, WKWebView для страниц YouTube, AVPlayer для системного плеера, XcodeGen + GitHub Actions для сборки.
Подробная карта кода и накопленные решения — в [`CLAUDE.md`](CLAUDE.md) (написан как контекст для ИИ-ассистента, но читается и людьми).
Как участвовать — в [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Лицензия

[MIT](LICENSE). Решатель подписей в `Fon/Solver/` — из проекта [yt-dlp/ejs](https://github.com/yt-dlp/ejs) (Unlicense / ISC / MIT).

---

## English

An unofficial open-source music player for YouTube on iPhone and iPad: background and lock-screen playback, music mode,
your library, recommendations, offline tracks and a customizable live player background. It builds for free on GitHub's
cloud — no Mac needed.

> Not affiliated with or endorsed by Google or YouTube. YouTube and YouTube Music are trademarks of Google LLC.
> Personal open-source project — use at your own risk and respect the terms of the services you use.

**Install:** install [SideStore](https://sidestore.io), then add the source
`https://github.com/esasabiyatov-afk/fon/releases/latest/download/apps.json` (Sources → «+»), or grab `Fon.ipa` from
[Releases](../../releases).

**Make your own version:** the project is MIT-licensed. Fork the repo, enable Actions, change the name and bundle id
in `project.yml` and `.github/workflows/build.yml`, push to `main` — your fork publishes its own SideStore source at
`https://github.com/<you>/<repo>/releases/latest/download/apps.json` (the repo must be public).

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to contribute.
