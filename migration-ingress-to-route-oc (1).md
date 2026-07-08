# Migration Ingress nginx (IKS) → Route OpenShift (ROKS)

> Référentiel de migration : arbre d'orientation de la terminaison TLS + tableau de correspondance des annotations `nginx.ingress.kubernetes.io/*` vers les Routes OpenShift.
> Pour chaque annotation sans équivalent natif sur la Route, une solution est proposée.
>
> **Convention** : « Route OpenShift » à la première mention, « Route » ensuite.
> Schémas associés (mêmes contenus, éditables) : `arbre-decision-tls-route.drawio`, `arbre-decision-tls-route.svg`.

---

## 1. Contexte & principes

**Objectif** : traduire fidèlement chaque Ingress IKS en Route ROKS équivalente, selon le **besoin réel de l'application**. Ce document ne recommande pas un mode de terminaison a priori — il fournit la correspondance et laisse le besoin exprimé par l'Ingress décider.

- **Le mode de terminaison découle du besoin, pas d'un choix par défaut** :
  - `passthrough` = **cas général** : l'application termine elle-même le TLS (le routeur ne déchiffre pas).
  - `reencrypt` : lorsque le routeur doit voir le trafic HTTP (fonctions L7) **et** que le backend sert du TLS.
  - `edge` : **exclu** par politique (chiffrement pod-to-pod obligatoire → pas de trafic en clair vers le pod).
- **Sidecar nginx = solution de repli pour les fonctions L7 non exprimables sur une Route** (regex, CORS, snippets, buffering, tailles de body). À mobiliser **au besoin**, quand ni la Route ni le `passthrough` ne peuvent porter la fonctionnalité — pas de façon systématique. La Route ne porte que ce qui est exprimable en annotation `haproxy.router.openshift.io/*` / `router.openshift.io/*` ou en champ `spec.*`.
- **Limites structurelles d'une Route** :
  - matching de path en **préfixe uniquement** (pas de regex) ;
  - **aucune injection** de configuration HAProxy arbitraire par Route (pas d'équivalent `configuration-snippet`) ;
  - en `passthrough`, **le routeur ne déchiffre pas le trafic et ne voit que le SNI TLS** → ni cookie, ni multipath, ni manipulation HTTP.

---

## 2. Arbre de traduction — quelle terminaison pour la Route ? (version simplifiée)

Le mode de terminaison de la Route se **déduit** de ce que déclare l'Ingress. `passthrough` est le cas général (l'application termine le TLS). La seule bascule vers `reencrypt` a lieu lorsqu'une fonctionnalité nécessite que le routeur voie le trafic HTTP (affinity/cookie, multipath, rewrite/regex, manipulation de headers, CORS, snippet) : le `passthrough` ne peut alors pas la porter.

```mermaid
flowchart TD
    Start(["Ingress nginx + annotations"]) --> Q0{"ssl-passthrough = true ?"}

    Q0 -->|"false / absent"| INFO["Router termine le TLS → L7 disponible<br/>Fonctions L7 : affinity/cookie, multipath,<br/>rewrite/regex, headers, snippet, CORS<br/>→ passthrough exclu"]
    Q0 -->|"true"| Q1{"Besoin L7 ? le router doit voir le HTTP"}

    Q1 -->|"OUI"| RE
    Q1 -->|"Non"| PT["PASSTHROUGH<br/>TLS terminé au pod"]

    INFO --> RE["REENCRYPT + destinationCACertificate<br/>(quand le routeur doit voir le HTTP)"]

    classDef pt fill:#f3e8ff,stroke:#a855f7,color:#6b21a8
    classDef re fill:#dcfce7,stroke:#22c55e,color:#15803d
    classDef info fill:#ecfeff,stroke:#06b6d4,color:#0e7490
    class PT pt
    class RE re
    class INFO info
```

> **EDGE non applicable** : chiffrement pod-to-pod obligatoire (choix de politique, pas un oubli).

**Résumé décisionnel**

| Situation | Verdict |
|---|---|
| `ssl-passthrough = false` / absent | **REENCRYPT** |
| `ssl-passthrough = true` + besoin L7 (OUI) | **REENCRYPT** |
| `ssl-passthrough = true` + aucun besoin L7 (Non) | **PASSTHROUGH** |

