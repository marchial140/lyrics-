# Vérification sur Mac, iPhone puis CarPlay

Tous les résultats matériels sont **à renseigner**. Essais dans une auto stationnée.

| Test | Action | Résultat attendu / à vérifier |
|---|---|---|
| Projet | Ouvrir, lister et compiler avec Xcode 26+ | Deux cibles, extension embarquée, schéma LyricLive |
| Signature | Même équipe, identifiants app/extension cohérents | Installation sur iPhone |
| Démarrage | Toucher Démarrer deux fois | Une seule activité active, pas d’accumulation |
| Écran verrouillé | Démarrer puis verrouiller | Texte de démo visible si les réglages le permettent, statut Pause |
| Dynamic Island | iPhone compatible | Vue compacte puis présentation développée |
| Navigation | Suivante puis Précédente | Ligne publiée dans la Live Activity ; cadence observée à noter |
| Défilement | Lire la démo au premier plan | Cinq lignes sur 30 s, fin en pause |
| Pause | Mettre en pause puis reprendre | Le compteur reprend à son point d’arrêt |
| Arrière-plan | Quitter l’app pendant la démo | Lecture locale suspendue, aucune promesse de défilement continu |
| Réouverture | Revenir après verrouillage / relancement | Activité existante retrouvée, pas de doublon, commandes disponibles |
| Suppression système | Retirer la Live Activity hors de l’app puis revenir | État retrouvé sans activité ; redémarrage possible |
| Désactivation | Désactiver les activités en direct dans Réglages | Message explicite au démarrage |
| Contenu ancien | Attendre plus de 60 s sans publier | Indication de mise à jour ancienne dans les vues qui l’affichent |
| Arrêt | Toucher Arrêter | Retrait demandé, toutes les activités du prototype terminées |
| CarPlay | Connecter et afficher le tableau de bord | Petite présentation si iOS la propose ; noter présence ou absence |
| Concentration | Refaire l’essai CarPlay avec/sans Concentration | Noter la présentation réelle et les alertes éventuelles |
| Accessibilité | Agrandir le texte, utiliser VoiceOver sur iPhone | Commandes compréhensibles, lisibilité et absence de chevauchements |

Pour chaque essai, consigner : iPhone, iOS/build, Xcode, véhicule et firmware, connexion filaire/sans fil, réglages des activités en direct, résultat, délai observé et capture éventuelle. Un update accepté par ActivityKit ne prouve pas une présentation immédiate dans l’auto.
