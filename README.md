# 📱 Flutter Bank Manager

![Build Status](https://github.com/chuppito/comptes/actions/workflows/main.yml/badge.svg)

Une application Flutter légère et personnalisable pour la gestion de comptes bancaires, conçue pour automatiser le suivi des dépenses via les notifications mobiles.

## 🚀 Objectif de l'application
L'objectif est de centraliser vos finances en temps réel. Cette application permet de regrouper plusieurs sources (Banques, Portefeuilles, Épargne) et d'enregistrer instantanément vos transactions grâce à une intégration avec **MacroDroid**.



## ✨ Fonctionnalités Clés

* **Multi-Banques Personnalisables :** L'application démarre vide ; c'est à vous de créer vos propres banques (Revolut, Trade Republic, Bourso, etc.) directement via l'interface.
* **Automatisation MacroDroid :** Intégration via *Deep Links* pour capturer les notifications bancaires et enregistrer les dépenses/recettes sans aucune saisie manuelle.
* **Pointage Intelligent :** * Les transactions reçues par MacroDroid sont **cochées (pointées) automatiquement**.
    * Les saisies manuelles ponctuelles sont aussi pointées par défaut.
    * Les dépenses récurrentes (loyers, abonnements) restent à pointer manuellement pour vérification.
* **Gestion des Récurrences :** Planification complète (mensuel, trimestriel, etc.) avec gestion des jours d'exclusions.
* **Calcul de Solde :** Visualisez votre solde réel (uniquement ce qui est pointé) ou votre solde théorique.
* **Import/Export JSON :** Sauvegardez vos données ou restaurez-les facilement.

## 🛠️ Installation

Comme l'application est en développement continu, vous pouvez récupérer la dernière version compilée directement sur GitHub :

1.  Rendez-vous sur la page des actions : [https://github.com/chuppito/comptes/actions](https://github.com/chuppito/comptes/actions)
2.  Cliquez sur le dernier workflow réussi (avec une coche verte ✅).
3.  En bas de la page, dans la section **"Artifacts"**, téléchargez le fichier `app-release.apk`.
4.  Installez l'APK sur votre smartphone Android.

## 🤖 Configuration avec MacroDroid

Pour envoyer une dépense automatiquement vers votre application, utilisez l'action "Ouvrir un lien" dans MacroDroid :

`macrodroid://revolut?m={montant}&d={marchand}&t=depense`

*(Remplacez `revolut` par le nom exact de la banque que vous avez créée dans l'application).*

* `m` : Le montant (ex: 12.50).
* `d` : Le nom du marchand (ex: Lidl).
* `t` : Le type (`depense` pour l'onglet rouge, `credit` pour l'onglet vert).

## 🧰 Stack Technique

* **Framework :** Flutter
* **Base de données :** Hive (Stockage local NoSQL ultra-rapide)
* **Deep Linking :** AppLinks pour la communication inter-app.