# Allowed values: cpu, cuda, rocm
ARG hardware="cpu"
# Allowed values: full, slim
ARG version="full"

FROM sceptri/amml-python-base-${hardware} AS base-full
FROM sceptri/amml-python-base-${hardware}-slim AS base-slim

ARG version
FROM base-${version} AS final
LABEL authors="sceptri"

WORKDIR /opt/project/

# Add something here!

# Entrypoint shell script is necessary to make it work with PyCharm when docker compose is the Python interpreter
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]