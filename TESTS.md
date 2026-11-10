# Tests des paroles et de la Live Activity

## XCTest — à exécuter sur Mac

Le schéma LyricLive contient la cible **LyricLiveTests**. Avec un simulateur iOS 26+, lancer **Product → Test**. Les tests du parseur portent sur : tags multiples, fractions de seconde, métadonnées, tri, limites exactes de lignes, recherche en arrière, silences, doublons, offset, secondes invalides et absence de timestamps.

Ces tests n’ont pas été exécutés dans l’environnement Linux dépourvu de Xcode et de Swift.

## Essais fonctionnels — à renseigner sur iPhone

| Scénario | Résultat attendu |
|---|---|
| Connexion Spotify | Ouverture de Spotify, consentement si nécessaire et retour dans LyricLive |
| Morceau avec paroles synchronisées | Texte LRCLIB, ligne surlignée et défilement au premier plan |
| Morceau avec paroles simples uniquement | Texte affiché, message sans synchronisation, aucun faux surlignage |
| Instrumental | Message instrumental, aucune ancienne parole |
| Version absente du catalogue | Message d’absence et possibilité de rechercher à nouveau |
| Changement de chanson pendant la recherche | Résultat de l’ancienne requête ignoré |
| Pause et reprise dans Spotify | Position corrigée au prochain échantillon ; pas de défilement en pause |
| Déplacement en arrière/avant | Nouvelle ligne sélectionnée au prochain échantillon, sans rester bloqué sur la ligne précédente |
| Lecture avant le premier timestamp | Interlude musical, première ligne présentée comme suivante |
| Live Activity | Bouton explicite, titre réel, ligne actuelle et suivante |
| Nouveau titre avec Live Activity active | Ancienne activité terminée, nouveau titre et nouvelles paroles ; pas de mélange entre chansons |
| Changement vers un titre sans paroles | Message d’indisponibilité à la place des anciennes paroles |
| Arrière-plan/verrouillage | Suivi suspendu, indication dans l’activité ; aucun suivi continu promis |
| Retour au premier plan | Nouvel échantillon Spotify avant de reprendre l’estimation |
| Déconnexion / aucune lecture Spotify | Paroles effacées et activité suivie terminée |
| Arrêter la Live Activity | Retrait demandé à iOS et aucune recréation automatique tant que désactivée |
| Réponse 429/503 LRCLIB | Respect de Retry-After, même avec le bouton Rechercher à nouveau |
| Réseau coupé | Message explicite sans paroles du morceau précédent |
| CarPlay à l’arrêt | Petite présentation, lisibilité, comportement observé selon iOS et le véhicule |
| Grandes tailles de texte / VoiceOver | Commandes compréhensibles et textes accessibles |

Consigner pour chaque essai : iPhone, version/build iOS, Xcode, titre et version du morceau, résultat, délais observés, mode premier plan/arrière-plan et réglages des activités en direct. Pour CarPlay : modèle et firmware du véhicule et connexion filaire/sans fil. Une mise à jour ActivityKit acceptée ne prouve pas une présentation immédiate dans le véhicule.

## Mode serveur / écran verrouillé

Exécuter `cd server && npm test`. Voir server/README.md pour les tests de livraison réelle. Vérifier les deux modes : sans serveur, suspension locale ; avec serveur activé et activité inscrite, observer les lignes écran verrouillé. Tester le changement de titre sans recréation, la rotation du jeton APNs, la désactivation des mises à jour fréquentes, l’arrêt, la déconnexion hors réseau et la reprise après redémarrage serveur. Aucun résultat APNs réel n’est annoncé comme réalisé.
