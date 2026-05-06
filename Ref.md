# Guide de déploiement OpenShift / ROKS — IT RefCard Continuity & Resilience for Cloud

**Version** : 1.0 — basé sur **IT RefCard v1.0.6 (2023)** BNP Paribas Cardif
**Cible** : Cloud Native Architects, SRE, équipes Build & Run
**Périmètre** : applications conteneurisées sur cluster ROKS IBM Cloud (region eu-fr2 — Marne Nord / Marne Est, DR Bastogne)

-----

## 1. Contexte & objectif

L’IT RefCard définit pour chaque application **un niveau de continuité métier** (`Extreme`, `Serious`, `Moderate`, `Low`) qui se traduit par un ensemble de règles techniques **MUST** sur 5 axes :

|Axe                    |Question répondue                                                |
|-----------------------|-----------------------------------------------------------------|
|**Topology Deployment**|Combien d’AZ et de régions dois-je couvrir ?                     |
|**Active Mode**        |Mes instances sont-elles toutes actives, ou en standby ?         |
|**Data Distribution**  |Comment ma donnée est-elle répliquée (sync / near-sync / async) ?|
|**Backup**             |Combien de copies de sauvegarde, où ?                            |
|**Recover Mechanism**  |Qu’est-ce qui est obligatoire pour restaurer ?                   |


> ⚠️ **Point clé souvent mal compris** : la RefCard parle de **Near Sync** (≠ sync strict). Cela autorise un RPO de l’ordre de quelques millisecondes — ce n’est pas un RPO mathématiquement nul. Toute exigence métier “RPO=0 absolu” sort du cadre standard et nécessite une dérogation formelle.

## 2. Tableau de synthèse des 4 niveaux

|Niveau        |AZ Hosting|AZ Status |Local Failover|Local Data   |Regional Data|Local Backup|Local Rebuild|Local Restore|
|--------------|----------|----------|--------------|-------------|-------------|------------|-------------|-------------|
|🔴 **Extreme** |M:Three   |All Active|HA            |**Near Sync**|M:One        |M:Two       |**MUST**     |**MUST**     |
|🟠 **Serious** |M:Two     |All Active|HA            |Near Sync    |M:One        |M:Two       |MUST         |MUST         |
|🟡 **Moderate**|M:Two     |—         |Hot           |Async / Batch|M:One        |M:Two       |SHOULD       |MUST         |
|🟢 **Low**     |M:One     |—         |Cold          |Async / Batch|M:One        |M:Two       |COULD        |MUST         |

**Lecture** :

- Plus le niveau est élevé, plus la **résilience locale** (intra-région) augmente
- Le DR régional `M:One` reste constant — c’est le filet de sécurité minimum pour toutes les classes
- La différence Serious / Extreme tient surtout dans le **nombre d’AZ** (2 vs 3)
- La différence Moderate / Serious tient dans le **mode de réplication** (async vs near-sync) et le **failover** (hot standby vs all-active)

## 3. Décodage des modes critiques

### 3.1 Active Mode — All Active vs Hot vs Cold

|Mode          |Description                                                      |RTO typique  |Coût                     |
|--------------|-----------------------------------------------------------------|-------------|-------------------------|
|**All Active**|Toutes les instances reçoivent du trafic en permanence           |< 30 s (auto)|Élevé (N nodes en charge)|
|**Hot**       |1 instance principale + standby pré-provisionné, prête à recevoir|1–5 min      |Moyen                    |
|**Cold**      |Instance secondaire à reprovisionner depuis backup               |30 min – 4 h |Bas                      |

### 3.2 Data Distribution — Near Sync décrypté

PostgreSQL est l’exemple canonique :

|Mode RefCard                    |Config PostgreSQL                                |RPO réel              |Latence commit ajoutée            |
|--------------------------------|-------------------------------------------------|----------------------|----------------------------------|
|**Sync strict** (hors RefCard)  |`synchronous_commit = remote_apply`              |0 strict              |RTT × 2 + fsync distant (~3–10 ms)|
|**Near Sync** (Extreme/Serious) |`synchronous_commit = on` ou `remote_write`      |ms (perte non flushée)|~1–2 ms                           |
|**Async / Batch** (Moderate/Low)|`synchronous_commit = off` ou réplication logique|secondes à minutes    |~0 ms                             |