---

## 3. Tableau de correspondance des annotations

Colonne **Cible** : `ANN` = annotation de Route · `SPEC` = champ `spec.*` de la Route · `IC` = configuration `IngressController` (global) · `SIDECAR` = à porter dans la conf du sidecar nginx · ❌ = pas d'équivalent natif Route.
Colonne **Équivalent Route** : `—` quand il n'existe pas d'équivalent (voir alors la colonne **Solution**).
Colonne **Passthrough ?** : ✅ compatible avec une Route `passthrough` · ❌ nécessite que le routeur voie le trafic HTTP (force `reencrypt`) · N/A sans objet (géré hors routeur / indépendant de la terminaison) · **Choix** = l'annotation détermine elle-même le mode de terminaison.
Les lignes marquées *(doc)* sont confirmées par les tables 2 & 3 de la page Confluence existante.

### 3.1 TLS & redirection

| Annotation nginx | Cible | Équivalent Route | Solution | Passthrough ? |
|---|---|---|---|---|
| `nginx.ingress.kubernetes.io/ssl-passthrough` | SPEC | `spec.tls.termination: passthrough` | Uniquement si aucun besoin L7 (cf. arbre) ; sinon `reencrypt`. | Choix |
| `nginx.ingress.kubernetes.io/ssl-redirect` | SPEC | `spec.tls.insecureEdgeTerminationPolicy: Redirect` | À configurer explicitement pour forcer HTTPS. Le défaut n'est pas garanti à `Redirect` (souvent `None` selon la plateforme / le mode de création de la Route). | ✅ |
| `nginx.ingress.kubernetes.io/force-ssl-redirect` | SPEC | `spec.tls.insecureEdgeTerminationPolicy: Redirect` | Idem `ssl-redirect`. | ✅ |
| `ingress.kubernetes.io/force-ssl-redirect` | SPEC | `spec.tls.insecureEdgeTerminationPolicy: Redirect` | Ancienne clé, même mapping. | ✅ |
| `nginx.ingress.kubernetes.io/backend-protocol` | SPEC | — | Déterminé par la terminaison (`reencrypt` ⇒ backend HTTPS). gRPC/h2c → `appProtocol` sur le Service ou `passthrough`. | N/A |
| `nginx.ingress.kubernetes.io/ssl-protocols` | IC / SIDECAR | — | Versions/ciphers via `IngressController.spec.tlsSecurityProfile` (global) ; par app → `ssl_protocols` du sidecar. | N/A |
| `nginx.ingress.kubernetes.io/proxy-ssl-verify` | SPEC | `spec.tls.destinationCACertificate` | Vérif du backend en reencrypt ; contrôle fin → sidecar. | N/A |
| `nginx.ingress.kubernetes.io/proxy-ssl-server-name` | SIDECAR | — | SNI vers backend non configurable per-route → `proxy_ssl_name` / `proxy_ssl_server_name` du sidecar. | N/A |
| `nginx.ingress.kubernetes.io/auth-tls-verify-client` | IC / SIDECAR | — | mTLS client via `IngressController.spec.clientTLS`, mTLS applicatif via `passthrough`, ou terminaison au sidecar. | ✅ |
| `nginx.ingress.kubernetes.io/force-http1` | IC / SIDECAR | — | HTTP/2 piloté au niveau IngressController (`ingress.operator.openshift.io/default-enable-http2`) ; sinon downgrade au sidecar. | N/A |

### 3.2 Session affinity & cookies

| Annotation nginx | Cible | Équivalent Route | Solution | Passthrough ? |
|---|---|---|---|---|
| `nginx.ingress.kubernetes.io/affinity` *(doc)* | ANN | `haproxy.router.openshift.io/disable_cookies: "false"` | Sticky session activée par défaut. | ❌ |
| `nginx.ingress.kubernetes.io/affinity-mode` | ANN | `haproxy.router.openshift.io/balance: source` | `persistent` ≈ cookie par défaut ; `source` = affinité par IP. | ❌ |
| `nginx.ingress.kubernetes.io/session-cookie-name` *(doc)* | ANN | `router.openshift.io/cookie_name: <nom>` | — | ❌ |
| `nginx.ingress.kubernetes.io/session-cookie-expires` | SIDECAR | — | Durée de vie du cookie non configurable sur Route → sticky avec `expires` au sidecar si requis. | ❌ |
| `nginx.ingress.kubernetes.io/session-cookie-max-age` | SIDECAR | — | Idem → sidecar. | ❌ |

