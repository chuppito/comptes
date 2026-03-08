# 📱 Flutter Bank Manager

![Build Status](https://github.com/chuppito/comptes/actions/workflows/main.yml/badge.svg)

Une application Flutter légère et intuitive pour la gestion de comptes bancaires multi-sources, conçue pour automatiser le suivi des dépenses via des notifications mobiles.

## 🚀 Objectif de l'application
L'objectif est de centraliser vos finances en temps réel. Contrairement aux applications bancaires classiques, celle-ci permet de regrouper plusieurs banques (Revolut, Trade Republic, etc.) et d'enregistrer instantanément vos transactions grâce à une intégration poussée avec **MacroDroid**.

## ✨ Fonctionnalités Clés

* **Multi-Banques :** Créez et gérez autant de comptes bancaires que nécessaire.
* **Automatisation MacroDroid :** Intégration via *Deep Links* pour capturer les notifications bancaires et enregistrer les dépenses/recettes sans ouvrir l'application.
* **Pointage Intelligent :** Les transactions issues des notifications sont cochées automatiquement (pointées), tandis que les dépenses récurrentes restent à pointer.
* **Gestion des Récurrences :** Planifiez vos loyers, abonnements et factures (mensuel, trimestriel, etc.) avec gestion des exclusions de dates.
* **Calcul de Solde Prévisionnel :** Visualisez votre solde réel (pointé) vs votre solde théorique à venir.
* **Import/Export JSON :** Sauvegardez vos données localement ou transférez-les facilement entre appareils.
* **Mode Calendrier :** Une vue globale pour anticiper vos flux financiers.

## 🛠️ Installation

Le projet utilise GitHub Actions pour compiler automatiquement l'application.

1.  Rendez-vous sur l'onglet **"Actions"** de ce dépôt GitHub.
2.  Cliquez sur le dernier workflow réussi (marqué d'une coche verte ✅).
3.  Descendez jusqu'à la section **"Artifacts"**.
4.  Téléchargez le fichier `app-release.apk` et installez-le sur votre appareil Android.

## 🤖 Configuration avec MacroDroid (Exemple)

Pour envoyer une dépense automatiquement à l'application, configurez une action "Ouvrir un lien" dans MacroDroid avec ce format :

`macrodroid://revolut?m={montant}&d={marchand}&t=depense`

* `m` : Le montant extrait de la notification.
* `d` : Le nom du marchand.
* `t` : Le type (depense ou credit).

## 🧰 Stack Technique

* **Framework :** Flutter
* **Base de données :** Hive (Stockage local rapide)
* **Gestion d'état :** Singleton Store pattern
* **Deep Linking :** AppLinks