## 4. Niveau 🔴 Extreme — Manifestes complets

**Cas d’usage** : flux paiement temps réel, souscription en ligne, services réglementaires DORA pilier 1.

### 4.1 Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: app-extreme-prod
  labels:
    bnpp.cardif/icp-classification: "extreme"
    bnpp.cardif/refcard-version: "1.0.6"
    pod-security.kubernetes.io/enforce: restricted
  annotations:
    bnpp.cardif/rpo-target: "near-sync (~ms)"
    bnpp.cardif/rto-target: "ha-automatic (<30s)"
```

### 4.2 Deployment — 9 réplicas (3 par AZ), All Active, HA

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-extreme
  namespace: app-extreme-prod
spec:
  # 9 réplicas = 3 par AZ (M:Three + redondance intra-AZ)
  replicas: 9

  # Zero-downtime strict : on ne descend jamais sous le nominal
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0

  selector:
    matchLabels:
      app: app-extreme

  template:
    metadata:
      labels:
        app: app-extreme
    spec:
      serviceAccountName: app-extreme-sa
      terminationGracePeriodSeconds: 60

      # === M:Three All Active — répartition stricte sur 3 AZ ===
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule   # ⚠ strict pour Extreme
          labelSelector:
            matchLabels:
              app: app-extreme
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: app-extreme

      # === Anti-affinity : jamais 2 pods sur le même node ===
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: app-extreme
              topologyKey: kubernetes.io/hostname

      # === Sécurité Pod (Ring 2) ===
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        fsGroup: 1001
        seccompProfile:
          type: RuntimeDefault

      containers:
        - name: app
          image: registry.bnpp.cardif/cardif/app-extreme:1.0.0
          ports:
            - { name: https, containerPort: 8443 }
            - { name: management, containerPort: 8081 }

          # === QoS Guaranteed — anti-eviction ===
          resources:
            requests: { cpu: "1000m", memory: "2Gi" }
            limits:   { cpu: "1000m", memory: "2Gi" }

          # === Probes complètes — séparation liveness/readiness ===
          startupProbe:
            httpGet: { path: /actuator/health/liveness, port: management }
            failureThreshold: 30
            periodSeconds: 3
          livenessProbe:
            httpGet: { path: /actuator/health/liveness, port: management }
            periodSeconds: 10
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: /actuator/health/readiness, port: management }
            periodSeconds: 5
            failureThreshold: 2

          # === Drain HTTP propre (15s laisse au LB le temps de désinscrire) ===
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: ["ALL"] }
```

### 4.3 PodDisruptionBudget — perte d’1 AZ tolérée

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: app-extreme-pdb
  namespace: app-extreme-prod
spec:
  # 9 pods - 3 (perte d'1 AZ) = 6 pods minimum garantis
  minAvailable: 6
  selector:
    matchLabels:
      app: app-extreme
```

### 4.4 PostgreSQL — Near Sync via CloudNativePG

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: db-extreme
  namespace: app-extreme-prod
spec:
  instances: 3   # 1 primary + 2 standby (1 par AZ)

  # === Réplication synchrone quorum-based — Near Sync RefCard ===
  postgresql:
    parameters:
      synchronous_commit: "on"        # remote_write par défaut, pas remote_apply
      max_wal_senders: "10"
      wal_level: "replica"
      hot_standby: "on"

  # Quorum sync : confirmation après réception WAL par 1 standby AZ distinct
  minSyncReplicas: 1
  maxSyncReplicas: 1

  # === Spread topologique — 1 instance par AZ ===
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          cnpg.io/cluster: db-extreme

  # === Backup M:Two — IBM COS + snapshots CSI ===
  backup:
    retentionPolicy: "30d"
    barmanObjectStore:
      destinationPath: "s3://backup-cos-marne-est/db-extreme"
      s3Credentials:
        accessKeyId:
          name: cos-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: cos-creds
          key: SECRET_ACCESS_KEY
      wal:
        compression: gzip
        maxParallel: 4
      data:
        compression: gzip

  # === Réplication régionale M:One vers Bastogne ===
  replica:
    enabled: false   # le cluster Bastogne fait `bootstrap.pgBaseBackup` depuis ce cluster
```

