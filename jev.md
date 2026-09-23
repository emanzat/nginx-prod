# Jev — mon premier essai avec cette IA de scoring

## C'est quoi, Jev ?

Jev est une intelligence artificielle sortie le 15 septembre, développée par une société nommée TypeSafe.

Sa particularité : elle ne rédige pas de texte. Elle prend une décision — elle choisit une réponse parmi plusieurs options possibles et donne un score de probabilité associé. C'est typiquement le genre d'outil qu'on utilise pour automatiser une prise de décision dans un programme : classer, noter, trier un texte pour déterminer l'étape suivante d'un traitement.

Comme à chaque fois qu'une nouvelle IA sort, j'ai eu envie de la tester tout de suite. Sa rapidité annoncée a fini de me convaincre, et j'ai voulu voir ce que ça donnait une fois branché sur Claude Code, que j'utilise au quotidien.

## Installation dans Claude Code

TypeSafe a publié un guide d'intégration dédié à Claude Code (compétence d'insertion pour Claude Code, Codex et autres agents), disponible sur `docs.typesafe.ai`.

L'installation se fait en deux commandes, à saisir l'une après l'autre dans le terminal :

```
claude plugin marketplace add typesafe-ai/skills
```

Après quelques lignes de logs en anglais, un message confirme l'ajout au marketplace.

```
claude plugin install typesafe@typesafe-ai
```

Là encore, confirmation immédiate que le plugin est bien installé. Dans les deux cas, aucune question n'a été posée entre le lancement de la commande et la fin de l'installation.

Pour les environnements hors Claude Code (comme Codex), la doc officielle tient en une seule ligne :

```
npx skills add typesafe-ai/skills --skill typesafe-ai
```

Une fois l'installation faite, on invoque l'outil directement dans Claude Code avec :

```
/typesafe:typesafe-ai
```

## Premier lancement

À l'appel de la commande, Claude Code a répondu avoir chargé le mode d'emploi de Jev, puis a proposé spontanément trois pistes d'utilisation adaptées au dossier ouvert (qui contenait les données de mon article ainsi qu'un historique de mon travail) :

- évaluer chaque phrase d'un brouillon pour juger de sa clarté auprès d'un lecteur débutant ;
- classer des retours de lecteurs selon la nature du problème signalé ;
- résumer les questions testées dans l'outil de test sous une forme facilement copiable-collable.

## Attention, l'installation ne suffit pas

Installer le plugin ne rend pas Jev fonctionnel tout de suite : ce qu'on installe, ce sont uniquement les instructions d'usage. Pour appeler réellement Jev, il faut une clé API à part, à récupérer dans la section dédiée de l'interface de gestion de Jev — cette clé fait office de mot de passe pour accéder au service.

Claude Code guide ensuite pour l'enregistrer : un simple copier-coller de la commande fournie suffit. Une inscription donne droit à un crédit de démarrage de 5 $.

## Mon cas d'usage : sélectionner des articles liés

Je voulais générer automatiquement une sélection d'articles à recommander en fin de billet. Sur mes 505 articles publiés sur Note, j'ai demandé à Jev de repérer ceux qui intéresseraient le plus les lecteurs de cet article précis.

Résultat en 7 secondes : les trois articles proposés parlaient tous de personnes coincées avec Claude Code — je les ai gardés tels quels en fin d'article.

## Pour la suite

Après avoir bouclé cet article, j'ai découvert que Jev fonctionne aussi avec Cloudflare (hébergeur de sites et d'applications), apparemment gratuitement. C'est mon prochain test.

---

*Pour recevoir les alertes et nouveaux outils au fur et à mesure, la newsletter par e-mail reprend les mêmes contenus que Note et Substack, avec parfois un supplément exclusif.*
