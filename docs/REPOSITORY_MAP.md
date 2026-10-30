# Mappa del repository Fornai

Questo documento descrive il contenuto pubblicato in [`mikeminer/fornai`](https://github.com/mikeminer/fornai): l’app nativa macOS, il runtime condiviso del worker e gli strumenti per verificarli e distribuirli. Il backend Fornai, il frontend del sito e le applicazioni Windows e Android sono sistemi esterni a questo repository.

La consultazione di questa mappa non concede diritti sui sorgenti. Gli interventi di sviluppo e compilazione richiedono il permesso scritto del titolare, secondo [LICENSE](../LICENSE) e [LICENSING](LICENSING.md).

## Struttura dei componenti

```text
.
├── .gitattributes
├── .gitignore
├── .github/
│   ├── CODEOWNERS
│   └── workflows/macos-worker.yml
├── README.md
├── LICENSE
├── THIRD_PARTY_NOTICES.md
├── SECURITY.md
├── docs/
│   ├── ARCHITECTURE.md
│   ├── LICENSING.md
│   ├── MACOS-WORKER.md
│   └── REPOSITORY_MAP.md
├── scripts/
│   ├── build-macos-worker.sh
│   ├── tray-worker.mjs
│   └── worker-runtime.mjs
├── tests/
│   ├── tray-worker.test.mjs
│   ├── worker-agent.test.mjs
│   ├── worker-renewal.test.mjs
│   ├── worker-repository.test.mjs
│   └── worker-runtime.test.mjs
└── tools/macos-worker/
    ├── Info.plist
    ├── Resources/fornai_logo.png
    ├── Sources/
    │   ├── Main.swift
    │   ├── Policy.swift
    │   ├── WorkerCore.swift
    │   └── WorkerView.swift
    └── Tests/PolicyTests.swift
```

L’albero riporta i sorgenti pubblicati e la documentazione. Le directory di build e la configurazione personale sono escluse dal repository.

## Applicazione nativa

| File | Responsabilità |
| --- | --- |
| [`Main.swift`](../tools/macos-worker/Sources/Main.swift) | Punto d’ingresso, menu, finestra, gestione dell’istanza già aperta e chiusura coordinata. Contiene anche lo smoke test dell’interfaccia e il rendering della sola finestra di test. |
| [`WorkerView.swift`](../tools/macos-worker/Sources/WorkerView.swift) | Controlli AppKit: endpoint locale, chiave protetta, wallet, modello, impostazioni agente, saldo, avvio e pausa. Presenta lo stato del controller. |
| [`WorkerCore.swift`](../tools/macos-worker/Sources/WorkerCore.swift) | Controller, Portachiavi, richieste HTTP, collegamento del wallet, processo Node, ricezione degli eventi e gestione dell’arresto. Coordina la persistenza delle credenziali rinnovate. |
| [`Policy.swift`](../tools/macos-worker/Sources/Policy.swift) | Modelli e validazioni: configurazione, endpoint locale, wallet, credenziale, collegamento, crediti, impostazioni agente e messaggi del processo figlio. |
| [`Info.plist`](../tools/macos-worker/Info.plist) | Identità e versione del bundle, requisito macOS 13.5, modalità barra dei menu ed eccezioni di rete limitate agli indirizzi locali previsti. |
| [`Resources/fornai_logo.png`](../tools/macos-worker/Resources/fornai_logo.png) | Logo usato nella finestra e come sorgente dell’icona generata durante la build. |

## Runtime e comunicazione tra processi

| File | Responsabilità |
| --- | --- |
| [`scripts/tray-worker.mjs`](../scripts/tray-worker.mjs) | Adattatore tra app e runtime. Scambia messaggi JSON separati da righe su canali privati, espone gli stati e attende conferma del salvataggio delle credenziali. Questi canali non sono un log pubblico. |
| [`scripts/worker-runtime.mjs`](../scripts/worker-runtime.mjs) | Implementa configurazione, controlli iniziali, heartbeat, acquisizione e rinnovo dei task, richieste a FreeLLMAPI, ricevute persistenti e rinnovo credenziali. Include l’agente e il lettore dei repository GitHub pubblici. |

L’app nativa avvia il Node incluso nel bundle. Il runtime contatta Fornai per il lavoro assegnato e FreeLLMAPI locale per modelli e ricerca. La modalità `agent` esegue una ricerca online iniziale; `response` e `research` restano compatibili con i task precedenti.

La lettura GitHub parte dai repository pubblici esplicitamente indicati dall’utente. Fissa un commit, consulta una struttura limitata e legge estratti testuali con riferimenti alle righe. Non equivale al caricamento completo di un repository. I limiti di tempo, passaggi e dimensioni e il trattamento dei contenuti remoti sono descritti nell’[architettura](ARCHITECTURE.md).

## Test

| File | Cosa verifica |
| --- | --- |
| [`tests/worker-runtime.test.mjs`](../tests/worker-runtime.test.mjs) | Configurazione, endpoint, ciclo dei task, errori e consegna delle risposte nel runtime. |
| [`tests/worker-agent.test.mjs`](../tests/worker-agent.test.mjs) | Sequenza di ricerca, strumenti, fonti, limiti e casi di errore dell’agente. |
| [`tests/worker-repository.test.mjs`](../tests/worker-repository.test.mjs) | Confini del lettore GitHub: repository consentiti, commit e blob, percorsi, intervalli e citazioni. |
| [`tests/worker-renewal.test.mjs`](../tests/worker-renewal.test.mjs) | Rinnovo delle credenziali e comportamento in caso di fallimento o persistenza incompleta. |
| [`tests/tray-worker.test.mjs`](../tests/tray-worker.test.mjs) | Protocollo privato tra host e runtime, conferme e gestione dell’arresto. |
| [`tools/macos-worker/Tests/PolicyTests.swift`](../tools/macos-worker/Tests/PolicyTests.swift) | Validazioni native, compatibilità della configurazione, credenziali, collegamento, crediti ed eventi. |

Le prove automatizzate usano dati sintetici. Lo smoke test AppKit usa il controller in modalità di test, senza leggere il Portachiavi personale o avviare un worker reale. La riuscita dei test non sostituisce la configurazione e la verifica del collegamento sul Mac dell’utente.

## Build, distribuzione e metadati

| File | Responsabilità |
| --- | --- |
| [`scripts/build-macos-worker.sh`](../scripts/build-macos-worker.sh) | Verifica piattaforma e architettura, recupera Node con checksum fissato, compila Swift e icone, esegue i test, firma ad hoc e confeziona gli artefatti. Eseguibile solo nell’ambito delle autorizzazioni descritte nella licenza. |
| [`.github/workflows/macos-worker.yml`](../.github/workflows/macos-worker.yml) | Due runner macOS nativi, Apple Silicon e Intel. Invoca lo script e raccoglie ZIP, checksum e immagine di test. |
| [`.github/CODEOWNERS`](../.github/CODEOWNERS) | Indica mikeminer come referente delle revisioni; non impone da solo regole di approvazione o restrizioni ai fork. |
| [`.gitattributes`](../.gitattributes) | Regole di terminazione delle righe e trattamento binario delle immagini. |
| [`.gitignore`](../.gitignore) | Esclude output di build, file ambiente, stato locale del worker e metadati del Finder. Non sostituisce il controllo dei contenuti prima della pubblicazione. |

Gli artefatti vengono generati sotto `tools/macos-worker/build/<arm64|x64>/dist/`; non sono sorgenti tracciati. Le nuove build contengono l’app, il runtime Node, i due script, `LICENSE`, `THIRD_PARTY_NOTICES.md` e il testo completo della licenza Node. Il sito ospita i download pubblici collegati nel [README](../README.md#download-per-macos); gli ZIP già pubblicati restano invariati come indicato in [LICENSING](LICENSING.md#ambito-e-distribuzione).

## Documentazione e condizioni

| Documento | Per chi e per cosa |
| --- | --- |
| [`README.md`](../README.md) | Panoramica, download ufficiali e percorso iniziale. |
| [`MACOS-WORKER.md`](MACOS-WORKER.md) | Installazione, impostazioni, collegamento al wallet, agente, pausa e crediti. |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Relazioni tra componenti, flussi e confini di accesso ai dati. |
| [`REPOSITORY_MAP.md`](REPOSITORY_MAP.md) | Questo inventario e ordine di lettura. |
| [`SECURITY.md`](../SECURITY.md) | Segnalazione dei problemi di sicurezza e gestione delle informazioni sensibili. |
| [`LICENSE`](../LICENSE) e [`LICENSING.md`](LICENSING.md) | Licenza proprietaria di mikeminer e autorizzazioni richieste. |
| [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) | Componenti esterni e condizioni applicabili ai rispettivi titolari. |

## Percorsi di lettura

- **Usare l’app:** README → guida macOS → download e collegamento.
- **Comprendere il sistema:** architettura → `Main.swift` → `WorkerView.swift` → `WorkerCore.swift` → adattatore e runtime.
- **Esaminare le validazioni:** `Policy.swift` → test Swift → test del runtime e dei repository.
- **Sviluppare con autorizzazione:** licenza → condizioni di autorizzazione → architettura → script e workflow di build.

Fornai web e il backend gestiscono sessioni, assegnazioni e contabilità dall’esterno. FreeLLMAPI e i fornitori configurati sono dipendenze esterne. Questo repository non contiene i loro sorgenti, le impostazioni personali degli utenti o credenziali di distribuzione.
