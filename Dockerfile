# =============================================================================
# Stage 1 : Image finale
FROM nginx:stable

LABEL maintainer="MANZAT EL HOUCINE" \
      version="1.0.0" \
      description="Nginx sidecar TLS termination for Kubernetes"

# -----------------------------------------------------------------------
# Sécurité : utilisateur non-root
# -----------------------------------------------------------------------
RUN groupadd -g 1001 nginx-sidecar && \
    useradd -u 1001 -g nginx-sidecar -s /bin/false -M nginx-sidecar && \
    chown -R nginx-sidecar:nginx-sidecar \
        /var/cache/nginx \
        /var/log/nginx \
        /etc/nginx/conf.d && \
    chmod -R 755 /var/cache/nginx && \
    touch /var/run/nginx.pid && \
    chown nginx-sidecar:nginx-sidecar /var/run/nginx.pid

# -----------------------------------------------------------------------
# Configuration principale Nginx
# -----------------------------------------------------------------------
COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d/default.conf /etc/nginx/conf.d/default.conf

# -----------------------------------------------------------------------
# Répertoire pour les certificats TLS (montés via Secret K8s)
# -----------------------------------------------------------------------
RUN mkdir -p /etc/nginx/certs && \
    chown -R nginx-sidecar:nginx-sidecar /etc/nginx/certs && \
    chmod 700 /etc/nginx/certs

# -----------------------------------------------------------------------
# Exposition des ports
# -----------------------------------------------------------------------
EXPOSE 8443


USER nginx-sidecar

CMD ["nginx", "-g", "daemon off;"]