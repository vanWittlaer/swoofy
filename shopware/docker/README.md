
# traefik labels for basic auth

```
traefik.enable=true
traefik.http.middlewares.auth.basicauth.users=van:$2y$05$dwgowIxflIulSM2fMW7Co./xEIGkzuE7ZbwX0spEAEfhgrWE4Vu/.
traefik.http.middlewares.gzip.compress=true
traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https
traefik.http.routers.http-0-ng448s84ss4soko8ksowkcks.entryPoints=http
traefik.http.routers.http-0-ng448s84ss4soko8ksowkcks.middlewares=redirect-to-https
traefik.http.routers.http-0-ng448s84ss4soko8ksowkcks.rule=Host(`www.poensgen.de`) && PathPrefix(`/`)
traefik.http.routers.http-0-ng448s84ss4soko8ksowkcks.service=http-0-ng448s84ss4soko8ksowkcks
traefik.http.routers.https-0-ng448s84ss4soko8ksowkcks.entryPoints=https
traefik.http.routers.https-0-ng448s84ss4soko8ksowkcks.middlewares=gzip,auth
traefik.http.routers.https-0-ng448s84ss4soko8ksowkcks.rule=Host(`www.poensgen.de`) && PathPrefix(`/`) && !PathPrefix(`/api`)
traefik.http.routers.https-0-ng448s84ss4soko8ksowkcks.service=https-0-ng448s84ss4soko8ksowkcks
traefik.http.routers.https-0-ng448s84ss4soko8ksowkcks.tls.certresolver=letsencrypt
traefik.http.routers.https-0-ng448s84ss4soko8ksowkcks.tls=true
traefik.http.routers.https-0-ng448s84ss4soko8ksowkcks-api.entryPoints=https
traefik.http.routers.https-0-ng448s84ss4soko8ksowkcks-api.middlewares=gzip
traefik.http.routers.https-0-ng448s84ss4soko8ksowkcks-api.rule=Host(`www.poensgen.de`) && PathPrefix(`/api`)
traefik.http.routers.https-0-ng448s84ss4soko8ksowkcks-api.service=https-0-ng448s84ss4soko8ksowkcks-api
traefik.http.routers.https-0-ng448s84ss4soko8ksowkcks-api.tls.certresolver=letsencrypt
traefik.http.routers.https-0-ng448s84ss4soko8ksowkcks-api.tls=true
traefik.http.services.http-0-ng448s84ss4soko8ksowkcks.loadbalancer.server.port=8000
traefik.http.services.https-0-ng448s84ss4soko8ksowkcks.loadbalancer.server.port=8000
traefik.http.services.https-0-ng448s84ss4soko8ksowkcks-api.loadbalancer.server.port=8000
```

