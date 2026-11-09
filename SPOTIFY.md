# Connecter Spotify à LyricLive

## Première configuration (une fois)

1. Ouvrir https://developer.spotify.com/dashboard et créer une application Spotify Web API.
2. Enregistrer exactement ce **Redirect URI** :

   ```text
   com.lyriclive.spotify://callback
   ```

   C’est un schéma personnalisé dédié à OAuth, déclaré dans `App/Info.plist`. Spotify prend en charge les schémas personnalisés pour les apps mobiles ; pour une distribution publique, préférer un schéma propre à votre identifiant ou un Universal Link HTTPS que vous contrôlez. En cas de changement, modifier **les deux constantes** dans `SpotifyClient.swift`, le schéma dans `App/Info.plist` et le Dashboard de façon cohérente.
3. Renseigner le Bundle ID iOS réel de LyricLive si le Dashboard le demande.
4. Copier le **Client ID**, jamais le Client Secret. Le Client ID n’est pas un secret ; le champ dans l’app est stocké localement dans UserDefaults.
5. En mode développement, ajouter le compte Spotify utilisé dans les utilisateurs autorisés. Les conditions actuelles imposent notamment Premium au propriétaire de l’application et limitent les utilisateurs de test ; vérifier les règles dans le Dashboard.
6. Recompiler le projet mis à jour, l’installer sur l’iPhone et ouvrir **Connecter Spotify** → **Configurer Spotify**. Coller le Client ID et choisir **Enregistrer et connecter**.
7. Autoriser l’accès à la lecture en cours dans la fenêtre d’authentification système. Démarrer une chanson dans l’app Spotify, puis revenir dans LyricLive.

Aucun Client Secret, mot de passe Spotify ou jeton ne doit être envoyé dans GitHub ou saisi dans le champ Client ID.

## Comportement

- Scope unique : `user-read-currently-playing`. Ni historique complet, ni modification de playlists, ni commande de lecture.
- OAuth Authorization Code + PKCE S256 avec verifier et state aléatoires, validation du retour et session `ASWebAuthenticationSession`.
- Jetons dans le Keychain (`WhenUnlockedThisDeviceOnly`), renouvellement avant expiration, conservation du refresh token si Spotify ne le renouvelle pas.
- Au premier plan : requête vers `GET /v1/me/player/currently-playing` environ toutes les 3 secondes **après chaque réponse**, donc latence de réseau en plus. Ce n’est pas un flux événementiel instantané. Affichage de la progression **échantillonnée**, sans prétendre à une synchronisation musicale exacte.
- Quand iOS met l’app en arrière-plan/inactive, annulation du suivi. Reprise au retour au premier plan, sans double boucle.
- Affichage du titre, artistes, pochette sans recadrage, lien Spotify, progression et pause. Un résultat 204 efface le morceau ; podcasts, publicités et contenus non musicaux sont signalés.
- 401 : renouvellement puis une nouvelle tentative. Session expirée/révoquée : déconnexion et demande de reconnexion. 403 : message et arrêt des tentatives jusqu’au prochain retour au premier plan. 429 : attente au moins égale au `Retry-After`. Panne réseau : ancien morceau effacé et reprise espacée.
- Déconnecter annule les tâches, efface les données affichées et les jetons du trousseau. Les réponses tardives ne peuvent pas reconnecter une session déconnectée. La déconnexion est locale ; pour retirer aussi l’autorisation côté Spotify, utiliser https://www.spotify.com/account/apps/.

La démo Live Activity/CarPlay existante garde ses textes originaux. Les métadonnées Spotify ne sont pas associées à ces textes et ne sont pas utilisées comme paroles. Cette version n’affiche pas encore le morceau Spotify dans la Live Activity.

## Validation à faire sur iPhone

- Connexion valide, refus de permission et annulation de la fenêtre système.
- Client ID vide/incorrect, Redirect URI mal enregistré et compte non ajouté aux testeurs.
- Démarrer un morceau, changer de morceau, mettre en pause, reprendre et déplacer la lecture : l’état affiché doit rejoindre Spotify au prochain cycle.
- Revenir au premier plan plusieurs fois : pas de boucles de requêtes doublées ; dernière heure de vérification actualisée.
- Déconnecter pendant une requête ou pendant OAuth : pas de retour du morceau ni des jetons dans l’app.
- Relancer l’app après une connexion : reprise depuis le Keychain ; expiration des jetons : renouvellement sans mot de passe.
- Aucun morceau actif (204), contenu non musical, perte de réseau, 401, 403 et 429 (à simuler par un proxy de test si nécessaire). Respecter `Retry-After` même après retour au premier plan.
- La démo Live Activity doit toujours démarrer, changer de ligne et se terminer normalement.

Aucun compte Spotify de test ni Client ID n’a été fourni dans l’environnement de développement. L’authentification réelle et la compilation iOS n’y sont donc pas validées. L’utilisateur a confirmé le fonctionnement de la version précédente de la Live Activity ; cette confirmation ne valide pas cette nouvelle intégration.

## Sources officielles

- https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow
- https://developer.spotify.com/blog/2025-02-12-increasing-the-security-requirements-for-integrating-with-spotify
- https://developer.spotify.com/documentation/web-api/reference/get-the-users-currently-playing-track
- https://developer.spotify.com/documentation/web-api/concepts/quota-modes
- https://developer.spotify.com/documentation/web-api/concepts/rate-limits
