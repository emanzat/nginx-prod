# Architecture TLS Reencrypt — Vault PKI & Certificate Lifecycle

|Champ             |Valeur                                                       |
|------------------|-------------------------------------------------------------|
|Type              |Runbook ITOps — Guide d’implémentation pas à pas             |
|Public cible      |Équipes ITOps / SRE / Plateforme OpenShift                   |
|Pré-requis lecteur|Connaissance OpenShift (`oc`), Helm, HashiCorp Vault, TLS/PKI|
|Auteur            |Équipe Architecture Cloud Native                             |
|Version           |1.0                                                          |

**💡 Astuce Confluence :** après collage, ajoute la macro `/toc` en haut de page pour une table des matières auto-générée à partir des titres.

-----

## Sommaire

1. Vue d’ensemble
1. Prérequis
1. Étape 1 — Sidecar Nginx & Init Container (Pod Cert)
1. Étape 2 — CronJob `issue-route-cert` (Route + Cert)
1. Étape 3 — CronJob `pod-cert-renewal` (Auto-renouvellement)
1. Étape 4 — Vérification, tests & rollback
1. Annexe A — RBAC complet
1. Annexe B — Troubleshooting

-----

## 1. Vue d’ensemble

### 1.1 Objectif

Mettre en place une terminaison **TLS Reencrypt** sur OpenShift, avec :

- **Route OpenShift** en mode `reencrypt` (TLS de bout en bout, F5 → Route → Pod)
- **Sidecar Nginx** dans le pod, qui termine le TLS côté backend (port 8443) et reverse-proxy en clair vers le container applicatif (`localhost:8080`)
- **HashiCorp Vault PKI Secrets Engine** comme autorité d’émission des certificats (route + pod)
- **Init Container** pour récupérer le certificat pod au démarrage
- **CronJob** pour créer/mettre à jour la route reencrypt avec son propre certificat
- **CronJob d’auto-renouvellement** quotidien (2h00) déclenchant un `oc rollout restart` 30 jours avant expiration

### 1.2 Choix d’architecture clés

|Décision                                      |Justification                                                                                                                           |
|----------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------|
|**emptyDir { medium: Memory }**               |Le certificat n’est jamais persisté sur disque. Volatile, lié au cycle de vie du pod.                                                   |
|**Init Container**                            |Le sidecar Nginx ne démarre qu’une fois le cert disponible (dépendance ordonnée).                                                       |
|**CronJob `issue-route-cert`**                |Évite de stocker le cert de route dans un Secret Kubernetes. La route est recréée avec un cert frais à chaque renouvellement.           |
|**CronJob `pod-cert-renewal`**                |Découple le cycle de vie du cert pod du cycle de déploiement applicatif. `oc rollout restart` force la ré-exécution de l’init container.|
|**Vault PKI comme unique source de confiance**|Centralisation banque-wide, audit Vault, rotation des CAs intermédiaires gérée côté Vault. Pas de CRD tiers à maintenir dans le cluster.|

-----

## 2. Prérequis

### 2.1 Côté Vault

- [ ] PKI Secrets Engine activé sur le path `pki_int/` (intermediate CA)
- [ ] Rôles Vault créés :
  - `pod-cert-role` : `allowed_domains=svc.cluster.local`, `allow_subdomains=true`, `max_ttl=2160h` (90 jours)
  - `route-cert-role` : `allowed_domains=apps.<cluster-domain>`, `max_ttl=8760h` (1 an)
- [ ] Méthode d’authentification Kubernetes activée (`auth/kubernetes`) avec policy associée

### 2.2 Côté OpenShift

- [ ] Namespace cible créé (ex. `my-ns`)
- [ ] ServiceAccount applicatif lié à un rôle Vault
- [ ] ServiceAccount `cert-lifecycle-sa` pour les CronJobs (RBAC en Annexe A)
- [ ] Image `vault-agent` ou script wrapper `vault-get-cert` disponible dans Harbor / registry interne

### 2.3 Variables à personnaliser

Avant tout déploiement, remplacer dans tous les manifestes :