### 4.5 Service & Route

```yaml
apiVersion: v1
kind: Service
metadata:
  name: app-extreme
  namespace: app-extreme-prod
spec:
  selector:
    app: app-extreme
  ports:
    - name: https
      port: 443
      targetPort: 8443
  # Fast-detect des pods morts par le ALB
  publishNotReadyAddresses: false
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: app-extreme
  namespace: app-extreme-prod
  annotations:
    haproxy.router.openshift.io/balance: leastconn
    haproxy.router.openshift.io/timeout: 30s
spec:
  host: app-extreme.cardif.bnpp
  to:
    kind: Service
    name: app-extreme
  tls:
    termination: reencrypt   # TLS bout-en-bout via Vault PKI
  port:
    targetPort: https
```

### 4.6 NetworkPolicy default-deny

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: app-extreme-prod
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: app-extreme-allow
  namespace: app-extreme-prod
spec:
  podSelector:
    matchLabels:
      app: app-extreme
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              network.openshift.io/policy-group: ingress
      ports:
        - { protocol: TCP, port: 8443 }
  egress:
    - to:
        - podSelector:
            matchLabels:
              cnpg.io/cluster: db-extreme
      ports:
        - { protocol: TCP, port: 5432 }
```

### 4.7 Velero — Backup K8s objects

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: app-extreme-daily
  namespace: velero
spec:
  schedule: "0 2 * * *"   # quotidien 02:00
  template:
    includedNamespaces: ["app-extreme-prod"]
    snapshotVolumes: true
    storageLocation: cos-marne-est
    volumeSnapshotLocations: ["ibm-csi"]
    ttl: "720h"            # 30 jours
```

## 5. Niveau 🟠 Serious — Manifestes adaptés

**Cas d’usage** : applications métier importantes mais non temps réel critique (back-office, reporting interne).

**Différences clés vs Extreme** :

- M:Two → **2 AZ** au lieu de 3 (et donc 6 réplicas au lieu de 9)
- Tout le reste reste identique : All Active, HA, Near Sync, M:Two backup, MUST rebuild & restore

### 5.1 Deployment — 6 réplicas sur 2 AZ

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-serious
  namespace: app-serious-prod
spec:
  replicas: 6   # 3 par AZ × 2 AZ
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0

  selector:
    matchLabels: { app: app-serious }

  template:
    metadata:
      labels: { app: app-serious }
    spec:
      serviceAccountName: app-serious-sa
      terminationGracePeriodSeconds: 60

      # === M:Two All Active — 2 AZ obligatoires ===
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule   # toujours strict (All Active)
          labelSelector:
            matchLabels: { app: app-serious }

      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels: { app: app-serious }
              topologyKey: kubernetes.io/hostname

      # ... reste identique à Extreme (probes, security, resources)
      containers:
        - name: app
          image: registry.bnpp.cardif/cardif/app-serious:1.0.0
          resources:
            requests: { cpu: "500m", memory: "1Gi" }
            limits:   { cpu: "500m", memory: "1Gi" }
          # ... probes identiques à Extreme
```

### 5.2 PDB — perte d’1 AZ tolérée

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: app-serious-pdb
  namespace: app-serious-prod
spec:
  # 6 - 3 (perte 1 AZ sur 2) = 3 minimum
  minAvailable: 3
  selector:
    matchLabels: { app: app-serious }
```

### 5.3 PostgreSQL — Near Sync sur 2 AZ

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: db-serious
spec:
  instances: 2          # 1 primary + 1 sync standby
  minSyncReplicas: 1
  maxSyncReplicas: 1
  postgresql:
    parameters:
      synchronous_commit: "on"
  # backup et topology spread identiques à Extreme
