# Chat Perché Parkour (Godot)

Jeu de chat multijoueur en 3D à la première personne. Un chasseur doit toucher les chassés, qui fuient sur les toits d'une ville en enchaînant des mouvements de parkour : glissade, course murale, escalade, accroche aux rebords, roulade.

Projet Godot **4.7** en GDScript, sans asset externe : la ville, les textures et les sons sont générés par le code.

## Lancer le jeu

1. Ouvrir Godot 4.7, **Importer**, choisir `project.godot`.
2. Appuyer sur **F5**.

Dans le menu :

- **Solo** : entraînement libre au parkour.
- **Héberger** : crée une partie sur le port UDP 7777. Les autres joueurs rejoignent avec ton adresse IP.
- **Rejoindre** : entre l'adresse de l'hôte, puis clique sur Rejoindre.

Une fois au moins deux joueurs connectés, n'importe qui appuie sur **Entrée** pour lancer la manche.

## Jouer en ligne avec des amis

L'hôte doit être joignable sur le **port UDP 7777**. Deux options :

- **Réseau privé virtuel (le plus simple)** : installez tous [Tailscale](https://tailscale.com) (ou ZeroTier, Radmin VPN). L'hôte donne son adresse Tailscale (`100.x.y.z`), les autres la saisissent dans « Adresse de l'hôte ».
- **Redirection de port** : sur la box de l'hôte, redirige le port UDP 7777 vers son ordinateur. Les autres utilisent l'IP publique de l'hôte.

### Serveur dédié

Pour un serveur qui tourne en permanence (VPS, Coolify, etc.) :

```bash
godot --headless --path . res://scenes/main.tscn -- --server
```

Ou avec un export Linux du jeu : `./ChatPerche.x86_64 --headless -- --server`. Le serveur n'a pas de joueur, il arbitre les parties. Ouvre le port UDP 7777.

## Commandes

| Touche | Action |
|---|---|
| ZQSD / WASD | Courir (touches physiques, marche en AZERTY et QWERTY) |
| Espace | Sauter. Face à un mur : grimper. Contre un mur sur le côté, en l'air : saut mural |
| Maj | Sprinter, uniquement au sol (10,5 m/s, 11 pour le chasseur). Vide la barre d'endurance en ~4,5 s ; elle se recharge en 4 s après une courte pause. Vide, le sprint est bloqué jusqu'à 30 % |
| Ctrl | Glisser en courant (garde ta vitesse). Juste avant d'atterrir d'une chute : roulade |
| Avancer + sauter le long d'un mur | Course murale. Espace pour rebondir avec un boost |
| Espace en l'air face à un rebord | S'agripper et se hisser automatiquement (avec un boost). Sans Espace, on ne s'agrippe pas |
| Clic gauche / F | Chasseur : toucher le chassé dans le viseur (3 m) |
| E | Chasseur : sonar, révèle les chassés à travers les murs pendant 3 s (recharge 20 s) |
| Entrée | Lancer la manche |
| Tab | Scores |
| Échap | Menu |

## Règles

- **Dispersion (10 s)** : le chasseur est bloqué et aveuglé, les chassés s'enfuient.
- **Chasse (2 min 30)** : le chasseur touche les chassés. Un chassé touché passe en vol libre jusqu'à la manche suivante.
- **Fin** : le chasseur gagne s'il touche tout le monde, sinon les chassés gagnent.
- **Points** : +100 par chassé touché, +150 si le chasseur gagne. Chaque seconde de survie rapporte 2 points, et chaque chassé encore libre à la fin gagne +100.
- Le chasseur change à chaque manche : c'est celui qui l'a été le moins souvent.

Les durées sont dans `scripts/net.gd` (`HIDE_T`, `ROUND_T`, `END_T`). Les vitesses et la physique du parkour sont dans les constantes en haut de `scripts/player.gd`.

## Structure

| Fichier | Rôle |
|---|---|
| `scripts/main.gd` | Assemble le jeu : monde, joueur, autres joueurs, HUD, sons. Lit l'état de la partie à chaque image |
| `scripts/player.gd` | Contrôleur de parkour (`CharacterBody3D`), avec un automate d'états : course, glissade, course murale, escalade, hissage, roulade, chute, spectateur. Gère aussi le sprint et l'endurance |
| `scripts/world.gd` | Génère la ville (même graine pour tous). Fournit les sondes de parkour : mur à côté, rebord devant, place pour se tenir debout |
| `scripts/net.gd` | Autoload `Net` : session ENet, liste des joueurs, état des coureurs, logique des manches (côté serveur uniquement) |
| `scripts/avatar.gd` | Affichage d'un autre joueur, interpolé avec ~110 ms de retard |
| `scripts/hud.gd` | Menu, HUD, scores, construits en code |
| `scripts/sfx.gd` | Sons synthétisés au démarrage |

Toute la géométrie solide est faite de boîtes enregistrées avec `World.add_box()`. Elles servent à la fois aux collisions Godot et aux sondes de parkour. Pour ajouter un obstacle utilisable en parkour, passe donc par `add_box()`.

### Réseau

Chaque client simule son propre coureur et envoie son état environ 30 fois par seconde (relayé par le serveur). Le serveur seul gère les manches et valide chaque touche : il refuse une touche si le chasseur et sa cible sont à plus de 7 m d'après les dernières positions reçues.

## Tests

```bash
# Scénarios de parkour (escalade, glissade, course murale, roulade, hissage, rampe)
godot --headless --fixed-fps 120 --path . -s res://tests/parkour_test.gd

# Manche complète en réseau : un serveur dédié et deux bots
godot --headless --path . res://scenes/main.tscn -- --server &
godot --headless --path . -s res://tests/net_client.gd -- --name=A &
godot --headless --path . -s res://tests/net_client.gd -- --name=B

# Captures d'écran (ouvre une fenêtre)
godot --path . --disable-vsync -s res://tests/screenshot.gd -- --out=/tmp/shots
```
