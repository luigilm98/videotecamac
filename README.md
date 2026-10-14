# Videoteca

App macOS nativa SwiftUI per catalogare offline i film in `/Users/luigi/Documents/film`.

- App installata: `/Users/luigi/Applications/Videoteca.app`
- Alias Desktop: `/Users/luigi/Desktop/Videoteca`
- Dati locali: `~/Library/Application Support/Videoteca Offline`
- Copertine: generate offline da fotogrammi video con `ffmpeg`
- Player: apre i file con `/Applications/VLC.app` quando disponibile
- Sorgenti: configurabili dall'app, con cartelle o singoli file video anche su dischi esterni
- Metadati online: il pulsante `Cerca online` prova a scaricare metadati e immagini da fonti pubbliche e li salva localmente per uso offline

La cartella dei film viene solo letta. Metadati modificati nell'app e copertine generate restano nella cartella dati locale dell'app.
