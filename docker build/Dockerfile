# ITFlow + MariaDB + Tailscale in a single container, for a DigitalOcean MicroVM.
# Build for linux/amd64 (MicroVMs require it).
FROM debian:12-slim

# Pin the ITFlow release. Change this to upgrade on the next image build.
ARG ITFLOW_REF=v26.10

ENV DEBIAN_FRONTEND=noninteractive

# Same packages as the official install script, minus certbot (Tailscale handles HTTPS),
# plus supervisor to run several processes in one container.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
      apache2 mariadb-server \
      php libapache2-mod-php php-intl php-mysql php-gd \
      php-curl php-mbstring php-zip php-xml \
      git cron whois dnsutils openssl supervisor tar gzip \
 && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
 && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
      -o /etc/apt/sources.list.d/tailscale.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends tailscale \
 && rm -rf /var/lib/apt/lists/*

# PHP limits, matching the official install script.
RUN for ini in /etc/php/*/apache2/php.ini; do \
      sed -i 's/^;\?upload_max_filesize =.*/upload_max_filesize = 500M/' "$ini"; \
      sed -i 's/^;\?post_max_size =.*/post_max_size = 500M/' "$ini"; \
      sed -i 's/^;\?max_execution_time =.*/max_execution_time = 300/' "$ini"; \
    done

# Apache site
COPY apache-itflow.conf /etc/apache2/sites-available/itflow.conf
RUN echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf \
 && a2enconf servername \
 && a2enmod rewrite \
 && a2dissite 000-default \
 && a2ensite itflow

# ITFlow code. Cloned on the master branch, then moved to the pinned release,
# so ITFlow's built-in updater (which tracks master) still works later.
RUN git clone --branch master https://github.com/itflow-org/itflow.git /var/www/itflow \
 && git -C /var/www/itflow reset --hard "${ITFLOW_REF}" \
 && chown -R www-data:www-data /var/www/itflow

# Cron jobs, process supervisor, startup and backup scripts
COPY itflow.cron /etc/cron.d/itflow
COPY supervisord-itflow.conf /etc/supervisor/conf.d/itflow.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY itflow-backup.sh /usr/local/bin/itflow-backup.sh
# Strip Windows line endings in case the files were checked out as CRLF
RUN sed -i 's/\r$//' /etc/cron.d/itflow /etc/supervisor/conf.d/itflow.conf \
      /usr/local/bin/entrypoint.sh /usr/local/bin/itflow-backup.sh \
      /etc/apache2/sites-available/itflow.conf \
 && chmod 644 /etc/cron.d/itflow \
 && chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/itflow-backup.sh

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