|Variable            |Exemple                         |Description              |
|--------------------|--------------------------------|-------------------------|
|`<NAMESPACE>`       |`my-ns`                         |Namespace cible          |
|`<APP_NAME>`        |`my-ms`                         |Nom de l’application     |
|`<SERVICE_NAME>`    |`my-svc`                        |Nom du Service Kubernetes|
|`<ROUTE_HOST>`      |`my-app.apps.<cluster-domain>`  |Hostname public          |
|`<VAULT_ADDR>`      |`https://vault.example.com:8200`|URL Vault                |
|`<VAULT_PKI_PATH>`  |`pki_int`                       |Path du moteur PKI       |
|`<VAULT_POD_ROLE>`  |`pod-cert-role`                 |Rôle Vault pour le pod   |
|`<VAULT_ROUTE_ROLE>`|`route-cert-role`               |Rôle Vault pour la route |

-----

## 3. Étape 1 — Sidecar Nginx & Init Container (Pod Cert)

### 3.1 Objectif

Modifier le `Deployment` (ou `StatefulSet`) applicatif pour :

1. Ajouter un **init container** `vault-get-pod-cert` qui récupère le certificat depuis Vault et l’écrit dans un volume `emptyDir` mémoire
1. Ajouter un **sidecar Nginx** qui termine le TLS sur le port 8443 et proxy vers le container applicatif (`localhost:8080`)
1. Ajouter le volume `emptyDir { medium: Memory }` partagé entre l’init container et le sidecar

### 3.2 ConfigMap : `nginx.conf` du sidecar

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-sidecar-config
  namespace: <NAMESPACE>
data:
  nginx.conf: |
    worker_processes 1;
    events { worker_connections 1024; }
    http {
      server {
        listen 8443 ssl http2;
        server_name _;

        ssl_certificate     /etc/nginx/tls/tls.crt;
        ssl_certificate_key /etc/nginx/tls/tls.key;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;

        location / {
          proxy_pass         http://localhost:8080;
          proxy_set_header   Host              $host;
          proxy_set_header   X-Real-IP         $remote_addr;
          proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
          proxy_set_header   X-Forwarded-Proto https;
        }

        # Endpoint health check côté sidecar
        location /healthz {
          access_log off;
          return 200 "ok\n";
        }
      }
    }
```

### 3.3 Patch `Deployment` / `StatefulSet`

À ajouter dans `spec.template.spec` du Deployment existant :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <APP_NAME>
  namespace: <NAMESPACE>
spec:
  replicas: 2
  selector:
    matchLabels:
      app: <APP_NAME>
  template:
    metadata:
      labels:
        app: <APP_NAME>
    spec:
      serviceAccountName: <APP_NAME>-sa   # Doit être lié au rôle Vault pod-cert-role

      # ────────────────────────────────────────────
      # Init Container : récupération du cert pod
      # ────────────────────────────────────────────
      initContainers:
      - name: vault-get-pod-cert
        image: <REGISTRY>/platform/vault-agent:1.15
        env:
        - name: VAULT_ADDR
          value: "<VAULT_ADDR>"
        - name: VAULT_ROLE
          value: "<VAULT_POD_ROLE>"
        - name: COMMON_NAME
          value: "<SERVICE_NAME>.<NAMESPACE>.svc.cluster.local"
        - name: ALT_NAMES
          value: "<SERVICE_NAME>,<SERVICE_NAME>.<NAMESPACE>,<SERVICE_NAME>.<NAMESPACE>.svc"
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -euo pipefail
          # Auth K8s → token Vault
          VAULT_TOKEN=$(vault write -field=token \
            auth/kubernetes/login \
            role=${VAULT_ROLE} \
            jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
          export VAULT_TOKEN

          # Issue cert
          vault write -format=json <VAULT_PKI_PATH>/issue/${VAULT_ROLE} \
            common_name="${COMMON_NAME}" \
            alt_names="${ALT_NAMES}" \
            ttl="2160h" > /tmp/cert.json

          jq -r '.data.certificate'      /tmp/cert.json > /etc/nginx/tls/tls.crt
          jq -r '.data.private_key'      /tmp/cert.json > /etc/nginx/tls/tls.key
          jq -r '.data.issuing_ca'       /tmp/cert.json > /etc/nginx/tls/ca.crt
          chmod 0400 /etc/nginx/tls/tls.key
        volumeMounts:
        - name: tls-certs
          mountPath: /etc/nginx/tls
        securityContext:
          runAsNonRoot: true
          runAsUser: 1001
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: true

      containers:
      # ────────────────────────────────────────────
      # Container Applicatif (HTTP localhost:8080)
      # ────────────────────────────────────────────
      - name: app
        image: <REGISTRY>/<APP_NAME>:1.0.0
        ports:
        - containerPort: 8080
          name: http
        # ... reste de la config applicative

      # ────────────────────────────────────────────
      # Sidecar Nginx : terminaison TLS 8443
      # ────────────────────────────────────────────
      - name: nginx-tls
        image: <REGISTRY>/platform/nginx:1.25-alpine
        ports:
        - containerPort: 8443
          name: https
        volumeMounts:
        - name: tls-certs
          mountPath: /etc/nginx/tls
          readOnly: true
        - name: nginx-config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
          readOnly: true
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8443
            scheme: HTTPS
          initialDelaySeconds: 5
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8443
            scheme: HTTPS
          initialDelaySeconds: 2
          periodSeconds: 5
        securityContext:
          runAsNonRoot: true
          runAsUser: 101         # nginx user
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
            add:  ["NET_BIND_SERVICE"]
          readOnlyRootFilesystem: true

      volumes:
      - name: tls-certs
        emptyDir:
          medium: Memory          # ⚠️ Pas de persistance disque
          sizeLimit: 1Mi
      - name: nginx-config
        configMap:
          name: nginx-sidecar-config
```

