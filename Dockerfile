# Allowed values: cpu, cuda, rocm
ARG hardware="cpu"
# Allowed values: full, slim
ARG version="full"

FROM sceptri/amml-python-base-${hardware}:latest AS base-full
FROM sceptri/amml-python-base-${hardware}-slim:latest AS base-slim

FROM base-${version} AS final
LABEL authors="sceptri"
ARG version

WORKDIR /opt/project/

# Add something here!
# For example install additional project-specific Python dependencies
COPY requirements.txt requirements.txt

# Copy all necessary requirements files (full requirements reference the slim version, not the other way around)
# Note that these files are masked by mounting the current host dir to WORKDIR of the container
RUN cp /opt/build/slim_requirements.txt slim_requirements.txt
RUN cp /opt/build/${version}_requirements.txt base_requirements.txt

RUN pip install --upgrade pip && pip install -r requirements.txt

# Entrypoint shell script is necessary to make it work with PyCharm when docker compose is the Python interpreter
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]