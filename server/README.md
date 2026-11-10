# Serveur de suivi LyricLive

Ce service suit Spotify et publie les lignes dans une Live Activity via APNs lorsque l’app n’exécute plus son code. **Il n’est pas déployé par le dépôt.** Un serveur toujours actif, un domaine HTTPS et un compte Apple Developer avec une clé APNs sont nécessaires.

## Lancer

Prérequis : **Node.js 24+**, un disque persistant, un seul processus/une seule instance. Aucune dépendance npm externe. Le SQLite natif de Node est utilisé.

```sh
cd server
cp .env.example .env
node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
```

Copier la valeur générée dans `DATA_KEY` de `.env` et conserver cette clé : elle chiffre les sessions SQLite avec AES-256-GCM. Ne pas changer la clé sans effacer les anciennes sessions ou préparer une migration. Renseigner :

| Variable | Valeur |
|---|---|
| APPLE_TEAM_ID | Team ID Apple à 10 caractères |
| APNS_KEY_ID | Identifiant à 10 caractères de la clé APNs |
| APNS_KEY_PATH | Chemin du fichier privé `.p8`, conservé sur le serveur |
| APP_BUNDLE_ID | Bundle ID **réel de l’app iPhone**, pas celui du widget |
| APNS_ENVIRONMENT | `development` pour Xcode ; `production` pour TestFlight/App Store |
| DATA_PATH | Fichier SQLite sur disque persistant |
| SPOTIFY_CLIENT_ID | Client ID public LyricLive, déjà renseigné dans l’exemple |

Créer une clé APNs dans Apple Developer → Certificates, Identifiers & Profiles → Keys. Activer Push Notifications pour l’App ID correspondant. Stocker le `.p8` et `.env` hors du dépôt, avec accès limité au compte du service. Le service ne transmet pas la clé Apple à l’iPhone.

```sh
npm test
mkdir -p data
npm start
```

Le service écoute par défaut sur `127.0.0.1:8080`. Placer un reverse proxy TLS devant lui (exemple `Caddyfile.example`), avec limite de corps 16 Ko et délais appropriés. Utiliser un certificat HTTPS valide. Le client iPhone refuse HTTP et les URL contenant des identifiants. Garder le port interne inaccessible depuis Internet. Un exemple systemd est fourni ; adapter ses chemins et installer Node 24 au chemin choisi. Ne pas employer un hébergement qui met le processus en veille ou un disque éphémère.

`GET /healthz` indique que le processus est actif ; il ne prouve pas qu’un iPhone reçoit les notifications. Le démarrage exige une configuration Apple syntaxiquement valide et une clé ES256 ; les autorisations réelles Apple doivent encore être testées.

## Configurer Xcode

1. Avec l’équipe Apple Developer payante sélectionnée, activer **Push Notifications** pour la cible **LyricLive** dans Signing & Capabilities. Régénérer le profil si nécessaire.
2. Le dépôt contient `App/LyricLivePush.entitlements` avec `aps-environment=development`. Il est volontairement **désactivé dans la configuration par défaut** pour conserver les builds locaux existants. Dans Build Settings de la cible app, définir `LYRICLIVE_PUSH_ENTITLEMENTS` à `App/LyricLivePush.entitlements` pour les configurations signées utilisées, ou laisser Xcode définir directement Code Signing Entitlements via sa capability.
3. Pour une distribution TestFlight/App Store, employer le profil et l’environnement `production` cohérents, et ajuster l’entitlement si le processus de signature l’exige. L’environnement du serveur doit correspondre au jeton émis par cette build.
4. `NSSupportsLiveActivitiesFrequentUpdates` est déjà activé dans Info.plist. L’utilisateur peut désactiver les mises à jour fréquentes dans Réglages. Aucun faux mode audio, localisation ni mode d’exécution permanente n’est ajouté. Les pushes ActivityKit ne nécessitent pas de demander des alertes/sons de notification ordinaires.
5. Recompiler, connecter Spotify et ouvrir **Suivi avec l’iPhone verrouillé**. Saisir l’URL HTTPS **de base** du serveur (sans sous-chemin), puis Activer.
6. Démarrer la Live Activity. Attendre la confirmation **Live Activity inscrite sur le serveur**. Sans jeton Apple après 15 secondes, un message invite à vérifier signature/capability.
7. Verrouiller l’iPhone et observer. Tester dans le véhicule à l’arrêt.

