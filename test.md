Salut,

Pas de page Confluence dédiée à ce sujet à ma connaissance (je n'en ai pas vu passer). Voici ce que je peux te partager :

1) Transformation des annotations nginx → HAProxy
Il n'y a pas de mapping automatique 1:1. Les annotations nginx.ingress.kubernetes.io/* doivent être retranscrites manuellement en annotations Route OpenShift (haproxy.router.openshift.io/* et router.openshift.io/*). Pas de règle de correspondance officielle partagée côté Confluence pour l'instant — à formaliser si l'équipage en a besoin.

2) Session affinity (cookie / sticky sessions)
Le cookie de persistance ne peut PAS fonctionner en passthrough : dans ce mode le routeur ne voit que le SNI/hostname, pas la couche HTTP, donc il ne peut ni lire ni injecter de cookie. Pour reproduire le comportement de l'annotation nginx cookie, il faut passer en reencrypt (ou edge) et utiliser :

    haproxy.router.openshift.io/disable_cookies: "false"
    router.openshift.io/cookie_name: nts-cookie

Donc oui : dès qu'il y a du cookie / de l'affinity, le passthrough est à déconseiller à l'équipage → reencrypt obligatoire.

3) Multipath
Même logique que ci-dessus : le multipath n'est pas géré en passthrough (le routeur ne voit pas le path). Deux options :
  - éclater en plusieurs Routes (une par path), en edge/reencrypt ;
  - ou garder le routage de path au niveau du sidecar nginx : une seule Route reencrypt vers le sidecar, et nginx dispatche en interne (config nginx).

