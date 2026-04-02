FROM nginx:1.27-alpine
RUN apk add --no-cache nginx-mod-http-js
COPY docker-entrypoint.sh /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
