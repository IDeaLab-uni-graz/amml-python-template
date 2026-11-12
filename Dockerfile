# Allowed values: cpu, cuda, rocm
ARG hardware="cpu"
# Allowed values: full, slim
ARG version="full"
# Pinned base image (published by the base image CI for all variants).
# Bump with `.container/image.sh bump-base [<tag>] [--repo <repo>]`; changing it triggers an image rebuild.
ARG base_repo="devidealab/amml-python-base"
ARG base_tag="main-6b1ecc3"

FROM ${base_repo}-${hardware}:${base_tag} AS base-full
FROM ${base_repo}-${hardware}-slim:${base_tag} AS base-slim

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

# Install Python dependencies
RUN pip install --upgrade pip && pip install -r requirements.txt

# Entrypoint shell script is necessary to make it work with PyCharm when docker compose is the Python interpreter
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]