FROM alpine:3.15
COPY ./dhix-backup.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/dhix-backup.sh
RUN apk add --no-cache wget curl
RUN apk add --update bash diffutils postgresql14-client && rm -rf /var/cache/apk/*
#ENTRYPOINT ["psql"] 