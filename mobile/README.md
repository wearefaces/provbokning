# Provbokning — Flutter mobile client

iOS + Android-klient för Provbokningsbevakning. Återanvänder backend-API:t på `https://provbok.8-229-124-88.nip.io`.

## Funktioner
- BankID-inloggning via QR-kod (samma flow som webben).
- Sök lediga körkortsprovstider (manuellt eller auto var 30:e sek).
- Boka direkt — öppnar Trafikverket i extern webbläsare och verifierar i bakgrunden att tiden fortfarande finns.
- Stripe-paywall: demoläge gratis, "Aktivera live" via Stripe Checkout i extern webbläsare.

## Förutsättningar
1. Installera Flutter SDK (3.19+): https://docs.flutter.dev/get-started/install
2. För iOS: macOS + Xcode 15+. För Android: Android Studio + Android SDK.

## Setup (en gång)
Från `mobile/`:

```bash
# Generera plattformsspecifika filer (ios/, android/) – läser vår pubspec/lib.
flutter create --platforms=ios,android --org se.provbok --project-name provbok .

# Hämta paket
flutter pub get
```

`flutter create` skriver ALDRIG över befintliga filer i `lib/` eller `pubspec.yaml` — den fyller bara på saknade plattformskataloger.

## Köra appen
```bash
# Lista enheter
flutter devices

# iOS-simulator
open -a Simulator
flutter run -d "iPhone 15"

# Android-emulator
flutter emulators --launch <id>
flutter run -d emulator-5554
```

## Anpassad backend (staging / lokal)
```bash
flutter run --dart-define=API_BASE_URL=http://192.168.1.42:5000
```

## Bygga release
```bash
# Android
flutter build apk --release
flutter build appbundle --release

# iOS (kräver Apple Developer-konto)
flutter build ipa --release
```

## Arkitektur (kort)
- `lib/config.dart` — bas-URL.
- `lib/models.dart` — DTO:er: `Slot`, `BillingStatus`, `ScanResult`.
- `lib/api.dart` — Dio-klient med `CookieManager` så Flask-sessionen följer med mellan anrop.
- `lib/screens/login_screen.dart` — BankID QR + polling av `/api/auth/status`.
- `lib/screens/home_screen.dart` — sök, lista, boka, paywall-bottomsheet.
- `lib/main.dart` — bootstrap som väljer login/home utifrån `/api/auth/check`.

## Begränsningar / nästa steg
- Cookie-jar är minnesbaserad. Sessionen försvinner om appen dödas. Lägg till `PersistCookieJar` med `path_provider` för persistens.
- Push-notiser saknas — lägg till FCM/APNs och en push-endpoint på servern (`/api/push/register`).
- Inställningar (orter, datum, körkortstyp) skickas inte ännu från mobilen — använd `/save_config` med en form-screen.
- Stripe-betalflödet öppnas i extern webbläsare. När användaren stänger Stripe-fliken vet appen inte direkt att betalningen lyckades; den uppdaterar status nästa gång `/api/billing/status` pollas. Lös med deep link → custom URL scheme `provbok://billing-success` om du vill ha omedelbar uppdatering.