### 3.4 Service exposé sur 8443

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <SERVICE_NAME>
  namespace: <NAMESPACE>
spec:
  selector:
    app: <APP_NAME>
  ports:
  - name: https
    port: 8443
    targetPort: 8443
    protocol: TCP
```

### 3.5 Vérification de l’étape 1

```bash
# 1. Le pod démarre et l'init container termine OK
oc -n <NAMESPACE> get pods -l app=<APP_NAME>
oc -n <NAMESPACE> logs <pod> -c vault-get-pod-cert

# 2. Le cert est bien présent dans le volume mémoire
oc -n <NAMESPACE> exec <pod> -c nginx-tls -- ls -l /etc/nginx/tls/

# 3. Le sidecar répond en TLS
oc -n <NAMESPACE> exec <pod> -c nginx-tls -- \
  wget -qO- --no-check-certificate https://localhost:8443/healthz

# 4. Inspection du cert servi
oc -n <NAMESPACE> port-forward <pod> 8443:8443 &
openssl s_client -connect localhost:8443 -showcerts < /dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

**✅ Critère de sortie :** Le pod est `Running` et `Ready`, le sidecar Nginx sert un cert valide signé par la CA Vault.

-----

## 4. Étape 2 — CronJob `issue-route-cert` (Route + Cert)

### 4.1 Objectif

Créer un **CronJob** qui, à intervalle défini :

1. Récupère un certificat de route depuis Vault PKI
1. Récupère la CA pod (depuis le pod ou Vault) pour le champ `destinationCACert`
1. Crée ou met à jour la **Route OpenShift** en mode `reencrypt` via la commande `oc create route reencrypt`

### 4.2 Stratégie

- **Fréquence :** hebdomadaire (`0 3 * * 0`, dimanche 3h00) — le cert route a un TTL d’1 an, on peut renouveler tous les mois sans risque
- **Idempotence :** `oc delete route` puis `oc create route` (ou `oc apply` avec template), pour repartir d’un cert frais

### 4.3 Manifeste CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: issue-route-cert
  namespace: <NAMESPACE>
