# PostgreSQL 16 con certificado TLS propio (hardening #6)
FROM postgres:16-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /etc/ssl/nutri \
 && openssl req -new -x509 -days 825 -nodes \
      -subj "/C=CR/O=NutriAnimales S.A./CN=postgres.nutrianimales.local" \
      -keyout /etc/ssl/nutri/server.key \
      -out    /etc/ssl/nutri/server.crt \
 && chown -R postgres:postgres /etc/ssl/nutri \
 && chmod 600 /etc/ssl/nutri/server.key
