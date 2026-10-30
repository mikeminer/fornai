# Licenza e diritti sul progetto

Il titolare indicato per i materiali originali di FORNAI, nei limiti dei diritti di cui dispone, è **mikeminer**. Il testo applicabile è la [FORNAI Proprietary License](../LICENSE), versione 1.0 del 30 ottobre 2026. È una licenza proprietaria, non una licenza open source.

## Cosa è consentito

| Attività | Regola |
| --- | --- |
| Installare e usare le app ufficiali con Fornai | Consentito dalla licenza, incluse le copie necessarie per installazione e backup. L'accesso al servizio ha condizioni separate. |
| Eseguire il proprio worker e accumulare crediti | Consentito attraverso le funzionalità ufficiali; la licenza non garantisce task o compensi. |
| Leggere il repository pubblico | Consentito. Restano anche i diritti previsti dai termini di GitHub, compreso il fork sulla piattaforma. |
| Copiare o adattare il codice in un altro prodotto | Richiede autorizzazione scritta, fatte salve le eccezioni di legge e i diritti già concessi. |
| Compilare, modificare, redistribuire o rivendere il codice originale | Richiede autorizzazione scritta, con le stesse eccezioni. I comandi di sviluppo nella documentazione non concedono questi diritti. |
| Usare i componenti di terzi | Si applicano le loro licenze, riportate negli [avvisi di terze parti](../THIRD_PARTY_NOTICES.md). |

Per proporre un uso aggiuntivo, apri una [richiesta al proprietario del repository](https://github.com/mikeminer/fornai/issues/new) descrivendo l'uso previsto, senza inserire dati riservati. Prima di inviare modifiche al codice, concorda per iscritto permessi e condizioni del contributo. L'apertura di una richiesta non costituisce autorizzazione; non è previsto un trasferimento automatico dei diritti di eventuali contributori.

## Cosa questa licenza non può impedire

Un repository pubblico resta materialmente leggibile e copiabile. I termini di GitHub prevedono specifici diritti per la piattaforma e per gli utenti, compresa la possibilità di visualizzare e fare fork del repository. La licenza non li annulla. Rendere privato un repository limita i nuovi accessi, ma non elimina fork o copie già esistenti. [Licenze su GitHub](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository), [termini GitHub, sezione D](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service#d-user-generated-content).

Il copyright tutela l'espressione originale del software nei limiti della legge; non attribuisce un monopolio sull'idea del servizio, sui metodi o sulla funzionalità. Documentare l'architettura non impedisce a terzi di realizzare autonomamente un sistema simile. [WIPO: protezione del copyright](https://www.wipo.int/en/web/copyright/protection).

Questa pubblicazione non revoca eventuali autorizzazioni precedenti. Nella cronologia del repository esaminata fino al commit `7f19a13cce2681b2e021c53a22bf0f14da710427` non era presente un file di licenza del progetto; ciò non dimostra l'assenza di altri accordi né l'origine di ogni materiale. L'assenza di una licenza open source non equivale al pubblico dominio.

## Ambito e distribuzione

La licenza copre i materiali originali del progetto per i quali mikeminer dispone dei diritti, inclusi codice, test, documentazione e grafica. Non sostituisce le licenze di Node.js, dei suoi componenti o di altre dipendenze. Né cambia i termini dei fornitori API o i diritti sui risultati web e sul codice letto dall'agente.

Gli header `LicenseRef-Fornai-Proprietary` rimandano al file `LICENSE`: l'identificatore è specifico del progetto, non una certificazione SPDX o un riconoscimento open source. `CODEOWNERS` indica chi deve essere coinvolto nelle revisioni; da solo non impone approvazioni né impedisce copie o fork.

Le build prodotte dallo script aggiornato includono `LICENSE` e `THIRD_PARTY_NOTICES.md` in `Contents/Resources/`, oltre al testo completo di Node in `Contents/Resources/runtime/NODE-LICENSE.txt`. Gli ZIP 0.3.0 già distribuiti prima di questo aggiornamento non vengono modificati retroattivamente: contengono già il testo completo di Node, ma non i due nuovi documenti del progetto.

Il testo è una disciplina proprietaria personalizzata. Prima di accordi commerciali o azioni di tutela, è opportuno farne verificare titolarità, applicabilità e adeguatezza da un professionista legale.