spec:
  schedule: "0 3 * * 0"          # Dimanche 03h00
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          serviceAccountName: cert-lifecycle-sa
          restartPolicy: OnFailure

          # ────────────────────────────────────────
          # Init container : récupération cert route
          # ────────────────────────────────────────
          initContainers:
          - name: vault-get-route-cert
            image: <REGISTRY>/platform/vault-agent:1.15
            env:
            - name: VAULT_ADDR
              value: "<VAULT_ADDR>"
            - name: VAULT_ROLE
              value: "<VAULT_ROUTE_ROLE>"
            - name: ROUTE_HOST
              value: "<ROUTE_HOST>"
            command: ["/bin/sh", "-c"]
            args:
            - |
              set -euo pipefail
              VAULT_TOKEN=$(vault write -field=token \
                auth/kubernetes/login \
                role=${VAULT_ROLE} \
                jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token))
              export VAULT_TOKEN

              vault write -format=json <VAULT_PKI_PATH>/issue/${VAULT_ROLE} \
                common_name="${ROUTE_HOST}" \
                ttl="8760h" > /tmp/cert.json

              jq -r '.data.certificate' /tmp/cert.json > /etc/route/tls/tls.crt
              jq -r '.data.private_key' /tmp/cert.json > /etc/route/tls/tls.key
              jq -r '.data.issuing_ca'  /tmp/cert.json > /etc/route/tls/ca.crt
            volumeMounts:
            - name: route-tls
              mountPath: /etc/route/tls

          # ────────────────────────────────────────
          # Container : création / mise à jour route
          # ────────────────────────────────────────
          containers:
          - name: create-reencrypt-route
            image: <REGISTRY>/platform/openshift-cli:4.14
            env:
            - name: ROUTE_HOST
              value: "<ROUTE_HOST>"
            - name: SERVICE_NAME
              value: "<SERVICE_NAME>"
            command: ["/bin/sh", "-c"]
            args:
            - |
              set -euo pipefail

              # Récupération de la CA pod (présente sur le service via DNS interne)
              # ou directement depuis Vault si le pod ne l'expose pas
              echo | openssl s_client -showcerts \
                -connect ${SERVICE_NAME}.<NAMESPACE>.svc.cluster.local:8443 2>/dev/null \
                | openssl x509 -outform PEM > /etc/route/tls/dest-ca.crt

              # Suppression de la route existante (idempotence)
              oc -n <NAMESPACE> delete route <APP_NAME> --ignore-not-found=true

              # Création de la route reencrypt
              oc -n <NAMESPACE> create route reencrypt <APP_NAME> \
                --hostname="${ROUTE_HOST}" \
                --service="${SERVICE_NAME}" \
                --port=8443 \
                --cert=/etc/route/tls/tls.crt \
                --key=/etc/route/tls/tls.key \
                --ca-cert=/etc/route/tls/ca.crt \
                --dest-ca-cert=/etc/route/tls/dest-ca.crt
            volumeMounts:
            - name: route-tls
              mountPath: /etc/route/tls
              readOnly: true

          volumes:
          - name: route-tls
            emptyDir:
              medium: Memory
              sizeLimit: 1Mi
```

### 4.4 Vérification de l’étape 2

```bash
# 1. Lancer le CronJob manuellement
oc -n <NAMESPACE> create job --from=cronjob/issue-route-cert issue-route-cert-manual-1

# 2. Suivre les logs
oc -n <NAMESPACE> logs -f job/issue-route-cert-manual-1

# 3. La route est créée
oc -n <NAMESPACE> get route <APP_NAME> -o yaml | grep -E "termination|host"

# 4. Test bout-en-bout via l'URL publique
curl -v https://<ROUTE_HOST>/healthz
```

**✅ Critère de sortie :** La route est en `termination: reencrypt`, accessible publiquement, et le cert présenté est bien le cert route Vault (vérifier l’issuer).

-----

## 5. Étape 3 — CronJob `pod-cert-renewal` (Auto-renouvellement)

### 5.1 Objectif

Vérifier quotidiennement (à 2h00) si le certificat servi par le sidecar expire dans moins de **30 jours**. Si oui, déclencher un `oc rollout restart` qui force la ré-exécution de l’init container et donc l’émission d’un nouveau cert.

### 5.2 Logique du script

```text
1. openssl s_client -connect <SERVICE_NAME>.<NAMESPACE>:8443 → récupère le cert
2. openssl x509 -checkend 2592000   (2 592 000 s = 30 jours)
3. SI expirant      → oc rollout restart deploy/<APP_NAME>
   SINON           → exit 0
