FROM alpine:3.20

RUN apk add --no-cache bash curl jq python3

COPY sync-tasks.sh sync-npm-hosts.sh sync-ctfd.sh /app/
RUN chmod +x /app/sync-*.sh

ENTRYPOINT ["/bin/sh"]