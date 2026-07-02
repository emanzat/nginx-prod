1. Authentification K8s → obtention du token Vault
bashcurl -s --request POST \
  https://vault.internal:8200/v1/auth/kubernetes/login \
  --data '{
    "role": "producer-app",
    "jwt": "'"$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"'"
  }'
Réponse :
json{
  "auth": {
    "client_token": "hvs.CAESIJ...xyz",
    "policies": ["producer-policy", "default"],
    "lease_duration": 3600,
    "renewable": true
  }
}
2. Lecture du secret dynamique (génère le SID + API Key)
bashcurl -s --header "X-Vault-Token: hvs.CAESIJ...xyz" \
  https://vault.internal:8200/v1/ibmcloud/creds/producer-role
Réponse — c'est ici que Vault a appelé l'API IAM IBM Cloud en coulisses :
json{
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
3. Injection dans le client Kafka
Le pod consomme data.api_key pour construire le JAAS config (jamais écrit sur disque, généré en mémoire) :
bashcat <<EOF > /tmp/producer.properties
bootstrap.servers=broker-0.kafka.svc.appdomain.cloud:9093
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
  username="token" \
  password="$(echo $VAULT_RESPONSE | jq -r .data.api_key)";
EOF
4. Renouvellement avant expiration (évite la coupure du producer)
bashcurl -s --header "X-Vault-Token: hvs.CAESIJ...xyz" \
  --request PUT \
  https://vault.internal:8200/v1/sys/leases/renew \
  --data '{
    "lease_id": "ibmcloud/creds/producer-role/abc123",
    "increment": 3600
  }'
5. Révocation explicite (suppression SID + clé côté IBM IAM)
bashcurl -s --header "X-Vault-Token: hvs.CAESIJ...xyz" \
  --request PUT \
  https://vault.internal:8200/v1/sys/leases/revoke \
  --data '{ "lease_id": "ibmcloud/creds/producer-role/abc123" }'