```

**⚠️ Note :** Le diagramme initial mentionne `-checkend 604800` (7 jours) avec un libellé “30 days before expiry”. On retient **2 592 000 s = 30 jours** pour laisser une marge de sécurité confortable.

### 5.3 Manifeste CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pod-cert-renewal
  namespace: <NAMESPACE>
spec:
  schedule: "0 2 * * *"          # Tous les jours à 02h00
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          serviceAccountName: cert-lifecycle-sa
          restartPolicy: OnFailure
          containers:
          - name: cert-checker
            image: <REGISTRY>/platform/openshift-cli:4.14
            env:
            - name: APP_NAME
              value: "<APP_NAME>"
            - name: SERVICE_NAME
              value: "<SERVICE_NAME>"
            - name: NAMESPACE
              value: "<NAMESPACE>"
            - name: RENEW_BEFORE_SECONDS
              value: "2592000"     # 30 jours
            command: ["/bin/sh", "-c"]
            args:
            - |
              set -euo pipefail

              echo "[$(date -Iseconds)] Vérification cert ${SERVICE_NAME}.${NAMESPACE}:8443"

              # 1. Récupération du cert servi par le sidecar
              echo | openssl s_client \
                -connect ${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local:8443 \
                -showcerts 2>/dev/null \
                | openssl x509 -outform PEM > /tmp/current-cert.pem

              # 2. Vérification expiration
              if openssl x509 -in /tmp/current-cert.pem \
                   -checkend ${RENEW_BEFORE_SECONDS} -noout; then
                echo "[OK] Cert valide pour plus de $((RENEW_BEFORE_SECONDS/86400)) jours."
                exit 0
              fi

              # 3. Cert expirant → rollout restart
              echo "[ACTION] Cert expirant dans moins de $((RENEW_BEFORE_SECONDS/86400)) jours."
              echo "[ACTION] Déclenchement: oc rollout restart deploy/${APP_NAME}"
              oc -n ${NAMESPACE} rollout restart deploy/${APP_NAME}

              # 4. Attente de la fin du rollout
              oc -n ${NAMESPACE} rollout status deploy/${APP_NAME} --timeout=10m
              echo "[OK] Rollout terminé. Nouveau cert servi."
```

### 5.4 Vérification de l’étape 3

```bash
# Forcer une exécution manuelle pour valider
oc -n <NAMESPACE> create job --from=cronjob/pod-cert-renewal pod-cert-renewal-test-1
oc -n <NAMESPACE> logs -f job/pod-cert-renewal-test-1

# Simuler une expiration : émettre un cert avec un TTL très court depuis Vault
# puis observer le déclenchement du rollout au prochain run
```

**✅ Critère de sortie :** Le job s’exécute en succès quotidiennement. En cas de cert expirant, le `rollout restart` se déclenche et un nouveau cert est servi.

-----

## 6. Étape 4 — Vérification, tests & rollback

### 6.1 Tests fonctionnels (smoke tests)

|#|Test                   |Commande                                                       |Résultat attendu            |
|-|-----------------------|---------------------------------------------------------------|----------------------------|
|1|Pod ready              |`oc get pods -l app=<APP_NAME>`                                |`2/2 Running`               |
|2|Cert sidecar valide    |`openssl s_client -connect <SERVICE_NAME>:8443`                |`Verify return code: 0 (ok)`|
|3|Route accessible       |`curl https://<ROUTE_HOST>/healthz`                            |`HTTP/2 200`                |
|4|Termination = reencrypt|`oc get route <APP_NAME> -o jsonpath='{.spec.tls.termination}'`|`reencrypt`                 |
|5|CronJob route OK       |`oc get jobs -l cronjob=issue-route-cert`                      |Status `Complete`           |
|6|CronJob renewal OK     |`oc get jobs -l cronjob=pod-cert-renewal`                      |Status `Complete`           |

### 6.2 Test de renouvellement forcé

```bash
# Émettre un cert avec TTL court depuis Vault (test uniquement) puis :
oc -n <NAMESPACE> create job --from=cronjob/pod-cert-renewal pod-cert-renewal-force-1
# → doit déclencher un rollout restart visible dans l'historique
oc -n <NAMESPACE> rollout history deploy/<APP_NAME>
```

