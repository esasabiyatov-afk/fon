# Fon

**English** · [Русский](#русский)

I'm not a programmer, just a regular user who wanted a music player of my own. So I built one with AI ([Claude](https://claude.ai/code)),
for myself. Now it's open source: take it, change it, make your own version.

An unofficial player for YouTube on iPhone and iPad:

- music keeps playing in the background and on the lock screen;
- **music mode**: native player with cover art, queue, offline tracks, recommendations;
- **video mode**: your YouTube feed and subscriptions, mini-player, previews in the feed;
- live **animated background** (Soft / Neon / Black) and a player customizer;
- English and Russian interface.

I didn't remove YouTube ads — there are none in my country, so I never needed to :)

**Install:** get [SideStore](https://sidestore.io), add the source
`https://github.com/esasabiyatov-afk/fon/releases/latest/download/apps.json`, install Fon. Or download `Fon.ipa` from [Releases](../../releases).

**Make your own version:** fork the repo, enable Actions, change the name and bundle id in `project.yml` and
`.github/workflows/build.yml`, push to `main`. Your fork builds `Fon.ipa` and publishes its own SideStore source.
No Mac needed. The repo has to be public.

Not affiliated with Google or YouTube. Use at your own risk. MIT license. Questions and ideas: Issues / Discussions.
How to help: [CONTRIBUTING.md](CONTRIBUTING.md). The code map is in [CLAUDE.md](CLAUDE.md).

---

## Русский

Я не программист, а обычный пользователь, которому захотелось своё приложение для музыки. Сделал его с помощью ИИ
([Claude](https://claude.ai/code)) для себя. Теперь код открыт: берите, меняйте, делайте свои версии.

Неофициальный плеер для YouTube на iPhone и iPad:

- музыка играет в фоне и на экране блокировки;
- **режим музыки**: свой плеер с обложкой, очередь, треки без интернета, рекомендации;
- **режим видео**: лента и подписки YouTube, мини-плеер, предпоказ видео в ленте;
- живой **анимированный фон** (Мягкий / Неон / Чёрный) и настройщик плеера;
- интерфейс на русском и английском.

Рекламу YouTube я не убирал — в моей стране её просто нет :)

**Установка:** поставьте [SideStore](https://sidestore.io), добавьте источник
`https://github.com/esasabiyatov-afk/fon/releases/latest/download/apps.json` и установите Fon. Либо скачайте `Fon.ipa` из [Releases](../../releases).

**Своя версия:** сделайте Fork, включите Actions, поменяйте название и bundle id в `project.yml` и
`.github/workflows/build.yml`, сделайте push в `main`. Форк сам соберёт `Fon.ipa` и выложит свой источник для SideStore.
Mac не нужен. Репозиторий должен быть публичным.

Не связано с Google и YouTube. Используйте на свой риск. Лицензия MIT. Вопросы и идеи: Issues / Discussions.
Как помочь: [CONTRIBUTING.md](CONTRIBUTING.md). Карта кода: [CLAUDE.md](CLAUDE.md).
