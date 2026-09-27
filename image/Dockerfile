FROM alpine:latest

RUN apk add --no-cache bash cronie curl coreutils mariadb mariadb-client postgresql-client gzip rclone tar tzdata shadow docker-cli msmtp ca-certificates

COPY backup.sh /usr/local/bin/backup.sh
COPY start.sh /start.sh

RUN chmod +x /usr/local/bin/backup.sh /start.sh

CMD ["/start.sh"]