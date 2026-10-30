# Segnalazioni di sicurezza

Per vulnerabilità del worker, del runtime o del collegamento a Fornai, usa la [segnalazione privata di GitHub](https://github.com/mikeminer/fornai/security/advisories/new). Includi la versione dell'app, il sistema operativo, l'impatto e i passaggi minimi per riprodurre il problema con dati di prova.

Non pubblicare vulnerabilità non risolte nelle issue. Non inviare chiavi API, token di collegamento, seed phrase, chiavi private, file del portachiavi o configurazioni personali. Se serve un log, rimuovi prima credenziali e contenuti delle conversazioni. Le segnalazioni vengono esaminate dal manutentore; non sono promessi tempi di risposta o premi.

## Ambito delle verifiche

Usa un ambiente e account di tua proprietà. Non accedere a dati di altri utenti, non saturare il servizio e non eseguire test distruttivi. Questa pagina descrive il canale di segnalazione; non concede una licenza aggiuntiva sul codice né un'autorizzazione generale a testare servizi esterni.

Il repository contiene il worker macOS e il runtime condiviso. Il codice del sito, del backend, del client Windows e dell'app Android non è pubblicato qui. Per FreeLLMAPI e per i fornitori esterni, usa anche i rispettivi canali di segnalazione quando il problema riguarda quei componenti.

## Confini del worker

Il worker usa richieste in uscita verso Fornai e FreeLLMAPI locale. La chiave API unificata resta sul dispositivo; non viene inviata alla coda Fornai. Il runtime accede ai repository pubblici GitHub indicati dall'utente con richieste di sola lettura e limiti per task: non esegue il codice scaricato e non offre accesso alla shell o ai file locali.

Sul Mac, le credenziali sono gestite tramite Keychain e passate inizialmente nell'ambiente del processo figlio, senza inserirle negli argomenti della riga di comando. Il rinnovo usa la pipe privata dell'app e attende conferma del salvataggio. Stato, giornale dei task e configurazione restano locali e non vanno inclusi nei pacchetti distribuiti. Vedi [architettura e limiti](docs/ARCHITECTURE.md).

Questi confini non rendono i contenuti web affidabili e non garantiscono l'assenza di vulnerabilità. I test automatici non sostituiscono una verifica con wallet, provider e dispositivi reali.
