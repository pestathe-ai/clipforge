# ClipForge

Editor video open source per Android e iOS, in stile CapCut. È scritto in
Flutter e usa FFmpeg per l'esportazione.

## Cosa fa (v0.1)

- **Clip**: importi più video dalla galleria e li metti in fila sulla timeline.
- **Montaggio**: puoi dividere una clip alla testina, tagliarne inizio e fine,
  spostarla a destra o a sinistra ed eliminarla.
- **Velocità**: da 0,5× a 2×, e l'audio segue la velocità.
- **Filtri**: B/N, Seppia, Vivace, Contrasto, Freddo. Li vedi già
  nell'anteprima.
- **Testi**: scegli colore, dimensione, posizione e sfondo, e decidi da che
  secondo a che secondo restano visibili.
- **Musica**: aggiungi un brano di sottofondo con il suo volume. Se è più corto
  del video riparte da capo.
- **Formati**: 9:16, 1:1 o 16:9. Le clip vengono adattate con bande nere.
- **Export**: MP4 H.264/AAC a 1080p e 30 fps, salvato nella galleria
  nell'album "ClipForge".

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

- Nell'anteprima la musica parte con il video, ma la sincronizzazione è
  approssimativa. L'export invece è preciso.
- Il taglio si fa con gli slider. Le miniature dei fotogrammi sulla timeline
  sono il prossimo passo naturale, per esempio con `FFmpegKit` e `-vf fps=1`.
- Mancano ancora: transizioni (`xfade`/`acrossfade`), sticker, keyframe,
  annulla/ripeti, salvataggio dei progetti e sottotitoli automatici
  (whisper.cpp).

## Licenza

GPL-3.0-or-later. Serve per forza questa licenza: `ffmpeg_kit_flutter_new`
include componenti GPL (x264, x265), quindi l'app va distribuita sotto GPL 3.0.
Se vuoi una licenza più permissiva, passa a una variante LGPL del pacchetto e
cambia codec. Il font Poppins è distribuito con la SIL OFL 1.1 (vedi
`assets/fonts/`).
