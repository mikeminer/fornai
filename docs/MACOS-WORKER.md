# Fornai Worker per macOS

L’app usa un’interfaccia nativa macOS e rimane disponibile nella barra dei menu. Collega FreeLLMAPI sul Mac alla coda di Fornai mediante connessioni in uscita: non occorre pubblicare porte locali o configurare un tunnel.

## Requisiti

- macOS 13.5 o successivo, richiesto anche dal runtime Node incluso.
- Versione per Apple Silicon (`arm64`) oppure per Mac Intel (`x86_64`), scelta in base al proprio Mac. In “Informazioni su questo Mac”, Apple M1/M2/M3 e successivi indicano Apple Silicon; un processore Intel indica la versione Intel.
- FreeLLMAPI in esecuzione sullo stesso Mac, con almeno un fornitore e un modello già configurati.
- Un wallet Solana per approvare il collegamento al proprio account su fornai.dev.

Il runtime necessario al worker è incluso nel pacchetto dell’app. Non è necessario installare Node separatamente per usare l’app distribuita.

## Download della versione 0.2.0

| Mac | App | Controllo SHA-256 |
| --- | --- | --- |
| Apple Silicon | [Scarica ZIP](https://fornai.dev/downloads/fornai-worker-macos-arm64.zip) | [Checksum](https://fornai.dev/downloads/fornai-worker-macos-arm64.sha256) |
| Intel | [Scarica ZIP](https://fornai.dev/downloads/fornai-worker-macos-x64.zip) | [Checksum](https://fornai.dev/downloads/fornai-worker-macos-x64.sha256) |

Per verificare il download, salva ZIP e checksum nella stessa cartella e usa `shasum -a 256 -c fornai-worker-macos-arm64.sha256` dal Terminale in quella cartella; su Intel sostituisci `arm64` con `x64`.

Le due versioni sono state compilate e verificate su runner macOS della rispettiva architettura: [risultati della build](https://github.com/mikeminer/fornai/actions/runs/41050741064). Per ciascuna sono passati 19 test della logica Swift, 32 test del runtime e lo smoke test della UI. Il collegamento al wallet reale e a FreeLLMAPI si completa sul proprio Mac.

## Installazione e primo collegamento

1. Apri l’archivio della versione adatta al Mac e sposta `FORNAI Worker.app` in Applicazioni.
2. Apri l’app. L’icona **F** compare nella barra dei menu; la finestra contiene stato, saldo e impostazioni.
3. Lascia l’indirizzo locale predefinito `http://127.0.0.1:31415/v1`, salvo una diversa configurazione locale di FreeLLMAPI. Inserisci la chiave API unificata nel campo protetto e scegli **Verifica API**. Se disponibili, i modelli vengono proposti nel selettore; puoi anche inserire l’ID esatto di un modello.
4. Inserisci un nome riconoscibile senza spazi, per esempio `fornai-mac`, e l’indirizzo **pubblico** del wallet Solana. Scegli **Salva impostazioni**, quindi **Collega wallet**.
5. Nel browser, accedi a fornai.dev con lo stesso wallet e confronta il codice mostrato dall’app. Approva esplicitamente il collegamento. Non inserire la frase di recupero o una chiave privata nell’app.
6. Quando il collegamento è confermato, scegli **Avvia**. La finestra e il menu mostrano lo stato effettivo del worker. **Pausa** interrompe l’attività attraverso il controller del worker.

La chiave FreeLLMAPI è locale; il collegamento al sito non la trasferisce a Fornai. Le richieste AI vengono elaborate dai fornitori configurati in FreeLLMAPI, secondo le loro condizioni e impostazioni. Questo worker usa tali API: non offre automaticamente la GPU del Mac.

## Agente ricerca web

La ricerca web è facoltativa e disattivata nelle configurazioni nuove e in quelle precedenti all’aggiornamento. Metti il worker in pausa, abilita **Agente ricerca web**, scegli Tavily, Exa o Firecrawl e salva. Il motore deve essere già configurato in FreeLLMAPI: il worker usa la stessa chiave unificata e non richiede altre credenziali.

Puoi impostare da 2 a 8 passaggi e da 1 a 5 ricerche per task; i valori iniziali sono 4 passaggi e 2 ricerche. Il limite di passaggi può fermare il lavoro prima di raggiungere quello delle ricerche. Nella console del sito scegli **Ricerca web**: il task attende un worker con questa capacità attiva. **Risposta** mantiene il comportamento senza ricerche.

L’agente lavora sugli estratti e sui collegamenti restituiti dal motore; non controlla un browser e non accede ai repository. L’avanzamento compare nello stato del worker, usando i messaggi già disponibili nell’app.

## Barra dei menu e avvio

Chiudere la finestra nasconde soltanto le impostazioni. Per riaprirla, scegli **Apri Fornai Worker** dall’icona nella barra dei menu. Dallo stesso menu puoi avviare o mettere in pausa il worker, aggiornare il saldo e aprire fornai.dev.

**Esci da Fornai Worker** attende l’arresto gestito dal controller prima di terminare l’app. Per cambiare account o configurazione, metti prima il worker in pausa.

Le opzioni **Avvia il worker quando apro l’app** e **Apri Fornai quando accedo al Mac** sono disattivate al primo avvio. Cambiale soltanto se desideri questo comportamento, quindi salva. L’apertura all’accesso utilizza il servizio nativo di macOS e lascia la finestra nascosta nella barra dei menu; un’apertura manuale mostra le impostazioni. Eventuali autorizzazioni si gestiscono nelle impostazioni di macOS.

## Crediti e abilitazione alla rete

Il collegamento dell’app non abilita automaticamente l’account a ricevere task dalla rete. L’interfaccia indica l’abilitazione restituita da Fornai.

Per un worker abilitato, ogni task completato per un altro wallet guadagna **1 credito interno Fornai**. L’attesa e i task del proprio wallet non generano ricompense. Una richiesta di rete costa 1 credito, salvo quota ancora disponibile dell’Abbonamento 24 ore, che viene usata per prima. I crediti sono spendibili su Fornai; non sono denaro e non sono token PASTA.

## Distribuzione e firma

Lo script di build attuale applica una **firma ad hoc** all’app. Non applica una firma Developer ID e non esegue la notarizzazione Apple. I controlli CI verificano l’integrità della firma, ma non attestano una notarizzazione.

Se macOS impedisce l’apertura, verifica prima che il download provenga dai link Fornai sopra e che il suo SHA-256 corrisponda al file di controllo pubblicato. Soltanto per un pacchetto verificato, puoi usare **Impostazioni di Sistema → Privacy e sicurezza → Apri comunque** e confermare l’apertura di questa app. Non occorre disabilitare Gatekeeper o rimuovere indiscriminatamente gli attributi di quarantena.

## Verifica di sviluppo su macOS

La UI è in `tools/macos-worker/Sources/Main.swift` e `WorkerView.swift`; la logica del worker e la persistenza sono nel controller separato. Richiede AppKit e Combine e usa la modalità linguistica Swift 5. Il punto di ingresso `@main` viene compilato con `-parse-as-library`.

L’eseguibile dell’app supporta uno smoke test isolato:

```sh
"FORNAI Worker.app/Contents/MacOS/FornaiWorker" --self-test
```

Per produrre anche un’immagine della sola finestra applicativa:

```sh
"FORNAI Worker.app/Contents/MacOS/FornaiWorker" --self-test --screenshot "$PWD/build/fornai-worker-ui.png"
```

La modalità `--self-test` costruisce il controller con `testMode: true`, senza leggere il portachiavi o la configurazione personale, aprire il browser, avviare il worker o usare la rete. Verifica i controlli nativi, il campo protetto della chiave, il selettore modelli, i comandi del menu e la permanenza dell’app dopo la chiusura della finestra. Termina con codice `0` e `FORNAI_MACOS_UI_SELF_TEST_OK` se questi controlli passano; altrimenti restituisce un codice diverso da zero.

L’immagine viene prodotta da `NSView.cacheDisplay`: non acquisisce il desktop o altre app e non richiede l’autorizzazione Registrazione schermo. La verifica dell’interfaccia non sostituisce i test di collegamento, portachiavi, elaborazione dei task o firma dell’artefatto.
