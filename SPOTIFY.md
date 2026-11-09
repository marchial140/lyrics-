# Connexion directe à l’app Spotify

Parcours utilisateur : **Connecter Spotify → app Spotify → consentement si nécessaire → retour dans LyricLive**. Aucun navigateur n’est ouvert par ce parcours. Si Spotify n’est pas installé, l’app demande de l’installer. Spotify peut réutiliser un consentement déjà accordé sans le redemander.

## Première configuration (une fois)

1. Le développeur ouvre https://developer.spotify.com/dashboard et crée une application avec **iOS SDK** et **Web API**, en renseignant le Bundle ID réel de LyricLive.
2. Enregistrer exactement ce **Redirect URI** :

   ```text
   com.lyriclive.spotify://callback
   ```

   C’est un schéma personnalisé dédié à OAuth, déclaré dans `App/Info.plist`. Spotify prend en charge les schémas personnalisés pour les apps mobiles ; pour une distribution publique, préférer un schéma propre à votre identifiant ou un Universal Link HTTPS que vous contrôlez. En cas de changement, modifier **les deux constantes** dans `SpotifyClient.swift`, le schéma dans `App/Info.plist` et le Dashboard de façon cohérente.
3. Renseigner le Bundle ID iOS réel de LyricLive si le Dashboard le demande.
4. Copier le **Client ID**, jamais le Client Secret. Le Client ID n’est pas un secret. Le mettre dans `App/SpotifyConfiguration.swift`, propriété `clientID`, avant de distribuer l’app : les utilisateurs ne verront alors aucun écran de configuration. Le Client ID fourni pour LyricLive est maintenant intégré ; le bouton Configuration développeur et le champ de saisie ont été retirés.
5. En mode développement, ajouter le compte Spotify utilisé dans les utilisateurs autorisés. Les conditions actuelles imposent notamment Premium au propriétaire de l’application et limitent les utilisateurs de test ; vérifier les règles dans le Dashboard.
6. Ouvrir le projet, laisser Xcode résoudre le package **SpotifyLogin**, recompiler et installer sur un iPhone avec Spotify installé et connecté. Appuyer sur **Connecter Spotify**.
7. Accepter le partage dans **l’app Spotify**, qui renvoie ensuite vers LyricLive. Si aucun morceau ne joue, en lancer un dans Spotify puis revenir dans LyricLive. L’authentification ne démarre aucune musique et ne change pas la lecture.

Aucun Client Secret, mot de passe Spotify ou jeton ne doit être envoyé dans GitHub.

## Comportement

- Scope unique : `user-read-currently-playing`. Ni historique complet, ni modification de playlists, ni commande de lecture.
- Authentification app-to-app avec le SDK officiel **SpotifyLogin 3.1.2** (`spotify/ios-auth`), flow `.clientOnlyFailsIfNotInstalled`. Le SDK gère PKCE et l’échange du code ; LyricLive vérifie la destination callback, n’accepte qu’un callback par tentative et ignore les réponses d’une session annulée. `LSApplicationQueriesSchemes` autorise le schéma `spotify`. Le retour SwiftUI utilise `onOpenURL`. Aucun repli vers le navigateur n’est configuré.
- Jetons dans le Keychain (`WhenUnlockedThisDeviceOnly`), renouvellement avant expiration, conservation du refresh token si Spotify ne le renouvelle pas.
- Au premier plan : requête vers `GET /v1/me/player/currently-playing` environ toutes les 3 secondes **après chaque réponse**, donc latence de réseau en plus. Ce n’est pas un flux événementiel instantané. Affichage de la progression **échantillonnée**, sans prétendre à une synchronisation musicale exacte.
- Quand iOS met l’app en arrière-plan/inactive, annulation du suivi. Reprise au retour au premier plan, sans double boucle.
- Affichage du titre, artistes, pochette sans recadrage, lien Spotify, progression et pause. Un résultat 204 efface le morceau ; podcasts, publicités et contenus non musicaux sont signalés.
- 401 : renouvellement puis une nouvelle tentative. Session expirée/révoquée : déconnexion et demande de reconnexion. 403 : message et arrêt des tentatives jusqu’au prochain retour au premier plan. 429 : attente au moins égale au `Retry-After`. Panne réseau : ancien morceau effacé et reprise espacée.
- Déconnecter annule les tâches, efface les données affichées et les jetons du trousseau. Les réponses tardives ne peuvent pas reconnecter une session déconnectée. La déconnexion est locale ; pour retirer aussi l’autorisation côté Spotify, utiliser https://www.spotify.com/account/apps/.

