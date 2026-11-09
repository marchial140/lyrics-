# LyricLive — Live Activity pour iPhone et CarPlay

Connexion Spotify : le bouton **Connecter Spotify** ouvre directement l’app Spotify installée pour obtenir le consentement, puis revient dans LyricLive. Le développeur doit configurer une seule fois son Client ID dans `App/SpotifyConfiguration.swift` ; consulte [SPOTIFY.md](SPOTIFY.md). Titre, artiste, pochette, état de lecture et progression sont actualisés environ toutes les trois secondes au premier plan.

Projet natif Swift / SwiftUI avec **deux cibles** : l’app iPhone et une extension WidgetKit contenant la Live Activity. Le dossier `LyricLive.xcodeproj` est le projet à ouvrir ; garder les dossiers App, Shared et Widget à côté. Le ZIP contient tout le nécessaire.

## Prérequis et lancement

1. Décompresser **LyricLive.zip** sur un Mac avec **Xcode 26 ou plus récent** et le SDK iOS correspondant.
2. Ouvrir `LyricLive/LyricLive.xcodeproj` (ou `LyricLive.xcodeproj` à la racine du dépôt GitHub). Laisser Xcode télécharger et résoudre le package officiel **SpotifyLogin 3.1.2** depuis `spotify/ios-auth`.
3. Sélectionner le schéma partagé **LyricLive**, puis un iPhone ou simulateur sous **iOS 26 ou plus récent**.
4. Pour installer sur iPhone, dans **Signing & Capabilities**, choisir la même équipe pour **LyricLive** et **LyricLiveWidget**.
5. Remplacer les deux Bundle Identifiers par des identifiants uniques, par exemple `ca.votrenom.LyricLive` et `ca.votrenom.LyricLive.widget`. L’identifiant de l’extension doit commencer par celui de l’app suivi d’un point. Ne pas ajouter d’entitlement CarPlay audio/communication ou Time Sensitive pour ce prototype.
6. Activer Developer Mode sur l’iPhone si Xcode le demande. Run.
7. Appuyer sur **Démarrer la Live Activity**. Vérifier l’écran verrouillé et, si disponible, la Dynamic Island. Utiliser **Suivante** pour publier une nouvelle ligne, ou **Lire la démo de 30 secondes** pour le défilement automatique au premier plan.
8. **Arrêter et retirer l’activité** termine toutes les instances appartenant à ce prototype.

L’app déclare `NSSupportsLiveActivities`. Elle ne demande pas les permissions de notifications ordinaires et ne configure aucun son ni APNs. La démo fonctionne sans clé ; la connexion Spotify nécessite ton Client ID public.

## Essayer CarPlay

Dans un véhicule stationné, connecter l’iPhone à CarPlay. Démarrer l’activité depuis l’iPhone, puis ouvrir le tableau de bord CarPlay. Selon les réglages iOS, l’activité peut être proposée automatiquement. Vérifier dans Réglages les activités en direct de LyricLive ainsi que les réglages d’activités en direct de CarPlay disponibles sur votre version.

L’extension fournit une présentation `.small` avec `supplementalActivityFamilies([.small])`, adaptée à CarPlay et Apple Watch. Les vues compactes de la Dynamic Island fournissent également une présentation de repli. Aucun bouton n’est ajouté à la vue CarPlay, les Live Activities y étant non interactives.

**L’affichage et la cadence réelle ne sont pas garantis.** CarPlay et ActivityKit gèrent la présentation. Les essais sur simulateur ne prouvent pas le résultat dans un véhicule.

## Ce que fait ce prototype

- Texte original de cinq lignes, sans parole commerciale ni audio.
- Démarrage et récupération d’une activité existante au retour dans l’app.
- Changement manuel de ligne dans les deux sens.
- Démo de 30 secondes avec mises à jour aux changements de ligne, sans alertConfiguration.
- Pause automatique lorsque l’app quitte le premier plan. La dernière ligne peut rester visible ; une mise à jour demande l’affichage du statut Pause.
- Indication de contenu ancien après la staleDate (60 secondes après la dernière publication) dans les présentations détaillées et petites.
- Arrêt immédiat demandé à ActivityKit ; le rendu effectif reste géré par iOS.
- Interface française, sombre et avec polices système adaptatives.

**La connexion Spotify est disponible dans la section en haut de l’app.** Elle lit les métadonnées de la lecture en cours au premier plan, avec une latence liée au réseau et à Spotify. La Live Activity reste une démonstration indépendante de textes originaux. La synchronisation des paroles et une mise à jour continue en arrière-plan restent des travaux distincts. L’API ActivityKit n’accorde pas de temps d’exécution continu à l’app. Nous n’utilisons ni audio silencieux ni faux mode d’arrière-plan.

L’app n’imite pas la présentation ni le code de Dynamic Lyrics : elle teste le même mécanisme public d’affichage, ActivityKit.

## Validation et limites connues

Projet et sources générés dans Linux ; Xcode, Swift et le SDK iOS n’y sont pas disponibles. **Aucune compilation iOS ni installation n’a pu être exécutée ici.** Les vérifications effectuées concernent la structure du projet, les références de fichiers, l’intégration de l’extension, les fichiers plist et le schéma partagé. Aucun test matériel iPhone/CarPlay n’est annoncé comme réalisé.

Sur Mac, commencer par :

```sh
xcodebuild -list -project LyricLive.xcodeproj
xcodebuild -project LyricLive.xcodeproj -scheme LyricLive \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Puis installer une version signée sur l’iPhone. Aucun catalogue d’icônes de publication n’est fourni : en ajouter un avant distribution. Le projet est un prototype de développement, pas une app prête à publier.

## Sources

- Apple : https://developer.apple.com/carplay/
- CarPlay, Live Activities depuis iOS 26 : https://developer.apple.com/videos/play/wwdc2025/216/
- Présentations et famille small : https://developer.apple.com/documentation/activitykit/creating-custom-views-for-live-activities
- Cycle de vie ActivityKit : https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- Référence qui a orienté ce prototype, Dynamic Lyrics (notes de version annonçant une Live Activity CarPlay) : https://apps.apple.com/us/app/dynamic-lyrics-car-karaoke/id6753217999
- Restrictions Spotify à traiter avant une intégration de paroles synchronisées : https://developer.spotify.com/compliance-tips