4) Regex dans les paths — limitation
Les Routes OpenShift ne gèrent pas les regex / wildcards dans les paths : le matching se fait en préfixe uniquement. Un pattern type api/* n'est pas supportable directement sur la Route → à porter sur le sidecar nginx.

Quelques correspondances complémentaires utiles pour l'équipage :
  - Rewrite : nginx .../rewrite-target → haproxy.router.openshift.io/rewrite-target
  - Timeouts : proxy-read-timeout / proxy-send-timeout → haproxy.router.openshift.io/timeout
  - Algo de load balancing : haproxy.router.openshift.io/balance (roundrobin, leastconn, source)
  - Allowlist IP : nginx .../whitelist-source-range → haproxy.router.openshift.io/ip_allowlist (ex-ip_whitelist)
  - Rate limiting : haproxy.router.openshift.io/rate-limit-connections
  - Taille de body : pas d'équivalent simple par-Route (géré au niveau IngressController/HAProxy global) → à traiter sur le sidecar si besoin

À noter aussi : le reencrypt suppose de fournir le destinationCACertificate dans la Route (CA du sidecar).

En résumé, le pattern qu'on pousse reste : une Route reencrypt vers le sidecar nginx, et on garde toute la logique fine (multipath, regex, rewrite complexe, headers) dans la conf nginx du sidecar. Ça limite la surface d'annotations sur la Route et ça reste cohérent avec l'archi cible.

Je peux monter une petite page Confluence de correspondance nginx → Route si ça vous rend service côté équipages.



# Exemple complet : Vault Dynamic Secrets → IBM Cloud IAM → IBM Event Streams

## 1. Authentification Kubernetes → Obtention du token Vault

Le pod s'authentifie auprès de Vault via la méthode **Kubernetes Auth** en présentant le JWT de son **Service Account**.

```bash
curl -s \
  --request POST \
  https://vault.internal:8200/v1/auth/kubernetes/login \
  --data '{
    "role": "producer-app",
    "jwt": "'"$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"'"
  }'
```

### Réponse

```json
{
  "auth": {
    "client_token": "hvs.CAESIJ...xyz",
    "policies": [
      "producer-policy",
      "default"
    ],
    "lease_duration": 3600,
    "renewable": true
  }
}
```

---

## 2. Lecture du secret dynamique (création du Service ID + API Key)

Le pod utilise le **Vault Token** obtenu précédemment pour demander un secret dynamique.

Vault appelle en arrière-plan l'API IBM Cloud IAM afin de :

- créer un **Service ID**
- lui associer une **policy IAM**
- générer une **API Key**
- retourner uniquement les informations nécessaires au client.

```bash
curl -s \
  --header "X-Vault-Token: hvs.CAESIJ...xyz" \
  https://vault.internal:8200/v1/ibmcloud/creds/producer-role
```

### Réponse

```json
{
  "lease_id": "ibmcloud/creds/producer-role/abc123",
  "lease_duration": 3600,
  "renewable": true,
  "data": {
    "service_id": "ServiceId-9f1c2e4a-...",
    "api_key": "p3kY7q-XXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    "api_key_id": "ApiKey-7a3b...",
    "name": "vault-producer-9f1c2e"
  }
}
```

> **Remarque**
>
> Le `service_id` représente l'identité IAM et porte les permissions.
>
> Le client Kafka n'utilise que la `api_key` pour l'authentification SASL.

---

## 3. Injection dans le client Kafka

Le pod récupère la valeur de `data.api_key` afin de construire la configuration JAAS.

Aucun secret n'est persisté sur disque. Les informations sont stockées uniquement en mémoire (tmpfs/emptyDir Memory).

```bash
cat <<EOF > /tmp/producer.properties
bootstrap.servers=broker-0.kafka.svc.appdomain.cloud:9093

security.protocol=SASL_SSL
sasl.mechanism=PLAIN

sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
username="token" \
password="$(echo "$VAULT_RESPONSE" | jq -r .data.api_key)";
EOF
```

---

## 4. Renouvellement du lease avant expiration

Afin d'éviter toute interruption du producteur Kafka, Vault peut renouveler le lease avant son expiration.

```bash
curl -s \
  --header "X-Vault-Token: hvs.CAESIJ...xyz" \
  --request PUT \
  https://vault.internal:8200/v1/sys/leases/renew \
  --data '{
    "lease_id": "ibmcloud/creds/producer-role/abc123",
    "increment": 3600
  }'
```

---

## 5. Révocation explicite

Lorsque le lease expire ou est révoqué, Vault supprime automatiquement les ressources créées dans IBM Cloud IAM :

- suppression de l'API Key
- suppression du Service ID

```bash
curl -s \
  --header "X-Vault-Token: hvs.CAESIJ...xyz" \
  --request PUT \
  https://vault.internal:8200/v1/sys/leases/revoke \
  --data '{
    "lease_id": "ibmcloud/creds/producer-role/abc123"
  }'
```

---

## Résumé du cycle de vie

```text
Pod Kubernetes
        │
        ▼
Authentification Kubernetes
        │
        ▼
Obtention d'un Vault Token
        │
        ▼
Lecture de ibmcloud/creds/producer-role
        │
        ▼
Vault crée dynamiquement :
   • Service ID
   • API Key
        │
        ▼
Le pod utilise uniquement l'API Key
pour l'authentification SASL/PLAIN Kafka
        │
        ▼
Lease renouvelable pendant son utilisation
        │
        ▼
Révocation ou expiration
        │
        ▼
Suppression automatique de :
   • l'API Key
   • le Service ID


startupProbe:
  httpGet:
    path: /healthz
    port: 8443
    scheme: HTTPS
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 30      # 30 × 10s = 300s de budget (> 210s)
  timeoutSeconds: 3

livenessProbe:
  httpGet:
    path: /healthz
    port: 8443
    scheme: HTTPS
  periodSeconds: 10
  timeoutSeconds: 3
  failureThreshold: 3       # plus besoin d'un gros initialDelay : le startupProbe gère le boot

readinessProbe:
  httpGet:
    path: /healthz
    port: 8080
    scheme: HTTP
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3

```
