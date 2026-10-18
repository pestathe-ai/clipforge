# ClipForge

Editor video open source per Android e iOS, in stile CapCut. È scritto in
Flutter e usa FFmpeg per l'esportazione.

## Cosa fa (v0.2)

- **Timeline in stile CapCut**: la testina resta fissa al centro e la timeline scorre sotto. Le clip mostrano le miniature dei fotogrammi. Con due dita fai lo zoom, tenendo premuto trascini una clip per spostarla, con le maniglie bianche tagli inizio e fine.
- **Montaggio**: dividi alla testina, duplica, elimina, cambia la velocità da 0,5× a 2×, regola il volume. Annulla e ripeti sono illimitati e il salvataggio è automatico.
- **Transizioni** (12 tipi): dissolvenza, nero, bianco, scorrimento, tendina, cerchio, zoom, pixel, sfocatura, schiaccia. Le tocchi dal quadratino tra due clip e puoi applicarle a tutte le clip in una volta.
- **Effetti** (10): zoom lento avanti e indietro, tremolio, glitch, VHS, vignetta, specchio, sfocato, flash.
- **Filtri** (9): B/N, seppia, vivace, contrasto, freddo, caldo, sbiadito, noir.
- **Testi**: stili rapidi, colori, sfondo e contorno, animazioni di entrata e uscita. Li sposti, ingrandisci e ruoti col dito direttamente sull'anteprima.
- **Sticker**: 64 emoji animate.
- **Sottotitoli automatici**: Whisper gira sul telefono, offline, in 6 lingue. I sottotitoli si correggono come testi e puoi applicare lo stesso stile a tutti.
- **Musica**: volume, ripetizione automatica se il brano è corto, dissolvenza finale.
- **Formati**: 9:16, 1:1, 16:9 e 4:5, con sfondo sfocato, nero o bianco ai lati.
- **Export**: MP4 1080p a 30 fps, salvato in galleria nell'album "ClipForge". Testi e sticker escono identici all'anteprima.

### Novità v0.3

- **Foto** come clip, con durata regolabile e zoom lento automatico.
- **Sovrapposizioni** (picture-in-picture) di video e foto: le trascini, le ridimensioni con due dita, cambi l'opacità.
- **Green screen** (chroma key) su verde, blu, nero e bianco.
- **Maschere**: cerchio, arrotondata, cuore, stella, rombo.
- **Keyframe di movimento** per testi, sticker e sovrapposizioni.
- **Voce fuori campo** registrata mentre il video scorre, ed **effetti sonori** da file.
- **Effetti voce**: scoiattolo, voce profonda, eco, radio, megafono, sala. C'è anche la **riduzione del rumore**.
- **Al contrario**, **ruota** di 90°, 180° o 270°.
- **7 modelli pronti**: Vlog, Sport, Cinematico, Ricordi, Retrò VHS, Social/Reel, Bianco e nero.
- Gli aggiornamenti si installano sopra la versione precedente, grazie alla chiave di firma fissa.

### Novità v0.4

- **Rimozione dello sfondo con l'IA**: ML Kit trova le persone fotogramma per fotogramma, direttamente sul telefono. Funziona sulle clip e sulle sovrapposizioni.
- **Tracciamento del movimento**: testi, sticker e sovrapposizioni seguono un oggetto nel video.
- **Curve di velocità**: Montaggio, Eroe, Proiettile, Salto, Lampo, Accelera, Rallenta. L'audio segue la curva.
- **Keyframe di zoom e rotazione**, oltre alla posizione: con due dita sull'anteprima.
- **Regola**: luminosità, contrasto, saturazione, temperatura e nitidezza, da applicare anche a tutte le clip.
- **Ritaglia** (ingrandimento e inquadratura), **Stabilizza**, **Fermo immagine**.
- **Estrai audio** dalla clip e **dissolvenze audio** in entrata e in uscita.
- **Esportazione** a 720p, 1080p, 2K o 4K, con 24, 25, 30 o 60 fps.

## Avvio rapido

Ti servono Flutter 3.27 o più recente, Android Studio e/o Xcode (per iOS
serve un Mac).

```bash
cd clipforge
./tool/setup_platforms.sh   # genera android/ e ios/, minSdk 24, iOS 14, permessi
flutter run                 # su un telefono collegato o un emulatore
flutter test                # test del generatore di comandi FFmpeg
```

Se `flutter pub get` segnala versioni incompatibili, prova
`flutter pub upgrade --major-versions`.

## Struttura

```
lib/
  main.dart                    tema e avvio
  models/project.dart          clip, testi, musica, filtri, formati
  services/export_command.dart costruisce il grafo FFmpeg (Dart puro, testato)
  services/ffmpeg_service.dart ffprobe, export con avanzamento, annulla
  screens/home_screen.dart     scelta del formato
  screens/editor_screen.dart   anteprima, riproduzione multi-clip, strumenti
  widgets/timeline.dart        tracce video / testi / musica e testina
  widgets/edit_sheets.dart     pannelli taglio, velocità, filtro, volume, testo
```

### Come funziona l'export

Per ogni clip la pipeline fa: `trim`, poi `setpts` per la velocità, poi
`scale`+`pad` per adattarla al formato, poi il filtro colore. L'audio fa
`atrim`, poi `atempo`, poi `volume`. Le clip senza audio ricevono un silenzio
generato con `anullsrc`, così `concat` funziona sempre. Dopo la
concatenazione si aggiungono `drawtext` per ogni testo (con `textfile`, che
evita i problemi di escape) e `amix` con la musica.

## Limiti noti e prossimi passi

- Nell'anteprima le transizioni sono un taglio netto e alcuni effetti (glitch, VHS) sono approssimati. Nel video esportato escono completi.
- La prima volta i sottotitoli devono scaricare il modello: circa 100–160 MB.
- Nell'anteprima il chroma key e gli effetti voce non si vedono e non si sentono: sono applicati al video esportato.
- La rimozione dello sfondo riconosce le persone, non gli oggetti, e si vede solo nel video esportato. Vale lo stesso per la stabilizzazione.
- Il tracciamento segue bene oggetti con contrasto e movimento regolare. Con movimenti molto veloci o oggetti che spariscono può perdersi.
- Mancano ancora rispetto a CapCut: sincronizzazione automatica col ritmo della musica, sintesi vocale (testo in voce), effetti IA di stile e la libreria online di modelli, musica ed effetti.

## Licenza

GPL-3.0-or-later. Serve per forza questa licenza: `ffmpeg_kit_flutter_new`
include componenti GPL (x264, x265), quindi l'app va distribuita sotto GPL 3.0.
Se vuoi una licenza più permissiva, passa a una variante LGPL del pacchetto e
cambia codec. Il font Poppins è distribuito con la SIL OFL 1.1 (vedi
`assets/fonts/`).
