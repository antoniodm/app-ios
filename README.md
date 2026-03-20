# Guardroom24 - App iOS

App nativa iOS basata su **Capacitor 8** che wrappa la webapp `https://davinci.perfortuna.it`. Invia e riceve notifiche push tramite **APNs** (Apple Push Notification service) usando token APNs raw (64 caratteri hex) senza Firebase SDK installato nell'app.

---

## Indice

1. [Panoramica](#1-panoramica)
2. [Prerequisiti e strumenti necessari](#2-prerequisiti-e-strumenti-necessari)
3. [Struttura del progetto](#3-struttura-del-progetto)
4. [Setup iniziale (da zero)](#4-setup-iniziale-da-zero)
5. [Gestione certificati e chiavi (step by step)](#5-gestione-certificati-e-chiavi-step-by-step)
6. [Come buildare](#6-come-buildare)
7. [Come installare sul dispositivo](#7-come-installare-sul-dispositivo)
8. [Flusso notifiche push](#8-flusso-notifiche-push)
9. [Troubleshooting](#9-troubleshooting)
10. [Note importanti e limitazioni](#10-note-importanti-e-limitazioni)

---

## Quick Start — Da clone a IPA installata

Sequenza completa di comandi per partire da zero e avere l'app installata su iPhone.

### 1. Clona il repository

```bash
git clone <url-repo> mobile-app-guardroom
cd mobile-app-guardroom/app-ios
```

### 2. Installa le dipendenze Node

```bash
npm install
```

### 3. Verifica i file segreti nel repo

I seguenti file sono già committati nel repo (privato aziendale):

- `secret/AuthKey_V36CCN4Z9R.p8` — chiave privata APNs
- `secret/ios_distribution.p12` — certificato distribuzione
- `secret/adhoc.mobileprovision` — provisioning profile Ad Hoc
- `ios/App/App/GoogleService-Info.plist` — placeholder (Firebase SDK non usato in iOS)

### 4. Sincronizza Capacitor con il progetto iOS

```bash
npx cap sync ios
```

### 5. Build con Codemagic (richiede macOS — usa Codemagic da Linux)

```bash
# Carica su Codemagic (una tantum, via UI web):
#   - secret/ios_distribution.p12  → Code signing > Certificates
#   - secret/adhoc.mobileprovision → Code signing > Provisioning profiles
#
# Poi esegui la build tramite Codemagic CLI o push sul branch configurato:
git add .
git commit -m "trigger build"
git push

# Oppure lancia manualmente via Codemagic CLI:
# pip install codemagic-cli-tools
# cm builds start --app-id <APP_ID> --workflow-id ios-release --branch main
```

Scarica l'artefatto IPA dalla dashboard Codemagic al termine della build.

### 6. Installa l'IPA su iPhone via USB (da Linux)

```bash
# Installa ideviceinstaller se non presente
sudo apt install ideviceinstaller

# Collega iPhone via USB e fidati del computer sul dispositivo
# Verifica che sia riconosciuto
idevice_id -l

# Installa l'IPA
ideviceinstaller -i Guardroom24.ipa
```

L'app appare sulla home screen del dispositivo.

---

## 1. Panoramica

| Parametro | Valore |
|---|---|
| App Name | Guardroom24 |
| Bundle ID | `com.octopusiot.example` |
| Team ID Apple | `YVKBSQ6Y56` |
| Capacitor | 8.x |
| Push | APNs diretto (token raw 64 hex) |
| APNs Key ID | `V36CCN4Z9R` |
| Firebase Project | `securhoprova` (solo per Android/web) |
| CI/CD | Codemagic (workflow `ios-release`) |
| Distribution | Ad Hoc |
| Webapp | `https://davinci.perfortuna.it` |

L'app non contiene Firebase SDK iOS. Le notifiche push vengono inviate direttamente tramite APNs HTTP/2, autenticate con JWT firmato dalla chiave privata `.p8`. Il token APNs (64 char hex) viene salvato sul database del server tramite l'endpoint `/json_savefcmtoken`.

---

## 2. Prerequisiti e strumenti necessari

### Obbligatori

- **Account Apple Developer** attivo (Team ID `YVKBSQ6Y56`) - necessario per certificati e provisioning profile
- **Codemagic** - unico modo per buildare su macOS senza Mac fisico
- **Node.js** >= 18 - per eseguire `npm install` e `npx cap sync`
- **OpenSSL** - disponibile su Linux/macOS, per generare chiavi e certificati

### Per installare su iPhone via USB da Linux

```bash
sudo apt install ideviceinstaller libimobiledevice-utils
```

### Non obbligatori ma utili

- **Xcode** su macOS - per ispezionare il progetto; non necessario se si usa solo Codemagic
- **idevice_id** - per trovare l'UDID del dispositivo collegato via USB

### Versioni dipendenze npm

```json
"@capacitor/cli": "^8.2.0"
"@capacitor/core": "^8.2.0"
"@capacitor/ios": "^8.2.0"
"@capacitor/push-notifications": "^8.0.2"
```

---

## 3. Struttura del progetto

```
app-ios/
├── capacitor.config.json          # Configurazione Capacitor (Bundle ID, server URL, plugin)
├── package.json                   # Dipendenze npm
├── package-lock.json
├── codemagic.yaml                 # Workflow CI/CD Codemagic
├── .gitignore                     # Esclude node_modules/, secret/, artifact/
│
├── ios/                           # Progetto Xcode generato da Capacitor CLI
│   └── App/
│       ├── App.xcodeproj/         # Progetto Xcode (non modificare manualmente)
│       ├── App/
│       │   ├── AppDelegate.swift  # Entry point iOS - gestisce callback token APNs
│       │   ├── App.entitlements   # Entitlement push: aps-environment = production
│       │   ├── Info.plist         # Configurazione app iOS
│       │   ├── capacitor.config.json  # Copia locale della config Capacitor
│       │   └── GoogleService-Info.plist  # NON in git - scaricare da Firebase Console
│       └── CapApp-SPM/
│           └── Package.swift      # Gestito da Capacitor CLI - NON modificare
│
├── web-placeholder/               # Directory web vuota richiesta da Capacitor
│                                  # La webapp reale e' servita da server remoto
├── artifact/                      # Output build locale (non in git)
│
└── secret/                        # NON in git - certificati e chiavi private
    ├── ios_distribution.key       # Chiave privata RSA per certificato distribuzione
    ├── ios_distribution.csr       # CSR (Certificate Signing Request)
    ├── ios_distribution.cer       # Certificato distribuzione (scaricato da Apple Developer)
    ├── ios_distribution.pem       # Certificato in formato PEM
    ├── ios_distribution.p12       # Certificato + chiave PKCS12 (password: codemagic)
    ├── aps.cer                    # Certificato APNs (scaricato da Apple Developer)
    ├── aps.pem                    # Certificato APNs in formato PEM
    ├── AuthKey_V36CCN4Z9R.p8     # Chiave APNs p8 (Key ID: V36CCN4Z9R) - non scade
    ├── adhoc.mobileprovision      # Provisioning profile Ad Hoc
    └── octopus.mobileprovision    # Provisioning profile App Store (non usato)
```

### File chiave: `capacitor.config.json`

```json
{
  "appId": "com.octopusiot.example",
  "appName": "Guardroom24",
  "webDir": "web-placeholder",
  "server": {
    "url": "https://davinci.perfortuna.it",
    "cleartext": false
  },
  "plugins": {
    "PushNotifications": {
      "presentationOptions": ["badge", "sound", "alert"]
    }
  }
}
```

### File chiave: `ios/App/App/App.entitlements`

```xml
<dict>
    <key>aps-environment</key>
    <string>production</string>
</dict>
```

**Importante:** l'entitlement `production` e' obbligatorio anche per build Ad Hoc. Non usare `development` altrimenti le notifiche non arrivano.

### File chiave: `ios/App/App/AppDelegate.swift`

L'AppDelegate e' minimale (senza Firebase). Gestisce i callback APNs e li inoltra a Capacitor:

```swift
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    NotificationCenter.default.post(
        name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
}

func application(_ application: UIApplication,
                 didFailToRegisterForRemoteNotificationsWithError error: Error) {
    NotificationCenter.default.post(
        name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
}
```

Capacitor converte internamente il `deviceToken` (Data) nel token hex da 64 caratteri.

---

## 4. Setup iniziale (da zero)

Questi passi descrivono come ricreare l'intero progetto partendo da zero.

### 4.1 Inizializzare il progetto Capacitor

```bash
mkdir app-ios && cd app-ios
npm init -y
npm install @capacitor/core @capacitor/cli @capacitor/ios @capacitor/push-notifications
npx cap init Guardroom24 com.octopusiot.example --web-dir web-placeholder
mkdir web-placeholder
npx cap add ios
```

### 4.2 Configurare `capacitor.config.json`

Impostare `server.url` alla webapp remota e il plugin push come mostrato nella sezione 3.

### 4.3 Sincronizzare il progetto iOS

```bash
npx cap sync ios
```

Questo comando:
- Copia la configurazione in `ios/App/App/capacitor.config.json`
- Aggiorna `CapApp-SPM/Package.swift` con i plugin Capacitor (incluso `CapacitorPushNotifications`)

### 4.4 Configurare AppDelegate.swift

Aggiungere i due metodi callback APNs nell'AppDelegate come mostrato nella sezione 3.

### 4.5 Configurare l'entitlement push

Creare `ios/App/App/App.entitlements` con il contenuto mostrato nella sezione 3.

### 4.6 Abilitare Push Notifications in Xcode (se disponibile macOS)

In Xcode: Project > Signing & Capabilities > + Capability > Push Notifications.

Codemagic gestisce questo automaticamente tramite il provisioning profile se non si ha Xcode.

### 4.7 Configurare Codemagic

1. Caricare su Codemagic (Teams > Code signing identities):
   - Certificato `ios_distribution.p12` con password `codemagic`
   - Provisioning profile `adhoc.mobileprovision`
2. Collegare il repository git a Codemagic
3. Verificare che `codemagic.yaml` sia presente nella root del repository

---

## 5. Gestione certificati e chiavi (step by step)

Tutti i file generati vanno nella directory `secret/` (non tracciata da git).

### 5.1 Generare la chiave privata e CSR (su Linux)

```bash
mkdir -p secret && cd secret

# Chiave privata RSA 2048 bit
openssl genrsa -out ios_distribution.key 2048

# Certificate Signing Request
openssl req -new \
  -key ios_distribution.key \
  -out ios_distribution.csr \
  -subj "/CN=Guardroom24/O=OctopusIot/C=IT"
```

### 5.2 Creare il certificato di distribuzione su Apple Developer

1. Accedere a [developer.apple.com/account](https://developer.apple.com/account)
2. Certificates, Identifiers & Profiles > Certificates > (+)
3. Scegliere **Apple Distribution**
4. Caricare `ios_distribution.csr`
5. Scaricare e salvare come `secret/ios_distribution.cer`

### 5.3 Convertire il certificato in PEM e generare il P12

```bash
cd secret/

# Converti .cer (formato DER) in PEM
openssl x509 -inform DER \
  -in ios_distribution.cer \
  -out ios_distribution.pem

# Crea P12 (bundle certificato + chiave privata)
openssl pkcs12 -export \
  -in ios_distribution.pem \
  -inkey ios_distribution.key \
  -out ios_distribution.p12 \
  -passout pass:codemagic
```

La password `codemagic` deve corrispondere a quella configurata in Codemagic.

### 5.4 Certificato APNs (se serve rigenerarlo)

1. Apple Developer > Certificates > (+) > Apple Push Notification service SSL (Sandbox & Production)
2. Selezionare l'App ID `com.octopusiot.example`
3. Caricare la stessa CSR
4. Scaricare e salvare come `secret/aps.cer`

```bash
# Converti in PEM per verifica o uso diretto
openssl x509 -inform DER -in secret/aps.cer -out secret/aps.pem
```

**Nota:** La chiave APNs p8 (`AuthKey_V36CCN4Z9R.p8`) e' preferita al certificato APNs perche' non scade. Il server Java usa esclusivamente la `.p8`.

### 5.5 Chiave APNs p8

Il file `AuthKey_V36CCN4Z9R.p8` e' gia' presente in `secret/` ed e' condiviso con il server Java in:
- `gatewayproxy-batch/src/main/resources/AuthKey_V36CCN4Z9R.p8`
- `gatewayproxy-boot/src/main/resources/AuthKey_V36CCN4Z9R.p8`

Per rigenerarla (solo se persa - non e' riscaricabile da Apple una volta creata):
1. Apple Developer > Keys > (+) > Apple Push Notifications service (APNs)
2. Scaricare il file `.p8` (scaricabile **una sola volta**)
3. Aggiornare Key ID in `PushServiceImpl.java` se il Key ID cambia

### 5.6 Provisioning Profile Ad Hoc

1. Apple Developer > Profiles > (+) > Ad Hoc
2. Selezionare App ID `com.octopusiot.example`
3. Selezionare il certificato di distribuzione creato al passo 5.2
4. Selezionare i dispositivi registrati (per UDID)
5. Scaricare e salvare come `secret/adhoc.mobileprovision`

### 5.7 Registrare un nuovo dispositivo iPhone

Quando si vuole installare l'app su un nuovo iPhone non ancora registrato:

1. Trovare l'UDID del dispositivo:
   ```bash
   idevice_id -l
   # Oppure: ideviceinfo -u UDID | grep UniqueDeviceID
   ```
2. Apple Developer > Devices > (+) > inserire UDID e nome
3. Rigenerare il provisioning profile Ad Hoc includendo il nuovo device
4. Ricaricare il `.mobileprovision` aggiornato su Codemagic
5. Fare una nuova build

UDID iPhone noto: `00008030-0010399E149A402E`

### 5.8 Caricare certificati su Codemagic

Codemagic > Teams > Code signing identities:
- Caricare `ios_distribution.p12` con password `codemagic`
- Caricare `adhoc.mobileprovision`

Codemagic li referenzia nel blocco `ios_signing` del `codemagic.yaml` tramite `distribution_type: ad_hoc` e `bundle_identifier: com.octopusiot.example`.

---

## 6. Come buildare

La build iOS richiede macOS con Xcode. Su Linux si usa esclusivamente **Codemagic**.

### 6.1 Build tramite Codemagic (metodo standard)

```yaml
# codemagic.yaml
workflows:
  ios-release:
    name: Guardroom24 iOS
    max_build_duration: 60
    instance_type: mac_mini_m2

    environment:
      ios_signing:
        distribution_type: ad_hoc
        bundle_identifier: com.octopusiot.example
      vars:
        XCODE_PROJECT: "ios/App/App.xcodeproj"
        XCODE_SCHEME: "App"
      node: latest

    scripts:
      - name: Install npm dependencies
        script: npm install

      - name: Capacitor sync
        script: npx cap sync ios

      - name: Set up code signing
        script: xcode-project use-profiles

      - name: Build iOS IPA
        script: |
          xcode-project build-ipa \
            --project "$XCODE_PROJECT" \
            --scheme "$XCODE_SCHEME"

    artifacts:
      - build/ios/ipa/*.ipa
      - /tmp/xcodebuild_logs/*.log
```

**Avviare una build:**

1. Fare push del codice su git (il repository deve essere collegato a Codemagic)
2. Codemagic > app > Start new build > workflow: `ios-release`
3. Attendere (max 60 minuti su Mac Mini M2)
4. Scaricare l'artifact `.ipa` dalla pagina della build

### 6.2 Passi eseguiti da Codemagic

| Step | Comando | Descrizione |
|---|---|---|
| 1 | `npm install` | Installa dipendenze node |
| 2 | `npx cap sync ios` | Copia file web e aggiorna plugin Swift |
| 3 | `xcode-project use-profiles` | Applica provisioning profile Ad Hoc |
| 4 | `xcode-project build-ipa` | Compila con Xcode e produce IPA |

### 6.3 Artefatti prodotti

- `build/ios/ipa/*.ipa` - l'IPA installabile su dispositivi registrati nel profilo Ad Hoc
- `/tmp/xcodebuild_logs/*.log` - log completi di compilazione Xcode

---

## 7. Come installare sul dispositivo

### 7.1 Installare gli strumenti necessari

```bash
sudo apt install ideviceinstaller libimobiledevice-utils
```

### 7.2 Verificare il dispositivo collegato via USB

```bash
idevice_id -l
# Output atteso: 00008030-0010399E149A402E
```

### 7.3 Installare l'IPA

```bash
ideviceinstaller -i App.ipa
```

Attendere il messaggio `Install: Complete`.

### 7.4 Primo avvio

Aprire l'app manualmente sul dispositivo. Al primo avvio iOS potrebbe richiedere di autorizzare l'app dello sviluppatore:

Impostazioni > Generali > Gestione VPN e dispositivo > Trust certificato sviluppatore

### 7.5 Distribuzione OTA (alternativa senza USB)

E' possibile distribuire via link OTA:
1. Creare un manifest `.plist` che punta all'IPA su un server HTTPS
2. Distribuire il link `itms-services://?action=download-manifest&url=https://...`

---

## 8. Flusso notifiche push

### 8.1 Schema generale

```
[iPhone - Guardroom24 app]
        |
        | 1. richiesta permesso + registrazione
        v
[APNs - Apple Push Notification service]
        |
        | 2. token APNs (64 hex)
        v
[Webapp - davinci.perfortuna.it]
        |
        | 3. POST /json_savefcmtoken
        v
[DB: tabella WP_FIREBASETOKENS]
        ^
        | 4. legge token al momento di inviare notifica
        |
[Server Java - PushServiceImpl]
        |
        | 5. APNs HTTP/2 con JWT ES256
        v
[APNs - Apple Push Notification service]
        |
        | 6. consegna notifica
        v
[iPhone - Guardroom24 app]
```

### 8.2 Registrazione del dispositivo

1. L'utente preme "Attiva Notifiche Push" nella webapp
2. La webapp chiama `collegaDispositivo()` in `js/firebaseConfig.js`
3. Su piattaforma nativa Capacitor viene eseguito:
   ```javascript
   PushNotifications.requestPermissions().then(perm => {
       if (perm.receive === 'granted') {
           PushNotifications.register();
       }
   });
   ```
4. iOS mostra il popup di sistema per il consenso
5. Se accettato, iOS contatta APNs e restituisce il token raw (64 char hex)
6. L'evento `registration` scatta con `token.value`
7. La webapp invia il token al server:
   ```
   POST /json_savefcmtoken
   { v_token: "<64-char-hex-token>" }
   ```
8. Il server PHP elimina eventuali token precedenti per lo stesso utente/useragent e inserisce il nuovo in `WP_FIREBASETOKENS`

### 8.3 Salvataggio token lato server PHP

```sql
-- Cancella token duplicati o precedenti dello stesso browser/app
DELETE FROM WP_FIREBASETOKENS
WHERE TOKEN = '{token}'
   OR (UTENTE = '{userid}' AND USERAGENT = '{useragent}');

-- Inserisce il nuovo token
INSERT INTO WP_FIREBASETOKENS
  (TOKEN, UTENTE, LOGIN, HOST, USERAGENT, SESSIONID, CREATIONTIME, MODIFYTIME)
  VALUES ('{token}', '{userid}', '{login}', '{ip}', '{useragent}', '{sessionid}',
          NOW(), NOW());
```

### 8.4 Invio notifica dal server Java

`PushServiceImpl.java` rileva il tipo di token con:

```java
private boolean isApnsToken(String token) {
    return token != null && token.matches("[0-9a-fA-F]{64}");
}
```

Per i token APNs esegue `sendApns()`:

**Generazione JWT ES256:**

```
header  = base64url({"alg":"ES256","kid":"V36CCN4Z9R"})
payload = base64url({"iss":"YVKBSQ6Y56","iat":<unix_timestamp>})
```

Il JWT viene firmato con `AuthKey_V36CCN4Z9R.p8` usando SHA256withECDSA e cachato per 50 minuti (il limite APNs e' 60 minuti).

**Richiesta HTTP/2 a APNs:**

```
POST https://api.push.apple.com/3/device/{64-hex-token}
authorization: bearer {jwt}
apns-topic: com.octopusiot.example
apns-push-type: alert
apns-priority: 10
content-type: application/json

{"aps":{"alert":{"title":"...","body":"..."},"sound":"default"}}
```

### 8.5 Scollegamento dispositivo

L'utente preme "Scollega" nella pagina dispositivi della webapp:
```javascript
scollegaDispositivo(token)
// POST /json_removefcmtoken  {v_token: token}
```
Il server elimina il record dalla tabella `WP_FIREBASETOKENS`.

---

## 9. Troubleshooting

### Notifiche non arrivano

**1. Verificare il tipo di token nel database:**
Il token APNs deve essere esattamente 64 caratteri esadecimali. Se e' piu' lungo, e' un token FCM (non funziona per iOS diretto APNs).

**2. Verificare l'entitlement:**
Il file `ios/App/App/App.entitlements` deve contenere `aps-environment = production`, non `development`.

**3. Verificare che il dispositivo sia nel profilo Ad Hoc:**
Il profilo Ad Hoc funziona solo su dispositivi il cui UDID e' incluso. Aggiungere il dispositivo e rigenerare il profilo se necessario.

**4. Verificare la chiave .p8 sul server:**
La chiave deve essere in `gatewayproxy-batch/src/main/resources/AuthKey_V36CCN4Z9R.p8`.
Log di avvio atteso: `APNs key caricata con successo!`

### Errore APNs 400 - BadDeviceToken

Il token e' invalido o corrotto. L'utente deve scollegarsi e ri-registrarsi dall'app.

### Errore APNs 410 - Unregistered

Il dispositivo ha disinstallato l'app o revocato i permessi. Eliminare il token dalla tabella `WP_FIREBASETOKENS`.

### Errore APNs 403 - Forbidden / InvalidProviderToken

JWT non valido. Verificare:
- La chiave `.p8` e' quella corretta (Key ID: `V36CCN4Z9R`)
- Il Team ID e' `YVKBSQ6Y56`
- La chiave non e' stata revocata su Apple Developer

### Build Codemagic fallisce: "No profiles found"

- Il certificato P12 o il provisioning profile non sono stati caricati su Codemagic
- Il profilo e' scaduto (i profili Ad Hoc scadono dopo 1 anno)
- Il Bundle ID nel profilo non corrisponde a `com.octopusiot.example`

### Build Codemagic fallisce: errori Swift Package Manager

```
error: package at '...' is not reachable
```

Verificare che `npx cap sync ios` sia eseguito prima della build nel workflow. Se il problema persiste, cancellare `ios/App/CapApp-SPM/` e lasciare che `cap sync` lo rigeneri.

### App crasha all'avvio

Causa molto probabile: `GoogleService-Info.plist` assente o invalido.

Soluzione: scaricare il file da Firebase Console (progetto `securhoprova`, sezione iOS) e copiarlo in `ios/App/App/GoogleService-Info.plist` prima della build. Il file non e' in git.

### Permessi notifiche non mostrati

Il popup di sistema viene mostrato solo la prima volta. Se l'utente lo ha rifiutato deve abilitare manualmente:
Impostazioni > Guardroom24 > Notifiche > Consenti notifiche

### L'app mostra schermo bianco o non carica

Verificare la connettivita' di rete e che `https://davinci.perfortuna.it` sia raggiungibile dal dispositivo.

---

## 10. Note importanti e limitazioni

### Firebase SDK iOS NON e' installato

Firebase iOS SDK e' stato deliberatamente escluso perche' causava crash all'avvio dovuti a conflitti di linking con Swift Package Manager. Conseguenze:

- I token APNs (64 hex) **non funzionano** da Firebase Console (invio test manuale)
- L'invio notifiche avviene esclusivamente tramite il server Java tramite APNs HTTP/2
- Il file `GoogleService-Info.plist` deve essere presente per evitare warning Xcode, ma non viene usato attivamente dall'app

### Token APNs vs Token FCM

| Caratteristica | Token APNs (iOS) | Token FCM (Android/Web) |
|---|---|---|
| Formato | Esattamente 64 char hex | Stringa ~150 char alfanumerica |
| Invio server-side | APNs HTTP/2 diretto | Firebase Admin SDK |
| Test da Firebase Console | NO | Si |
| Scadenza | Disinstallazione app | Simile |

Il server Java distingue i token con `token.matches("[0-9a-fA-F]{64}")`.

### Build solo su macOS

Non e' possibile compilare un'app iOS su Linux. Codemagic fornisce Mac Mini M2 in cloud. Non tentare build locali su Linux.

### Provisioning Profile Ad Hoc - Limitazioni

- Richiede registrazione UDID per ogni iPhone destinatario
- Scade dopo 1 anno dalla creazione
- Massimo 100 dispositivi registrati
- Per distribuzione pubblica usare App Store o TestFlight (richiede profilo App Store Connect)

### Chiave APNs p8 - Gestione

- Scaricabile da Apple Developer **una sola volta** al momento della creazione
- Non scade (a differenza dei certificati APNs `.cer` che scadono ogni anno)
- Una singola chiave vale per tutte le app dello stesso Team ID
- Conservare in modo sicuro: se persa va rigenerata e aggiornato `PushServiceImpl.java`

### Scadenza certificati - Riepilogo

| Elemento | Scadenza | Azione al rinnovo |
|---|---|---|
| iOS Distribution `.p12` | 1 anno | Rigenera CSR, carica su Apple Developer, genera nuovo P12, ricarica su Codemagic |
| APNs Certificate `.cer` | 1 anno | Non usato - usiamo la `.p8` |
| APNs Key `.p8` | Mai | Nessuna azione necessaria |
| Provisioning Profile Ad Hoc | 1 anno | Rigenera su Apple Developer, ricarica su Codemagic |

### File sensibili NON in git

La directory `secret/` e il file `GoogleService-Info.plist` sono esclusi da `.gitignore`. Non devono mai essere committati:

```
secret/ios_distribution.key
secret/ios_distribution.p12
secret/AuthKey_V36CCN4Z9R.p8
secret/adhoc.mobileprovision
ios/App/App/GoogleService-Info.plist
```
