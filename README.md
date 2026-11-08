# Clavier Futé (iOS)

Projet Xcode de l'application iOS. La compilation et l'envoi sur TestFlight se font automatiquement par GitHub Actions (onglet *Actions*).

- À chaque modification : compilation de vérification sur un Mac GitHub.
- *Run workflow* avec « Envoyer sur TestFlight » coché : archive signée avec la clé API App Store Connect et envoi sur TestFlight.

Secrets nécessaires (Settings › Secrets and variables › Actions) : `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (fichier .p8 en base64), `TEAM_ID`.