```

## 6. Niveau 🟡 Moderate — Manifestes adaptés

**Cas d’usage** : applications de support, outils internes, batchs analytics non critiques.

**Différences clés vs Serious** :

- Active Mode → **Hot** (et non All Active) → 1 instance principale + standby
- Data Distribution → **Async / Batch** (RPO en secondes/minutes accepté)
- Local Rebuild → **SHOULD** (recommandé, pas obligatoire — runbook utile mais non bloquant)

### 6.1 Deployment — 4 réplicas sur 2 AZ, contraintes assouplies

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-moderate
  namespace: app-moderate-prod
spec:
  replicas: 4
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1   # ⚠ on autorise une légère indispo

  selector:
    matchLabels: { app: app-moderate }

  template:
    metadata:
      labels: { app: app-moderate }
    spec:
      serviceAccountName: app-moderate-sa
      terminationGracePeriodSeconds: 30

      # === Spread souple — ScheduleAnyway tolère un déséquilibre ===
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway   # ⚠ pas DoNotSchedule
          labelSelector:
            matchLabels: { app: app-moderate }

      # Anti-affinity en preferred — pas required
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels: { app: app-moderate }
                topologyKey: kubernetes.io/hostname

      containers:
        - name: app
          image: registry.bnpp.cardif/cardif/app-moderate:1.0.0
          resources:
            # QoS Burstable acceptable pour Moderate
            requests: { cpu: "250m", memory: "512Mi" }
            limits:   { cpu: "1000m", memory: "1Gi" }
          # probes simplifiées (liveness + readiness suffisent)
          livenessProbe:
            httpGet: { path: /actuator/health, port: 8081 }
            periodSeconds: 15
          readinessProbe:
            httpGet: { path: /actuator/health, port: 8081 }
            periodSeconds: 10
```

### 6.2 PDB — minimum 1 pod

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: app-moderate-pdb
  namespace: app-moderate-prod
spec:
  minAvailable: 1   # plus tolérant qu'Extreme/Serious
  selector:
    matchLabels: { app: app-moderate }
```

### 6.3 PostgreSQL — réplication asynchrone (Hot standby)

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: db-moderate
spec:
  instances: 2

  # Pas de quorum sync — réplication async
  minSyncReplicas: 0
  maxSyncReplicas: 0

  postgresql:
    parameters:
      synchronous_commit: "off"   # async — RPO en secondes
      hot_standby: "on"
```

## 7. Niveau 🟢 Low — Manifestes minimalistes

**Cas d’usage** : outils internes ponctuels, environnements d’expérimentation, applications obsolescentes en cours de décommissionnement.

**Différences clés vs Moderate** :

- Topology → **M:One** : 1 seule AZ requise
- Active Mode → **Cold** : pas de standby pré-provisionné
- Local Rebuild → **COULD** : optionnel
- Restore régional → **MUST** reste obligatoire (filet de sécurité minimum partagé par tous les niveaux)

### 7.1 Deployment — 1 ou 2 réplicas, contraintes minimales

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-low
  namespace: app-low-prod
spec:
  replicas: 2   # minimum pour rolling update sans interruption
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1

  selector:
    matchLabels: { app: app-low }

  template:
    metadata:
      labels: { app: app-low }
    spec:
      serviceAccountName: default
      terminationGracePeriodSeconds: 30

      # Pas de topologySpread — single AZ accepté
      # Pas d'anti-affinity stricte

      containers:
        - name: app
          image: registry.bnpp.cardif/cardif/app-low:1.0.0
          resources:
            requests: { cpu: "100m", memory: "256Mi" }
            limits:   { cpu: "500m", memory: "512Mi" }
          livenessProbe:
            httpGet: { path: /health, port: 8080 }
            initialDelaySeconds: 30
            periodSeconds: 30
```

### 7.2 Pas de PDB obligatoire

Le PDB peut être omis ou très souple : `maxUnavailable: 1` simplement.

### 7.3 PostgreSQL — instance unique avec backup obligatoire

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: db-low
spec:
  instances: 1   # standalone — Cold mode

  # Backup OBLIGATOIRE même pour Low (Local Restore = MUST)
  backup:
    retentionPolicy: "7d"
    barmanObjectStore:
      destinationPath: "s3://backup-cos-marne-est/db-low"
      # ... credentials
      wal:
        compression: gzip
```

## 8. Récapitulatif — qu’est-ce qui change entre les niveaux ?

