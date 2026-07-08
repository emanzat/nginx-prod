

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