L’activation transfère les jetons Spotify au serveur contrôlé par l’utilisateur. Pendant ce mode, **le serveur est l’unique propriétaire du renouvellement Spotify** ; au premier plan, l’iPhone récupère la lecture via le serveur, et seul le serveur publie les updates de l’activité. Cela évite les renouvellements concurrents et les mises à jour locales contredisant les pushes.

## Cycle de vie et données

- Une session est protégée par un secret aléatoire par installation, conservé dans le Keychain ; le serveur ne conserve que son hash d’authentification. Aucun mot de passe ou secret partagé global n’est embarqué dans l’app.
- Les jetons Spotify et APNs sont chiffrés en SQLite. Les paroles sont seulement en cache mémoire limité. La réponse de lecture est protégée par le secret de la session et `Cache-Control: no-store`.
- Expiration logique : **6 heures par session**, puis tentative de fin de l’activité et suppression des jetons serveur à la prochaine exécution du worker (donc au redémarrage si le serveur était arrêté). Réactiver/reconnecter après expiration. Une session n’est pas prolongée par une simple réinscription.
- Spotify est interrogé environ toutes les 3 secondes. Le serveur estime la progression entre deux réponses, corrige pauses/recherches/changements de titre, et utilise LRCLIB pour les paroles. Le titre/artiste sont dans le contenu dynamique ActivityKit pour pouvoir changer lorsque l’iPhone est verrouillé.
- Une seule session worker par identifiant est exécutée à la fois. SQLite et les jetons survivent au redémarrage ; les limites Spotify sont persistées. Ne pas lancer plusieurs répliques du service sur cette base.
- Updates APNs de priorité **5**, sans son ni alerte, au changement de ligne ou pour renouveler stale-date. Intervalle minimum : 2 secondes si les mises à jour fréquentes sont autorisées, sinon 15 secondes. **Des lignes peuvent être sautées ou retardées.** Apple ne garantit pas une cadence temps réel. Une erreur Apple apparaît au retour dans l’app.
- Les réponses 429 sont temporisées ; une erreur de jeton d’appareil retire ce jeton sans supprimer automatiquement la session Spotify. Les inscriptions d’activités sont versionnées pour ignorer les retours tardifs d’une ancienne activité.
- Arrêter la Live Activity retire son inscription. Le serveur peut continuer de fournir la lecture à l’app jusqu’à désactivation du mode ou expiration. **Désactiver le suivi serveur** rend les derniers jetons Spotify à l’iPhone et supprime la session du serveur après tentative de fin de l’activité.
- **Déconnecter Spotify** efface la session locale et demande la suppression serveur. Si le réseau empêche la suppression, l’app garde la demande dans le Keychain, réessaie au retour, et indique que l’arrêt n’a pas été confirmé ; le délai de six heures borne la conservation.
- La Live Activity peut survivre à la fermeture de l’app. Les limites et réglages iOS restent applicables, ainsi que la durée maximale d’une Live Activity. Ce mode ne garantit pas une activité perpétuelle ni une livraison après toute fermeture forcée.

Ce serveur est prévu pour un petit déploiement personnel (maximum dix sessions, limitation HTTP par adresse du proxy). Avant un service public, prévoir inscription/attestation des appareils, quotas par utilisateur, supervision, sauvegarde et rotation des clés, et revue de l’accès aux données. Le reverse proxy doit aussi limiter le débit. L’accès public à LRCLIB et l’existence d’APNs ne valident pas les droits sur les paroles ni les conditions Spotify pour une diffusion publique : voir le README principal.

## Tests et vérification réelle

`npm test` utilise seulement des textes originaux et de faux Spotify/APNs. Les tests couvrent progression sans iPhone, pause/recherche, changement de titre, renouvellement et restitution, expiration, SQLite chiffré, isolation des sessions, inscriptions tardives, cooldown, signature ES256 et payload Apple.

Ils **n’attestent pas** d’une livraison APNs réelle. Pour cela, vérifier successivement : build signée compatible, jeton ActivityKit reçu, inscription HTTPS réussie, environnement/bundle/key corrects, lecture Spotify accessible, puis observation avec écran verrouillé. Tester aussi arrêt, révocation, redémarrage du serveur et absence de réseau. Le statut d’inscription seul n’est pas un accusé de réception visuel.
