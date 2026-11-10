# LyricLive — Spotify, paroles et Live Activity

**Nouveau : suivi serveur lorsque l’iPhone est verrouillé.** Le code iOS et le backend APNs sont inclus dans `server/`. L’activation exige un serveur HTTPS toujours actif, une clé APNs et une build signée avec Push Notifications. Le service n’est pas déployé ni configuré automatiquement. Voir [le guide serveur](server/README.md).

Le bouton **Connecter Spotify** ouvre l’app Spotify pour obtenir le consentement et revient dans LyricLive. Le Client ID public est intégré. Le morceau en cours s’actualise environ toutes les trois secondes au premier plan.

Les paroles sont recherchées dans **LRCLIB**, une API publique accessible sans clé. Si une version synchronisée existe, la ligne actuelle est surlignée et le texte défile dans l’app. Le bouton **Afficher les paroles dans la Live Activity** envoie cette même ligne à ActivityKit, avec la suivante. Lors d’un changement de morceau, le titre et les paroles sont remplacés. La couverture et la disponibilité varient selon les morceaux et les versions.

## Installer la mise à jour

1. Télécharger le dépôt complet via **Code → Download ZIP**, ou mettre à jour le clone.
2. Ouvrir `LyricLive.xcodeproj` avec **Xcode 26+**. Laisser Xcode résoudre **SpotifyLogin 3.1.2**.
3. Sélectionner le schéma **LyricLive** et un iPhone sous **iOS 26+**. Choisir son équipe de signature pour l’app et l’extension ; utiliser des Bundle IDs uniques et cohérents.
4. Dans Spotify Developer, enregistrer le Bundle ID réel, activer iOS SDK/Web API, autoriser le compte de test et vérifier le Redirect URI : `com.lyriclive.spotify://callback`.
5. Lancer, connecter Spotify, jouer une chanson puis revenir dans LyricLive. Attendre la recherche des paroles sous la section Spotify.
6. Toucher **Afficher les paroles dans la Live Activity**. Vérifier l’écran verrouillé, la Dynamic Island et, dans un véhicule stationné, le tableau de bord CarPlay.

Le projet comprend trois cibles : l’app, l’extension WidgetKit et les tests du parseur de paroles. Les cibles app et extension partagent les attributs ActivityKit. La cible de test dépend de l’app.

## Comportements et limites

- Recherche par titre, artiste principal, album et durée ; seconde tentative sans album si aucun résultat. Pas de substitution par une chanson vaguement similaire.
- Paroles synchronisées : défilement estimé à partir de la progression Spotify ; correction au prochain échantillon en cas de pause, changement ou déplacement dans la chanson.
- Paroles sans timestamps : texte lisible dans l’app, sans inventer une ligne synchronisée dans la Live Activity.
- Instrumental, paroles absentes, panne et limite de requêtes : message explicite et effacement des paroles du morceau précédent.
- Seul le titre/artiste/album/durée nécessaires à la recherche sont transmis à LRCLIB ; jamais les jetons Spotify. Cache mémoire limité à vingt morceaux, aucun stockage persistant de paroles.
- `User-Agent` identifié, requêtes espacées, respect du `Retry-After` et ajout de jitter. Un bouton permet de rechercher à nouveau sans contourner le délai du service.
- Aucun son de notification ni alertConfiguration ; les mises à jour identiques sont regroupées. L’affichage et la cadence sont gérés par ActivityKit et CarPlay.
- **Sans serveur**, la synchronisation fonctionne au premier plan et est suspendue hors de l’app. **Avec le mode serveur configuré**, Spotify et les lignes sont suivis par le backend ; APNs peut actualiser la Live Activity même si l’app ne tourne plus. La fréquence et la livraison sont gérées par Apple et ne sont pas garanties. Une Live Activity ne donne pas de temps d’exécution continu à l’app.
- Au retour, le défilement attend un nouvel échantillon Spotify. En mode local, le changement de titre recrée l’activité. En mode serveur, titre et artiste font partie du contenu dynamique et changent sans recréer l’activité verrouillée. L’arrêt retire l’inscription ; la désactivation du mode serveur supprime sa session.

## Vérification

```sh
xcodebuild -project LyricLive.xcodeproj -scheme LyricLive \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Dans Xcode, lancer **Product → Test** sur un simulateur iOS 26+ pour les tests `LyricsTimelineTests`. Voir `TESTS.md` pour les essais fonctionnels et matériels.

Dans l’environnement Linux de développement, les tests du backend Node ont été exécutés avec succès. Les tests XCTest et la compilation iOS nécessitent un Mac. Les nouveaux envois APNs réels nécessitent les identifiants Apple ; ils ne sont pas validés par les services simulés. **La compilation Swift, les tests XCTest et les essais de cette version sur iPhone/CarPlay n’ont pas été exécutés ici.** Le fonctionnement de la connexion Spotify a été confirmé par l’utilisateur pour la version précédente.

## API et droits avant distribution

L’accès public à l’API LRCLIB autorise son utilisation technique selon sa documentation ; il ne constitue pas une preuve que chaque parole est licenciée pour une distribution commerciale ou automobile. Les conditions et droits pour ces usages doivent être validés avant publication. Spotify indique également que la synchronisation de ses enregistrements avec des paroles est un usage interdit dans ses Compliance Tips ; un accord adapté reste nécessaire pour distribuer ce concept. Ce dépôt est un prototype, pas une validation commerciale ou App Store.

- API LRCLIB : https://lrclib.net/docs.txt
- Authentification et configuration : [SPOTIFY.md](SPOTIFY.md)
- Spotify Compliance Tips : https://developer.spotify.com/compliance-tips
- ActivityKit : https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- CarPlay : https://developer.apple.com/carplay/
