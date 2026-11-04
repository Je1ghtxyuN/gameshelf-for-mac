ARG PYTHON_IMAGE=python:3.12-slim-bookworm
FROM ${PYTHON_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends \
    samba samba-common-bin smbclient util-linux passwd ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY gameshelf_server /app/gameshelf_server
COPY tests /app/tests
COPY api-schema.json /app/api-schema.json
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 GAMESHELF_CONTAINER=1
EXPOSE 8443 445
STOPSIGNAL SIGTERM
ENTRYPOINT ["python", "-m", "gameshelf_server"]
