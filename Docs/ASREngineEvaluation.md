# Daisy: нужен ли FluidAudio и можно ли остаться только на Whisper

**Дата исследования:** 23 июля 2026
**Тип:** desk benchmark + решение + протокол честного A/B-теста Daisy

## Короткий вывод

1. **Не заменять Daisy на Wispr Flow.** Wispr Flow — не библиотека и не локальная модель, а облачный SaaS: по его документации транскрипция всегда выполняется в облаке. Даже в режиме zero-retention аудио отправляется на обработку и затем удаляется. Это противоречит on-device обещанию Daisy и добавляет платную внешнюю зависимость.
2. **Whisper оставить основным движком встреч.** У него широкое покрытие (100+ языков), лучшее основание для русского/смешанных языков и уже работающая интеграция.
3. **FluidAudio не нужен для Whisper.** Это отдельный SDK для Parakeet и diarization, а не ускоритель WhisperKit.
4. **FluidAudio оправдан только двумя продуктовым функциями:** быстрый локальный диктант на Parakeet и локальная diarization. Если Daisy отказывается от одной из них, соответствующую часть зависимости и модели следует убрать. Если speaker labels остаются фичей Daisy, одним Whisper обойтись нельзя: Whisper сам diarization не делает.
5. **Рекомендация:** не расширять FluidAudio сейчас. Оставить его как *опциональный* движок диктанта и diarization, но не как default для встреч. Перед следующим релизом провести описанный ниже A/B на реальных аудиозаписях Daisy. Если Parakeet не даёт заметного выигрыша в latency без потери русского качества, убрать его из публичных настроек и тем самым убрать вторую модель/лицензионный трек.

## 1. Что такое «Wispr Flow» в этом сравнении

Под «Висперфлоу» здесь понимается **Wispr Flow**, а не Whisper/WhisperKit.

Wispr Flow не раскрывает используемую ASR-модель как заменяемый локальный движок. Его собственная privacy-документация прямо говорит, что транскрипция всегда происходит в облаке; Privacy Mode влияет на хранение и обучение, а не на место распознавания. Поэтому его нельзя взять в Daisy как бесплатную on-device замену WhisperKit или FluidAudio.