> Annotations Route natives complémentaires côté cookie *(doc, Table 3)* : `haproxy.router.openshift.io/disable_cookies` (Boolean, désactive le sticky), `router.openshift.io/cookie-same-site` (attribut SameSite : Strict / Lax / None).

### 3.3 Routing, rewrite & path

| Annotation nginx | Cible | Équivalent Route | Solution | Passthrough ? |
|---|---|---|---|---|
| `nginx.ingress.kubernetes.io/rewrite-target` *(doc)* | ANN + SPEC | `haproxy.router.openshift.io/rewrite-target` + `spec.path` | — | ❌ |
| `ingress.kubernetes.io/rewrite-target` | ANN + SPEC | `haproxy.router.openshift.io/rewrite-target` + `spec.path` | Ancienne clé, même mapping. | ❌ |
| `nginx.ingress.kubernetes.io/use-regex` | SIDECAR | — | Route = matching préfixe (pas de regex, ex. `api/*` non géré) → `location` regex au sidecar. | ❌ |
| `nginx.ingress.kubernetes.io/app-root` | SIDECAR | — | Pas d'équivalent → `rewrite` / `return 302` au sidecar ou géré par l'app. | ❌ |
| `nginx.ingress.kubernetes.io/canary` *(doc)* | SPEC | `spec.alternateBackends` | **Équivalent uniquement pour le canary pondéré** (`weight`). Le routage canary par header / cookie / pattern n'a pas d'équivalent Route → sidecar ou app. | Pondéré N/A · header/cookie ❌ |
| `nginx.ingress.kubernetes.io/canary-weight` *(doc)* | SPEC | `spec.alternateBackends` + `weight` | Canary pondéré uniquement. | N/A |

### 3.4 Timeouts

| Annotation nginx | Cible | Équivalent Route | Solution | Passthrough ? |
|---|---|---|---|---|
| `nginx.ingress.kubernetes.io/proxy-read-timeout` | ANN | `haproxy.router.openshift.io/timeout` | Couvre les principaux timeouts HAProxy (connexion inactive, serveur…) ; ce n'est pas un mapping 1:1 par type de timeout. | ✅ |
| `nginx.ingress.kubernetes.io/proxy-send-timeout` | ANN | `haproxy.router.openshift.io/timeout` | Même annotation que `proxy-read-timeout` (timeout HAProxy global). | ✅ |
| `nginx.ingress.kubernetes.io/proxy-connect-timeout` | IC / SIDECAR | — | `IngressController.spec.tuningOptions` (global) ou sidecar. | N/A |

### 3.5 Buffers, tailles de body & buffering

| Annotation nginx | Cible | Équivalent Route | Solution | Passthrough ? |
|---|---|---|---|---|
| `nginx.ingress.kubernetes.io/proxy-body-size` | SIDECAR | — | La Route ne fournit pas de mécanisme équivalent pour limiter la taille des requêtes HTTP. Si une limite est nécessaire, l'appliquer au sidecar (`client_max_body_size`). Rappel : `0` = illimité côté nginx (pas un blocage). | N/A |
| `nginx.ingress.kubernetes.io/client-max-body-size` | SIDECAR | — | Idem → `client_max_body_size` au sidecar. | N/A |
| `nginx.ingress.kubernetes.io/client-body-buffer-size` | SIDECAR | — | Buffering au sidecar. | N/A |
| `nginx.ingress.kubernetes.io/client-header-buffer-size` | IC / SIDECAR | — | `IngressController.spec.tuningOptions.headerBufferBytes` (global) ou sidecar. | N/A |
| `nginx.ingress.kubernetes.io/large-client-header-buffers` | IC / SIDECAR | — | `tuningOptions.headerBufferMaxRewriteBytes` / `headerBufferBytes` ou sidecar. | N/A |
| `nginx.ingress.kubernetes.io/http2-max-header-size` | IC / SIDECAR | — | Tuning IngressController ou sidecar. | N/A |
| `nginx.ingress.kubernetes.io/proxy-buffer-size` | SIDECAR | — | `proxy_buffer_size` au sidecar. | N/A |
| `nginx.ingress.kubernetes.io/proxy-buffers` | SIDECAR | — | `proxy_buffers` au sidecar. | N/A |
| `nginx.ingress.kubernetes.io/proxy-buffers-number` | SIDECAR | — | `proxy_buffers` au sidecar. | N/A |
| `nginx.ingress.kubernetes.io/proxy-max-temp-file-size` | SIDECAR | — | `proxy_max_temp_file_size` au sidecar. | N/A |
| `nginx.ingress.kubernetes.io/proxy-buffering` | SIDECAR | — | `proxy_buffering on/off` au sidecar. | N/A |
| `nginx.ingress.kubernetes.io/proxy-request-buffering` | SIDECAR | — | `proxy_request_buffering on/off` au sidecar. | N/A |

