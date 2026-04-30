# Sizing Sidecar nginx — Production

Sidecar nginx (reverse proxy / TLS termination / TLS reencrypt) sur OpenShift.

## Tableau de dimensionnement

|RPS / pod        |CPU request|CPU limit|Memory request|Memory limit|
|-----------------|-----------|---------|--------------|------------|
|**0 – 200**      |`25m`      |`100m`   |`32Mi`        |`32Mi`      |
|**200 – 500**    |`50m`      |`200m`   |`64Mi`        |`64Mi`      |
|**500 – 1 500**  |`100m`     |`500m`   |`128Mi`       |`128Mi`     |
|**1 500 – 3 000**|`200m`     |`800m`   |`192Mi`       |`192Mi`     |
|**3 000 – 6 000**|`400m`     |`1500m`  |`256Mi`       |`256Mi`     |
|**> 6 000**      |`750m`     |`2500m`  |`384Mi`       |`384Mi`     |

## Règles

- **Memory request = limit** → QoS `Guaranteed`, pas d’OOMKill aléatoire.
- **CPU limit ≈ 3–5× request** → absorbe les pics de handshakes TLS sans throttling permanent.
- **TLS reencrypt** → prendre la ligne au-dessus (handshake côté client + côté backend).
- **mTLS bidirectionnel** → +30 % CPU, prendre la ligne au-dessus.
- **HTTP plain (sans TLS)** → diviser le CPU par 2.

## Base de calcul (synthèse)

|Opération                      |Coût       |
|-------------------------------|-----------|
|Handshake TLS ECDHE-RSA 2048   |~3 ms CPU  |
|Reprise session TLS            |~0,2 ms CPU|
|Proxy HTTP (overhead)          |~0,1 ms CPU|
|Connexion TLS active en mémoire|~100 Ko    |
|Worker nginx idle              |~12 Mo     |

Avec un taux de reprise de session de 90 % (réaliste avec `ssl_session_cache shared:SSL:10m`), le coût moyen par requête est ~0,5 ms CPU côté front, ~1 ms en reencrypt.

## Calibration

Surveiller sur 7 jours :

```promql
# Throttling — doit rester < 1%
rate(container_cpu_cfs_throttled_periods_total{container="nginx"}[5m])
  / rate(container_cpu_cfs_periods_total{container="nginx"}[5m])

# Pic mémoire
max_over_time(container_memory_working_set_bytes{container="nginx"}[7d])
```

Ajuster :

- `memory request` = `P99 working_set × 1,3`
- `cpu request` = `P95 cpu_usage`
- `cpu limit` = `P99.9 cpu_usage × 1,5`
