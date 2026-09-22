# Обмер — этап 1 (сканер)

Приложение для дизайнеров интерьеров: сканирование помещения лидаром iPhone
и получение размеров стен и проёмов.

Этот этап делает: скан → список размеров в миллиметрах → экспорт USDZ и JSON.
Ещё НЕ делает: уточнение по дальномеру, IFC для ArchiCAD, визуализацию, каталог.

## Требования

- iPhone Pro (12 Pro и новее) или iPad Pro с 2020 г. — нужен LiDAR
- Xcode (полный, из Mac App Store) — Command Line Tools недостаточно
- iOS 17.0+ на устройстве
- Симулятор не подходит: у него нет LiDAR, сканирование не запустится

## Как собрать

### Вариант А — через Xcode вручную (проще, ничего ставить не надо)

1. Xcode → File → New → Project → iOS → App
2. Product Name: `Obmer`, Interface: SwiftUI, Language: Swift
3. Сохранить куда угодно, потом удалить из проекта созданные Xcode
   `ContentView.swift` и `ObmerApp.swift` (Move to Trash)
4. Перетащить в проект все файлы из папки `Obmer/` этого репозитория,
   отметив «Copy items if needed»
5. Target → Info → добавить `Privacy - Camera Usage Description`
   с текстом из нашего `Info.plist`
6. Target → General → Minimum Deployments → iOS 17.0
7. Target → Signing & Capabilities → выбрать свою команду (Team)
8. Подключить iPhone кабелем, выбрать его вверху вместо симулятора, ⌘R

### Вариант Б — через XcodeGen (быстрее при повторных сборках)

    brew install xcodegen
    cd /Users/madina/Projects/Obmer
    xcodegen generate
    open Obmer.xcodeproj

Дальше — Signing & Capabilities и запуск на устройстве.

## Что где лежит

| Файл | Зачем |
|---|---|
| `ObmerApp.swift` | точка входа |
| `ContentView.swift` | стартовый экран, проверка поддержки LiDAR |
| `ScanScreen.swift` | полноэкранное сканирование с кнопками |
| `RoomScannerView.swift` | мост к `RoomCaptureView` от Apple |
| `ScanController.swift` | состояние сеанса: запуск, остановка, ошибки |
| `RoomSummary.swift` | разбор `CapturedRoom` в размеры в мм |
| `ResultsView.swift` | таблица результатов и экспорт |
| `Exporter.swift` | сохранение USDZ (`.parametric`) и JSON |
| `PrivacyInfo.xcprivacy` | манифест приватности, обязателен для App Store |

## Решения, которые надо принять до публикации

- Настоящее имя приложения и bundle identifier (сейчас заглушка `app.obmer.scanner`)
- Apple Developer Program: физлицо или компания — влияет на имя продавца в App Store
- Модель монетизации: подписка, разовая покупка или оплата за помещение
- Политика конфиденциальности — обязательна, даже если данные не покидают телефон