|Élément                   |Extreme        |Serious        |Moderate       |Low      |
|--------------------------|---------------|---------------|---------------|---------|
|`replicas`                |9              |6              |4              |1–2      |
|`whenUnsatisfiable`       |DoNotSchedule  |DoNotSchedule  |ScheduleAnyway |(omis)   |
|`podAntiAffinity`         |required       |required       |preferred      |(omis)   |
|`maxUnavailable` (rolling)|0              |0              |1              |1        |
|`PodDisruptionBudget`     |minAvailable: 6|minAvailable: 3|minAvailable: 1|omis     |
|QoS class                 |Guaranteed     |Guaranteed     |Burstable      |Burstable|
|`synchronous_commit` PG   |on             |on             |off            |off      |
|Réplicas DB               |3 (1/AZ)       |2 (1/AZ)       |2 (async)      |1        |
|Backup retention          |30 j           |30 j           |14 j           |7 j      |
|Restore test fréquence    |trimestriel    |trimestriel    |semestriel     |annuel   |

## 9. Bonnes pratiques transverses (tous niveaux)

Quel que soit le niveau, certaines règles s’appliquent :

1. **Probes séparées** liveness ≠ readiness — sinon une dépendance externe down provoque des restarts inutiles.
1. **`terminationGracePeriodSeconds` aligné** avec le timeout du LB en frontal (typiquement 30–60 s).
1. **`preStop` hook** avec `sleep` court (10–15 s) pour laisser au controller endpoints le temps de désinscrire le pod avant SIGTERM.
1. **NetworkPolicies default-deny** dès Moderate — non négociable depuis DORA / NIS2.
1. **Image scan** Trivy / Snyk + signature Cosign vérifiée par Kyverno (Ring 4 — Image Security).
1. **Audit logs** activés sur le cluster (Ring 1 — API Server).
1. **PV non zonal** : éviter `ibmc-block-*` zonal pour les workloads HA → privilégier IBM Cloud Databases ou ODF / Portworx.

## 10. Mapping AZ logique → infrastructure ITGP

|AZ ROKS (label `topology.kubernetes.io/zone`)|Site physique ITGP   |Backup zone disponible                       |
|---------------------------------------------|---------------------|---------------------------------------------|
|`eu-fr2-1` (Paris 1)                         |Marne Nord DC        |non (Marne Nord n’héberge pas de Backup zone)|
|`eu-fr2-2` (Paris 2)                         |Marne Est DC         |oui                                          |
|`eu-fr2-3` (Paris 3)                         |Marne Est DC         |oui                                          |
|Bastogne                                     |Bastogne DC (Belgium)|oui — DR vital applications uniquement       |

**Conséquence** : les backups M:Two doivent cibler obligatoirement Marne Est et/ou Bastogne — pas Marne Nord.

## 11. Checklist de revue d’architecture

Avant mise en production, valider que le manifeste répond positivement à chaque ligne :

- [ ] `replicas` ≥ valeur du tableau pour le niveau cible
- [ ] `topologySpreadConstraints` configuré sur `topology.kubernetes.io/zone`
- [ ] `whenUnsatisfiable` correct selon niveau (DoNotSchedule pour Extreme/Serious)
- [ ] `podAntiAffinity` sur `kubernetes.io/hostname`
- [ ] `PodDisruptionBudget` aligné sur le quorum AZ
- [ ] Probes séparées startup / liveness / readiness
- [ ] `preStop` hook + `terminationGracePeriodSeconds` cohérents
- [ ] QoS class adaptée (Guaranteed pour Extreme/Serious)
- [ ] DB en mode `synchronous_commit=on` pour Extreme/Serious
- [ ] Backup configuré avec destination Marne Est ou Bastogne
- [ ] Test de restauration planifié (trimestriel pour Extreme/Serious)
- [ ] NetworkPolicy default-deny appliquée
- [ ] Image signée + scan vulnérabilités passé
- [ ] Documentation runbook DR à jour (MUST pour Extreme/Serious)

## 12. Annexe — Références

- IT RefCard Continuity & Resilience for Cloud v1.0.6 (2023) — référentiel BNPP Cardif
- IBM Cloud — ROKS multi-zone clusters
- Kubernetes — Pod Topology Spread Constraints
- CloudNativePG — PostgreSQL Operator
- Velero — Kubernetes backup & restore
- DORA (Digital Operational Resilience Act) — exigences de tests de restauration

-----

*Charte Design Ema · Cloud Native Architect — BNPP Cardif / TOE*