Источник: [Wispr Flow privacy](https://wisprflow.ai/privacy).

Если под «Висперфлоу» имелся в виду просто **Whisper/WhisperKit**, то ответ выше остаётся тем же: Whisper достаточно для транскрипции, но не заменяет diarization и проигрывает Parakeet в скорости диктанта.

## 2. Как устроены сравниваемые продукты

| Продукт | Где ASR | Что известно о движках | Что это значит для Daisy |
| --- | --- | --- | --- |
| Wispr Flow | Облако | Модель не раскрыта; транскрипция always-cloud. | Не аналог локального движка и не кандидат для интеграции. |
| Granola | Облако | Использует поставщиков, включая Deepgram и Assembly; LLM-провайдеров OpenAI/Anthropic. | Конкурирует UX-ом meeting notes, не технологией локального ASR. |
| MacWhisper | Локально по умолчанию | Поддерживает WhisperKit, Parakeet и системные Apple speech models; cloud — отдельный выбор. | Прямое подтверждение, что multi-engine — нормальная продуктовая стратегия на Mac. |
| Superwhisper | Локально или облачно по выбору | Локальные Whisper и Parakeet V2/V3; облачные модели опциональны. | Тот же паттерн: Parakeet для скорости, Whisper для охвата языков. |
| Aiko | Только локально | Whisper large-v2 через whisper.cpp; нет live transcription и speaker detection. | Whisper-only хорош для простого batch-продукта, но не покрывает текущие фичи Daisy. |
| Whisper Notes | Локально | Сделал Parakeet V3 default, Whisper оставил fallback для языков вне 25. | Полезный рыночный сигнал, но не независимое доказательство качества. |

Источники: [Granola security](https://www.granola.ai/security), [MacWhisper models](https://docs.macwhisper.com/article/57-macwhisper-command-line-tool), [MacWhisper privacy](https://docs.macwhisper.com/article/52-keeping-transcriptions-private), [Superwhisper models](https://superwhisper.com/models), [Aiko App Store listing](https://apps.apple.com/in/app/aiko/id1672085276?platform=mac), [Whisper Notes comparison](https://whispernotes.app/blog/parakeet-v3-default-mac-model).

## 3. Desk benchmark: Whisper vs Parakeet

### Что можно сравнивать честно

Показатели ниже — опубликованные результаты **исходных моделей**, а не прогон Daisy. Они показывают направление выбора, но не заменяют теста наших CoreML-конверсий, VAD, сегментации и UX на Mac.

| Сценарий | Parakeet TDT 0.6B v3 | Whisper large-v3 / turbo | Вывод |
| --- | --- | --- | --- |
| Английская short-form оценка Open ASR Leaderboard | 6.32% средний WER, 3,333x RTFx | large-v3: 7.44% и 146x; turbo: 7.83% и 350x | Parakeet сильнее по английскому speed/accuracy benchmark. RTFx измерен не на Mac и не переносится напрямую. |
| Русский FLEURS | 5.51% WER у Parakeet по карточке NVIDIA | Сторонняя сводка совместимого теста даёт 4.42% для Whisper large-v3-turbo | Для русского нельзя заранее объявить Parakeet победителем; Whisper вероятно точнее на части материала. Нужен Daisy A/B. |
| Охват языков | 25 европейских языков, включая русский и украинский | 100+ языков | Whisper обязателен как fallback для глобального продукта. |
| Локальная CoreML скорость Parakeet | FluidAudio сообщает ~195–225x RTFx на FLEURS на M4 Pro в зависимости от языка | Сопоставимого публичного Daisy/WhisperKit замера на том же pipeline нет | Скорость Parakeet — убедительная гипотеза для диктанта, но не доказательство итоговой выгоды Daisy. |
| Диаризация | Через FluidAudio / pyannote CoreML | В Whisper отсутствует | Это отдельный функциональный, не WER-аргумент за FluidAudio. |

Open ASR Leaderboard запускает единые воспроизводимые оценки в Docker на одинаковом железе; это надёжнее маркетинговых сравнений, но его RTFx не является скоростью на Apple Silicon. [Методология leaderboard](https://github.com/huggingface/open_asr_leaderboard), [карточка Parakeet с результатами](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).

### Что это означает practically

- Для **диктанта на английском и части европейских языков** Parakeet очень вероятно даёт ощущаемо более быстрый финальный текст. Это единственная сильная причина держать FluidAudio ASR.
- Для **русских встреч, терминов, смешанной речи и языков за пределами 25** нельзя обещать преимущество Parakeet. Whisper остаётся безопасным default.
- Для **встреч** разница между «в 5–20 раз быстрее реального времени» не так важна, как WER, timestamps, работа с шумом и спикерами: пользователь ждёт результат после окончания встречи, а не мгновенное появление текста после фразы.
- Для **короткого диктанта** latency — ключевая метрика. Здесь A/B может оправдать дополнительную зависимость даже при небольшом WER-компромиссе.

## 4. Apple SpeechAnalyzer — третья, бесплатная опция

На macOS 26 Apple предоставляет `SpeechAnalyzer`/`SpeechTranscriber`: on-device модель, streaming, long-form и meeting scenarios, с системным управлением assets. Daisy уже использует этот путь как третий движок.

Его стоит сохранять как optional/native путь для поддерживаемых macOS и локалей, но не делать единственной заменой Whisper:

- Daisy не контролирует версию и качество модели: Apple автоматически обновляет assets;
- availability и языки зависят от ОС/устройства;
- это не решает diarization;
- воспроизводимость и version pin хуже, чем у собственной модели.

Источник: [WWDC: SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/).

## 5. Рекомендованная архитектура

```text
Встречи (default): WhisperKit / Whisper large-v3
  ├─ 100+ языков, стабильный model pin
  ├─ VAD + offline processing
  └─ при включённом speaker labels: FluidAudio diarization только для diarization

Диктант (опционально): Parakeet v3 через FluidAudio
  ├─ только 25 поддерживаемых языков
  ├─ быстрый final result
  └─ Whisper fallback для остальных языков и при неудаче загрузки

macOS 26 (опционально): Apple SpeechAnalyzer
  └─ системная локальная модель, без нашего model hosting
```

Это не означает, что пользователь должен видеть три технических названия. UX может оставить понятные варианты: **«Стандартный»**, **«Быстрый диктант»**, **«Системный (macOS 26)»**.

## 6. Критерий, когда FluidAudio можно убрать

Убрать FluidAudio полностью имеет смысл только при обоих условиях:

1. Daisy убирает speaker diarization либо заменяет её другой локальной библиотекой с тем же качеством и лицензией.
2. В Daisy A/B Parakeet не выигрывает у Whisper по p95 времени до final text как минимум в 2 раза **или** ухудшает WER на русском/английском более чем на 1.5 процентных пункта.

Если сохраняется diarization, FluidAudio (или эквивалентная отдельная зависимость) остаётся обоснованным, даже если Parakeet выключить.

## 7. Реальный A/B benchmark Daisy перед решением

### Набор

Собрать 100 коротких/средних фрагментов с вручную выверенным текстом и согласием на тестирование:

- 30 русских: 10 чистый диктант, 10 бытовая речь/имена, 10 запись встречи с шумом;
- 30 английских в тех же трёх условиях;
- 20 mixed RU/EN и продуктовые термины;
- 10 тишина/музыка/переходы — проверка hallucinations;
- 10 двухспикерных фрагментов с разметкой спикеров — отдельный тест diarization.

Не публиковать сами записи без явного согласия. Для открытого воспроизводимого слоя можно добавить отдельно лицензированные публичные FLEURS/AMI фрагменты.

### Условия

- Один и тот же ресемплинг, VAD и нормализация текста для всех ASR.
- Сравнить: текущий WhisperKit default, выбранный Whisper high-accuracy, Parakeet v3 через FluidAudio и Apple SpeechAnalyzer там, где доступен.
- Прогнать на минимально поддерживаемом M-series Mac и на актуальном M-series Mac; три прогрева и затем три измерения каждого фрагмента.
- Не смешивать ASR WER и качество diarization: speaker labels считать отдельно.

### Метрики

| Метрика | Почему важна |
| --- | --- |
| WER/CER, с одинаковой нормализацией | Основная точность распознавания. |
| Proper-noun / product-term recall | Для Daisy это часто заметнее среднего WER. |
| Time to first text и p50/p95 time to final text | Отличает быстрый диктант от batch-встреч. |
| RTFx, peak RAM, средний CPU/energy impact | Проверяет реальный выигрыш на Mac, а не на H200. |
| Hallucinated tokens per 10 min silence | Важная failure mode Whisper. |
| DER/JER и число ложных спикеров | Отдельный ответ на вопрос, нужен ли FluidAudio для diarization. |

### Decision rule

- **Whisper остаётся default meetings**, если он выигрывает или не хуже по WER на русском/mixed/long-form.
- **Parakeet остаётся только для dictation**, если даёт >=2x p95 faster final text и WER не хуже Whisper более чем на 1.5 п.п. для RU и EN.
- **Apple SpeechAnalyzer** остаётся native option, если доступен и его WER/latency укладываются в те же пороги.
- **Diarization** остаётся, только если помеченные спикеры улучшают продуктовую ценность и DER приемлем; иначе вырезать весь diarization-trек и переоценить необходимость FluidAudio.

## 8. Непосредственные действия

1. Не начинать перенос Parakeet/diarization на GitHub Releases, пока не пройден license gate из [`ModelHostingDeveloperPlan.md`](./ModelHostingDeveloperPlan.md).
2. Сначала провести A/B из раздела 7 в текущей ветке приложения.
3. На основании результатов выбрать один из двух честных product modes:
   - **Lean Daisy:** WhisperKit + Apple SpeechAnalyzer; без Parakeet и без speaker labels.
   - **Full local Daisy (рекомендовано при сохранении текущих фич):** WhisperKit для встреч + FluidAudio только для Parakeet dictation и diarization.
4. Не использовать Wispr Flow или Granola как технических провайдеров: это изменит продукт с локального на облачный и создаст расходы.
