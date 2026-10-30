# Billes & Rampes

Jeu de circuits de billes en réalité mixte pour Meta Quest 3.

- **Mode libre** : construisez des circuits au-dessus de vos vrais meubles.
- **Mode Défis** : 8 niveaux avec pièces limitées et 3 étoiles à attraper.
- **Aimantation** : une pièce lâchée près de l'entrée ou de la sortie d'une autre s'y aligne toute seule.

## Application Quest (APK)
Le dossier `godot/` contient la version native (Godot 4.7 + OpenXR, passthrough Meta).
À chaque envoi sur `main`, GitHub Actions teste les niveaux, compile l'APK et le publie dans **Releases**.

Installation : mode développeur activé sur le Quest, puis installer `billes-rampes.apk`
(SideQuest, Meta Quest Developer Hub ou `adb install`). L'appli apparaît dans « Sources inconnues ».

## Version web
`index.html` (WebXR, Three.js, cannon-es) se joue dans le navigateur du Quest.
`powershell -ExecutionPolicy Bypass -File build-single.ps1` crée `dist\billes-rampes.html`, qui contient tout le jeu en un fichier.

```
powershell -ExecutionPolicy Bypass -File serve.ps1          # https://<ip-du-pc>:8443 pour le Quest
powershell -ExecutionPolicy Bypass -File serve.ps1 -Http    # http://localhost:8080 sur le PC
```