### 6.3 Procédure de rollback

En cas d’incident bloquant :

```bash
# 1. Restaurer le Deployment précédent (sans sidecar)
oc -n <NAMESPACE> rollout undo deploy/<APP_NAME>

# 2. Suspendre les CronJobs
oc -n <NAMESPACE> patch cronjob/issue-route-cert  -p '{"spec":{"suspend":true}}'
oc -n <NAMESPACE> patch cronjob/pod-cert-renewal  -p '{"spec":{"suspend":true}}'

# 3. Restaurer la route en mode edge ou passthrough (selon configuration cible de fallback)
oc -n <NAMESPACE> apply -f rollback/route-edge.yaml
```

-----

## Annexe A — RBAC complet

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cert-lifecycle-sa
  namespace: <NAMESPACE>
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cert-lifecycle-role
  namespace: <NAMESPACE>
rules:
# Gestion des routes
- apiGroups: ["route.openshift.io"]
  resources: ["routes", "routes/custom-host"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
# Rollout deployments
- apiGroups: ["apps"]
  resources: ["deployments", "deployments/scale"]
  verbs: ["get", "list", "patch", "update"]
# Lecture pods (debug + checks)
- apiGroups: [""]
  resources: ["pods", "services", "endpoints"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cert-lifecycle-rb
  namespace: <NAMESPACE>
subjects:
- kind: ServiceAccount
  name: cert-lifecycle-sa
  namespace: <NAMESPACE>
roleRef:
  kind: Role
  name: cert-lifecycle-role
  apiGroup: rbac.authorization.k8s.io
```

**💡 Note RBAC :** la sous-ressource `routes/custom-host` est requise pour pouvoir spécifier `--hostname` lors de la création d’une route en mode reencrypt sur OpenShift.

-----

## Annexe B — Troubleshooting

|Symptôme                                                           |Cause probable                                                               |Action                                                                          |
|-------------------------------------------------------------------|-----------------------------------------------------------------------------|--------------------------------------------------------------------------------|
|Init container `vault-get-pod-cert` en `CrashLoopBackOff`          |SA non bindé au rôle Vault, ou path PKI incorrect                            |`oc logs <pod> -c vault-get-pod-cert` ; vérifier `vault token lookup` côté Vault|
|Sidecar Nginx ne démarre pas (`SSL_CTX_use_PrivateKey_file failed`)|Cert ou clé absent du volume `emptyDir`                                      |Vérifier `ls /etc/nginx/tls/` dans le sidecar ; relire les logs init container  |
|Route en `503`                                                     |`destinationCACert` ne correspond pas à la CA qui a signé le cert pod        |Re-générer la route via le CronJob `issue-route-cert`                           |
|Route en `502`                                                     |Sidecar Nginx KO ou Service mal configuré                                    |Vérifier `readinessProbe` du sidecar, `oc describe svc <SERVICE_NAME>`          |
|CronJob `pod-cert-renewal` en `Forbidden`                          |Permission manquante sur `deployments`                                       |Vérifier le RBAC (Annexe A)                                                     |
|`x509: certificate signed by unknown authority` côté client        |CA intermédiaire Vault absente du `caCertificate` de la route                |Vérifier que `--ca-cert` est bien fourni au `oc create route`                   |
|`oc rollout restart` ne change pas le cert                         |Volume `emptyDir` réutilisé (improbable mais possible si HostPath par erreur)|Vérifier que le volume est bien `emptyDir { medium: Memory }`                   |

### Commandes de diagnostic rapide

```bash
# Inspection complète du cert servi par le sidecar
oc -n <NAMESPACE> exec <pod> -c nginx-tls -- \
  openssl x509 -in /etc/nginx/tls/tls.crt -noout -text | head -30

# Inspection du cert présenté par la route
echo | openssl s_client -servername <ROUTE_HOST> -connect <ROUTE_HOST>:443 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# Historique des jobs CronJob
oc -n <NAMESPACE> get jobs --sort-by=.status.startTime
```

-----

|Contact             |Équipe Architecture Cloud Native|
|--------------------|--------------------------------|
|Dernière mise à jour|Voir historique de la page      |
