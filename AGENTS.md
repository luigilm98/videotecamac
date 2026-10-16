# Istruzioni di ingegneria per Codex e agenti AI

Valide per tutte le modifiche nel repository. Interpretazione operativa dei principi presentati da **antirez** nel video condiviso dal maintainer (15 giugno 2026); non sono citazioni testuali né un'autorizzazione a ignorare sicurezza o verifiche.

## Priorità, in ordine

1. **Saper dire di no.** Chiarire il problema e le condizioni di successo. Prima di generare codice verificare se basta semplificare, riusare o rimuovere. Ogni nuova feature, dipendenza, astrazione, file o documento deve giustificare il proprio costo.
2. **Possedere il modello mentale.** Saper descrivere in linguaggio naturale componenti, responsabilità, percorsi dei dati, transizioni di stato, assunzioni e invarianti. Un nuovo developer deve capire il sistema senza dover leggere ogni riga.
3. **Non revisionare tutto il codice generato per abitudine.** Iniziare da contratti, entry point, test e funzioni interessate. Leggere approfonditamente solo dove serve, **sempre** per parti critiche: autenticazione, permessi, dati sensibili, persistenza, migrazioni, operazioni distruttive, algoritmi contabili o documentazione regolata. La comprensione non è sostituita dai test.
4. **Progettare per essere testabile.** Isolare logica deterministica ed effetti collaterali; preferire test di integrazione che verifichino il comportamento rispetto a unit test fragili legati all'implementazione. Coprire percorsi positivi, errori, autorizzazioni negate, dati vuoti, retry e concorrenza. Eseguire controlli rapidi sulle piccole modifiche e suite multi-piattaforma più ampie prima dei rilasci.
5. **Riconoscere le decisioni quasi irreversibili.** Linguaggio/framework, schemi dei dati, formati su disco, API, confini di sicurezza, migrazioni e distribuzione: descrivere alternative, costi futuri, compatibilità, backup e rollback; chiedere revisione umana prima di interventi distruttivi.
6. **Sapersi fermare.** Se emergono regressioni, fragilità strutturali, conflitti sui dati, duplicazioni o test inaffidabili, interrompere l'aggiunta di feature e consolidare le basi. Preferire refactor piccoli e verificabili alle riscritture speculative.
7. **Comunicare bene.** Nomi espliciti, interfacce comprensibili, commenti sul *perché* e documentazione essenziale che descrive il runtime reale, non capacità ipotetiche. Spiegare scelte e compromessi a una persona in onboarding.

## Protocollo obbligatorio per ogni richiesta

- **Prima:** definire obiettivo, ciò che NON costruire, flusso interessato, invarianti, rischi e piano di test. Ispezionare il codice pertinente, non l'intera codebase senza scopo.
- **Durante:** scegliere la modifica minima; separare dominio, I/O e UI quando apporta beneficio reale; evitare fonti di verità duplicate e refactor non richiesti. Conservare comportamento e compatibilità.
- **Verifica veloce:** controlli mirati su funzioni e contratti toccati. **Verifica di rilascio:** test end-to-end/integrati, rischi di concorrenza, error handling e matrice piattaforme effettivamente supportate.
- **Stop gate:** nessun deploy, migrazione, push forzato, riscrittura Git, scrittura a sistemi esterni o modifica distruttiva dei dati di produzione senza autorizzazione specifica, backup appropriato e controllo degli effetti.
- **Alla fine:** riportare decisioni rifiutate, file cambiati, verifiche davvero eseguite e risultati, verifiche mancanti, rischi residui e stato preciso di commit/PR/deploy. Non inventare evidenze.

## Privacy e limiti

Mai inserire in codice, test, documentazione, log o prompt dati finanziari o clinici veri, file personali, nomi di account locali, password, token, cookie, dump di database o chiavi private. Usare fixture sintetiche. Controllare anche cronologia Git e output di build: `.gitignore` non cancella i commit vecchi. Se un tool non può verificare un comportamento, dichiarare il limite senza proclamarlo sicuro.

## Vincoli specifici del progetto
- Applicazione macOS SwiftUI: scansione libreria, riconoscimento film/serie, metadati, poster, sottotitoli, spostamenti di media e sidecar. Partire da [README.md](README.md) e dai moduli `Sources/` coinvolti.
- Rinomine, spostamenti, modifiche al contenitore MKV/WebM e scritture JSON possono cambiare dati personali non recuperabili: prima simulare il piano su copie in cartelle temporanee. Non usare mai una libreria reale per test automatici.
- Invarianti: correzioni manuali e metadati preservati, nessuna sovrascrittura di film o sottotitoli, idempotenza possibile e gestione degli stati parziali. Un log delle operazioni **non** equivale a un undo.
- Token TMDb/OpenSubtitles, libreria media e percorsi locali restano privati. La configurazione corrente memorizza credenziali in chiaro nelle impostazioni locali: l'eventuale migrazione a Keychain richiede piano di compatibilità e recupero.
- Il repository non contiene una suite Xcode/SwiftPackage riproducibile dichiarata. Non affermare che compila o che è testato su macOS senza una verifica reale. Priorità a test per parsing, identità, caching, move sidecar, iniezione di errori e mancata rete.
- Evitare architetture/framework aggiuntivi per il solo gusto di modularizzare; distinguere UI SwiftUI, provider di metadati, analisi dei file e mutazioni del filesystem.
