# ruleid: dockerfile-unpinned-base-latest
FROM node:latest
# ok: dockerfile-unpinned-base-latest
FROM python@sha256:abc123

# ruleid: dockerfile-secret-in-env-arg
ENV API_SECRET=hunter2supersecret
# ruleid: dockerfile-secret-in-env-arg
ARG DB_PASSWORD=letmein
# ok: dockerfile-secret-in-env-arg
ENV APP_PORT=8080

# ruleid: dockerfile-runs-as-root
USER root