### 3.6 Headers

| Annotation nginx | Cible | Équivalent Route | Solution | Passthrough ? |
|---|---|---|---|---|
| `nginx.ingress.kubernetes.io/use-forwarded-headers` | ANN | `haproxy.router.openshift.io/set-forwarded-headers` | Valeurs : append / replace / never / if-none. | ❌ |
| `nginx.ingress.kubernetes.io/proxy_hide_header` | SPEC / SIDECAR | `spec.httpHeaders.actions.response` (type `Delete`) | OCP ≥ 4.13 ; nécessite le champ `spec.httpHeaders`, indisponible sur les versions antérieures. Sinon suppression au sidecar. | ❌ |

> Pose / modification de headers génériques *(OCP ≥ 4.13, champ `spec.httpHeaders`)* : `spec.httpHeaders.actions` (Set / Delete, requête & réponse).

### 3.7 CORS

| Annotation nginx | Cible | Équivalent Route | Solution | Passthrough ? |
|---|---|---|---|---|
| `nginx.ingress.kubernetes.io/enable-cors` | SIDECAR | — | Pas de CORS natif Route → gestion au sidecar (headers `Access-Control-*` + réponse aux `OPTIONS`) ou app/gateway. | N/A |
| `nginx.ingress.kubernetes.io/cors-allow-origin` | SIDECAR | — | → sidecar. | N/A |
| `nginx.ingress.kubernetes.io/cors-allow-headers` | SIDECAR | — | → sidecar. | N/A |
| `nginx.ingress.kubernetes.io/cors-allow-methods` | SIDECAR | — | → sidecar. | N/A |
| `nginx.ingress.kubernetes.io/cors-allow-credentials` | SIDECAR | — | → sidecar. | N/A |

### 3.8 Snippets & divers

| Annotation nginx | Cible | Équivalent Route | Solution | Passthrough ? |
|---|---|---|---|---|
| `nginx.ingress.kubernetes.io/configuration-snippet` | SIDECAR | — | Aucune injection HAProxy per-route → reprendre le snippet tel quel dans la conf nginx du sidecar. Marqueur fort que la Route seule ne suffit pas. | N/A |
| `nginx.ingress.kubernetes.io/server-snippet` | SIDECAR | — | → sidecar. | N/A |
| `nginx.ingress.kubernetes.io/enable-rewrite-log` | IC / SIDECAR | — | Logs d'accès IngressController ou sidecar. | N/A |

---

## 4. Synthèse — annotations sans équivalent Route

Trois destinations possibles quand la Route ne couvre pas :

1. **Sidecar nginx** (le plus fréquent, cohérent avec le pattern cible) : regex/path, CORS, snippets, buffering, tailles de body/headers, timeouts fins, SNI upstream, app-root, cookie expires/max-age.
2. **IngressController (global, à arbitrer avec la plateforme)** : versions/ciphers TLS (`tlsSecurityProfile`), buffers de headers (`tuningOptions`), HTTP/2, mTLS client (`clientTLS`), timeouts globaux.
3. **spec.* de la Route** : redirection HTTP→HTTPS, path, canary pondéré (`alternateBackends`), manipulation de headers (`httpHeaders.actions`, OCP ≥ 4.13), vérif backend (`destinationCACertificate`).

