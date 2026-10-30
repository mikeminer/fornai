# Fornai Worker per macOS

[![Build macOS](https://github.com/mikeminer/fornai/actions/workflows/macos-worker.yml/badge.svg)](https://github.com/mikeminer/fornai/actions/workflows/macos-worker.yml)
[![Versione pubblica 0.3.0](https://img.shields.io/badge/versione_pubblica-0.3.0-e95735)](#download-per-macos)
[![Licenza proprietaria — non open source](https://img.shields.io/badge/licenza-proprietaria%20%E2%80%94%20non%20open%20source-202720)](LICENSE)

**Fornai Worker** collega FreeLLMAPI sul tuo Mac all’assistente di [fornai.dev](https://fornai.dev). L’app nativa rimane nella barra dei menu, riceve le richieste assegnate, restituisce le risposte e mostra i crediti Fornai riconosciuti al tuo account.

Questo repository pubblica **l’app macOS e il runtime JavaScript condiviso del worker**, con test e automazione di build. I sorgenti del sito, del backend, dell’app Windows e dell’app Android non fanno parte di questo repository.

Il software è proprietario di **[mikeminer](https://github.com/mikeminer)**. La visibilità pubblica dei sorgenti non costituisce una licenza open source: consulta [LICENSE](LICENSE) e [condizioni d’uso dei sorgenti](docs/LICENSING.md).

## Download per macOS

Versione pubblica **0.3.0**. Richiede **macOS 13.5 o successivo** e FreeLLMAPI già configurata sullo stesso Mac. Node 24.21.0 è incluso nell’app: per utilizzare il pacchetto distribuito non serve installarlo separatamente.

| Il tuo Mac | Download ufficiale | Verifica integrità |
| --- | --- | --- |
| Apple Silicon | [Fornai Worker — arm64](https://fornai.dev/downloads/fornai-worker-macos-arm64.zip) | [SHA-256](https://fornai.dev/downloads/fornai-worker-macos-arm64.sha256) |
| Intel | [Fornai Worker — x64](https://fornai.dev/downloads/fornai-worker-macos-x64.zip) | [SHA-256](https://fornai.dev/downloads/fornai-worker-macos-x64.sha256) |

Entrambe le architetture sono state compilate e verificate su runner macOS dedicati nella [build 41060484911](https://github.com/mikeminer/fornai/actions/runs/41060484911). La pipeline controlla il runtime, le policy Swift, l’interfaccia, l’architettura dei binari e l’integrità della firma.

L’app usa una **firma ad hoc**; non dispone di firma Apple Developer ID o notarizzazione Apple. Segui la [guida all’installazione](docs/MACOS-WORKER.md#distribuzione-e-firma) per verificare il download e aprirlo con i controlli di macOS.

## Inizia a usare il worker

1. Scarica il pacchetto adatto al Mac, verifica il checksum e sposta `FORNAI Worker.app` in Applicazioni.
2. Avvia FreeLLMAPI e configura nell’app il suo indirizzo locale e la chiave API unificata. Usa **Verifica API** e scegli un modello disponibile.
3. Inserisci un nome per il worker e l’indirizzo pubblico del tuo wallet Solana. Scegli **Collega wallet**, confronta il codice e approva il collegamento su fornai.dev.
4. Abilita **Agente Fornai**, scegli un motore di ricerca già disponibile in FreeLLMAPI e salva. Premi **Avvia** per ricevere i task compatibili con l’abilitazione del tuo account.

La [guida macOS](docs/MACOS-WORKER.md) descrive configurazione, avvio automatico, pausa, crediti e primo collegamento. Chiudere la finestra lascia l’app disponibile nella barra dei menu; **Pausa** e **Esci** gestiscono l’arresto del worker.

Il collegamento usa connessioni in uscita: non occorre aprire porte o pubblicare l’API locale. La chiave FreeLLMAPI rimane sul Mac, conservata con la configurazione protetta nel Portachiavi. Il worker usa i fornitori API configurati in FreeLLMAPI; i prompt sono elaborati secondo le loro condizioni.

## Un assistente, ricerca e fonti

Ogni nuova richiesta dell’assistente avvia prima una ricerca online, poi prepara la risposta. I motori supportati sono Tavily, Exa e Firecrawl, tramite FreeLLMAPI. La disponibilità effettiva dipende dal motore configurato sul worker.

Quando l’utente indica un repository **GitHub pubblico**, l’assistente può consultarne la struttura e leggere una selezione di file pertinenti. Le letture sono limitate per tempo, passaggi, dimensioni e righe; le citazioni rimandano ai file e alle righe effettivamente letti, su un commit preciso. Gli errori o i limiti di GitHub vengono segnalati. Non viene promessa una lettura completa del repository.

I task non hanno strumenti per eseguire comandi, leggere cartelle locali o accedere a repository privati. Testi, risultati di ricerca e file remoti vengono trattati come dati da analizzare. Per dettagli e confini di accesso, consulta l’[architettura](docs/ARCHITECTURE.md) e la [documentazione sulla sicurezza](SECURITY.md).

Per un account abilitato alla rete, un task completato per un altro wallet accredita **1 credito interno Fornai**. I propri task e l’attesa non generano ricompense. I crediti sono spendibili su Fornai e non sono denaro o token PASTA; collegare il worker non abilita automaticamente l’account ai task di rete.

## Orientarsi nel repository

| Area | Responsabilità |
| --- | --- |
| [`tools/macos-worker/Sources/`](tools/macos-worker/Sources/) | AppKit, barra dei menu, impostazioni, Portachiavi e ciclo di vita del worker. |
| [`scripts/tray-worker.mjs`](scripts/tray-worker.mjs) | Collegamento privato tra applicazione nativa e runtime tramite messaggi JSON. |
| [`scripts/worker-runtime.mjs`](scripts/worker-runtime.mjs) | Coda, elaborazione, ricerca, lettura GitHub, rinnovo credenziali e consegna delle risposte. |
| [`tests/`](tests/) e [`tools/macos-worker/Tests/`](tools/macos-worker/Tests/) | Verifiche isolate del runtime e delle policy native. |
| [`scripts/build-macos-worker.sh`](scripts/build-macos-worker.sh) | Compilazione e confezionamento per la singola architettura Mac. |
| [Workflow macOS](.github/workflows/macos-worker.yml) | Esecuzione su runner Apple Silicon e Intel e raccolta degli artefatti. |

La [mappa dei file](docs/REPOSITORY_MAP.md) spiega il ruolo di ogni componente e propone un ordine di lettura.

## Documentazione

- [Architettura](docs/ARCHITECTURE.md): flussi, processi, stati e confini di fiducia.
- [Mappa del repository](docs/REPOSITORY_MAP.md): cartelle, file e responsabilità.
- [Guida macOS](docs/MACOS-WORKER.md): installazione e uso dell’app distribuita.
- [Sicurezza](SECURITY.md): segnalazioni e indicazioni per non esporre dati sensibili.
- [Licenza e autorizzazioni](docs/LICENSING.md): condizioni applicabili a sorgenti e distribuzione.
- [Componenti di terze parti](THIRD_PARTY_NOTICES.md): avvisi e licenze dei componenti esterni.

## Compilazione dei sorgenti

**Le istruzioni di sviluppo sono destinate esclusivamente a chi ha ottenuto un permesso scritto da mikeminer.** La presenza dei sorgenti, degli script o di una pipeline pubblica non concede il diritto di copiarli, modificarli, compilarli o redistribuirli. Prima di procedere, consulta [LICENSE](LICENSE) e [LICENSING](docs/LICENSING.md).

Per chi è autorizzato, il progetto richiede un Mac della stessa architettura del pacchetto da produrre e gli strumenti a riga di comando di Xcode. Da una copia autorizzata e pulita:

```sh
# Su Apple Silicon
bash scripts/build-macos-worker.sh arm64

# Su Intel
bash scripts/build-macos-worker.sh x86_64
```

Lo script scarica Node dalla distribuzione ufficiale, verifica lo SHA-256 fissato nel sorgente, compila l’app in Swift 5, esegue i test e controlla firme e architettura. Produce ZIP, checksum e immagine della finestra di test in `tools/macos-worker/build/<arm64|x64>/dist/`. La firma ad hoc prodotta dalla pipeline non equivale alla notarizzazione Apple.

Le nuove build includono `LICENSE`, `THIRD_PARTY_NOTICES.md` e il testo completo della licenza di Node, mantenuti come documenti separati. Le licenze di terze parti restano applicabili ai rispettivi componenti, come descritto in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Gli ZIP 0.3.0 già distribuiti restano invariati; vedi [ambito e distribuzione](docs/LICENSING.md#ambito-e-distribuzione).