La section paroles recherche maintenant les textes via l’API publique LRCLIB. Quand des timestamps sont disponibles, les lignes sont suivies dans l’app et peuvent être publiées dans une Live Activity. Voir README.md pour les limites d’arrière-plan, de disponibilité et les droits à valider avant distribution.

## Validation à faire sur iPhone

- Spotify installé : un toucher sur Connecter ouvre **Spotify**, montre le consentement si nécessaire et revient dans LyricLive. Tester acceptation, refus, retour manuel sans consentement puis Annuler, et retour en double.
- Spotify non installé : message explicite, aucun navigateur.
- Consentement déjà accordé : Spotify peut revenir sans nouvel écran.
- Interrompre/tuer LyricLive pendant la connexion : une nouvelle tentative peut être nécessaire ; aucun consentement ne doit être inventé.
- Client ID vide/incorrect, Redirect URI mal enregistré et compte non ajouté aux testeurs.
- Démarrer un morceau, changer de morceau, mettre en pause, reprendre et déplacer la lecture : l’état affiché doit rejoindre Spotify au prochain cycle.
- Revenir au premier plan plusieurs fois : pas de boucles de requêtes doublées ; dernière heure de vérification actualisée.
- Déconnecter pendant une requête ou pendant OAuth : pas de retour du morceau ni des jetons dans l’app.
- Relancer l’app après une connexion : reprise depuis le Keychain ; expiration des jetons : renouvellement sans mot de passe.
- Aucun morceau actif (204), contenu non musical, perte de réseau, 401, 403 et 429 (à simuler par un proxy de test si nécessaire). Respecter `Retry-After` même après retour au premier plan.
- La Live Activity doit afficher le titre et les lignes du morceau choisi, puis se terminer normalement. Voir TESTS.md pour les cas de paroles manquantes, pause, recherche et changement de morceau.

Le Client ID public a été fourni et intégré. Aucun accès à un compte Spotify de test n’est disponible dans l’environnement de développement. L’authentification réelle et la compilation iOS n’y sont donc pas validées. L’utilisateur a confirmé le fonctionnement de la version précédente de la Live Activity ; cette confirmation ne valide pas cette nouvelle intégration.

## Sources officielles

- https://github.com/spotify/ios-auth/blob/v3.1.2/README.md
- https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow
- https://developer.spotify.com/blog/2025-02-12-increasing-the-security-requirements-for-integrating-with-spotify
- https://developer.spotify.com/documentation/web-api/reference/get-the-users-currently-playing-track
- https://developer.spotify.com/documentation/web-api/concepts/quota-modes
- https://developer.spotify.com/documentation/web-api/concepts/rate-limits

## Correction de l’attente au retour de Spotify

La session Spotify appartient maintenant à l’app SwiftUI ; le callback est reçu à sa racine. Les retours avec barre oblique finale sont normalisés ; un code/une erreur OAuth dans le fragment peut être normalisé vers la query attendue par le SDK. Les jetons d’un ancien flow implicite ne sont pas acceptés. Un retour invalide produit une erreur au lieu d’être ignoré indéfiniment.

Trois délais bornent la tentative : 120 secondes pour le consentement, 5 secondes après retour au premier plan sans callback (pour laisser passer l’événement onOpenURL), 20 secondes pour l’échange du code après réception du callback. L’état affiche « Retour Spotify reçu. Finalisation de la connexion… » pendant l’échange. Toute fin annule les échéances, détache le SDK et reprend la continuation une seule fois. Les réponses tardives d’anciens managers sont ignorées.

Ces changements corrigent des chemins d’attente identifiés dans le code ; ils ne prouvent pas la cause exacte du blocage observé sur l’iPhone. Le client secret, les codes et les URL de callback complètes ne sont pas journalisés.

À vérifier sur iPhone après mise à jour :

| Cas | Résultat attendu |
|---|---|
| Accepter et revenir automatiquement | Finalisation puis état connecté |
| Revenir manuellement sans accepter | Message d’absence de retour après 5 secondes ; bouton réutilisable |
| Refuser | Erreur explicite ; fin du chargement |
| Code reçu, échange sans réponse réseau | Message d’expiration après 20 secondes ; possibilité de réessayer |
| Refuser puis réessayer | Nouvelle tentative indépendante |
| Callback reçu avant/après le changement de scenePhase | Même traitement, pas d’échec immédiat à la réactivation |
| Même callback livré deux fois | Une seule consommation |
| Callback reçu après Annuler ou expiration | Pas de reconnexion de l’ancienne session |
| Retour avec chemin invalide ou jeton implicite | Erreur, aucun jeton accepté |

La compilation Xcode et ces essais matériels restent à effectuer sur Mac/iPhone.