> Règle pratique : si une annotation tombe en catégorie *IngressController*, elle est **globale** (impacte tous les Routes du contrôleur) → préférer le **sidecar** pour tout ce qui est spécifique à une application.

**En pratique, la majorité des annotations nginx se répartissent entre deux catégories :**

- fonctionnalités **L7 spécifiques à une application** → **sidecar nginx** ;
- fonctionnalités de **terminaison TLS ou de routage** → **Route OpenShift**.

---

## 5. Exemples de Route cible

### 5.1 Route reencrypt avec sticky session (cas standard)

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ap26330-api-contract
  annotations:
    haproxy.router.openshift.io/disable_cookies: "false"   # sticky session ON
    router.openshift.io/cookie_name: "nts-cookie"
    router.openshift.io/cookie-same-site: "Strict"
    haproxy.router.openshift.io/rewrite-target: /
    haproxy.router.openshift.io/timeout: 30s
    haproxy.router.openshift.io/set-forwarded-headers: append
spec:
  host: api-contract.apps.<cluster>.roks
  path: /api/contract                 # matching PRÉFIXE (pas de regex)
  to:
    kind: Service
    name: api-contract
    weight: 100
  port:
    targetPort: 8443
  tls:
    termination: reencrypt
    # CA ayant signé le certificat présenté par le backend (sidecar nginx)
    destinationCACertificate: |-
      -----BEGIN CERTIFICATE-----
      <CA du sidecar>
      -----END CERTIFICATE-----
    insecureEdgeTerminationPolicy: Redirect   # reproduit ssl-redirect / force-ssl-redirect
```

### 5.2 Canary / trafic pondéré (`canary` + `canary-weight`)

```yaml
spec:
  to:
    kind: Service
    name: api-v1
    weight: 90
  alternateBackends:
    - kind: Service
      name: api-v2
      weight: 10
# NB : uniquement du pondéré. Le canary par header/cookie n'a pas d'équivalent Route.
```

### 5.3 Suppression de header (`proxy_hide_header`, OCP ≥ 4.13)

```yaml
spec:
  httpHeaders:
    actions:
      response:
        - name: Server
          action:
            type: Delete
```

### 5.4 Passthrough (uniquement si aucun besoin L7)

```yaml
spec:
  tls:
    termination: passthrough        # le routeur ne déchiffre pas le trafic : pas de cookie, de rewrite, de manipulation de headers ni de routage HTTP (l'hôte/SNI reste visible)
  port:
    targetPort: 8443
```

---

## 6. Points de vigilance migration

- **Validation TLS du backend en `reencrypt`** : le routeur valide le certificat présenté par le backend. Trois éléments doivent être cohérents entre eux : **le certificat présenté** par le backend, **sa CA de signature** (référencée dans `destinationCACertificate`) et **le nom utilisé lors de la connexion TLS (SNI)**. Toute incohérence entre ces trois entraîne un échec de handshake.
- **`ssl-redirect` / `insecureEdgeTerminationPolicy`** : le comportement par défaut n'est pas garanti à `Redirect` (souvent `None`). Le configurer **explicitement** pour reproduire le forçage HTTPS.
- **`proxy-body-size: 0`** = illimité côté nginx (pas un bug). La Route n'offre pas de limite équivalente ; cap éventuel → sidecar (`client_max_body_size`), utile contre les payloads massifs.
- **`ssl-passthrough=true` + fonctionnalité L7** (affinity, rewrite, multipath, snippet…) : incohérence → la Route doit basculer en **reencrypt** (branche « OUI » de l'arbre).
- **Regex de path** (`use-regex`, patterns `api/*`) : non portables sur Route → sidecar.
- **Config globale vs par app** : préférer le sidecar aux réglages IngressController pour ne pas **impacter les autres applications / workloads** partageant le contrôleur.

---

## 7. Références

- Table 2 — *Correlation between IKS Ingress annotations and Route ROKS configurations* (page Confluence interne).
- Table 3 — *ROKS Route-specific annotations* (page Confluence interne).
- Documentation OpenShift : *Route configuration* / *Route-specific annotations* (`haproxy.router.openshift.io/*`, `router.openshift.io/*`), *IngressController tuningOptions*, *HTTP header actions* (`spec.httpHeaders.actions`).
