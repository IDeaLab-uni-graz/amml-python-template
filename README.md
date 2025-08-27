# AMML Python Template

This is the basic light-weight template for Python + Pytorch projects running on Docker at the Martin Holler's team @ IDea_Lab, University of Graz.

For standard machine learning Python projects in the AMML team use the complete [AMML Python ML template](https://github.com/IDeaLab-uni-graz/amml-python-ml-template). More information regarding the design and contents of the base images can be found in the [respective repository](https://github.com/IDeaLab-uni-graz/AMML-Python-Base).

Run with, e.g., 
```
docker compose run --build --rm amml-project-cpu
```

## Template Checklist

What needs to be done after starting a new project:

- [ ] Rename project in `docker-compose.yaml`
- [ ] Rename source folder, here `amml-python-template/`
- [ ] Write a (good) `README.md`, possibly also change a license

### PyCharm Checklist

What needs to be done after starting a new project to use it with PyCharm:

- [ ] Set up the Python interpreter to use **Docker compose**, or possibly also Docker.
- [ ] Set the Jupyter server to listen on all addresses by adding `--ip 0.0.0.0` to _command line arguments_ for the local Jupyter connection.

In case one decides to use the **Docker Python interpreter**, it is also necessary to do:

- [ ] Make sure to have access to the gpu's in the Docker container (e.g., with the flag `--gpus all`)
- [ ] Make sure to expose the host network to the Docker container (e.g., with the flag `--add-host=host.docker.internal:host-gateway`)
  - Alternatively, one can set the container to use the same network as the host using `--network host`, but this does not work with Jupyter and PyCharm - in such case, replace `host.docker.internal` address with `localhost` in the source code and config

## Structure

Description of files and directories belonging to this repository:
- `amml-python-template/` - source code directory to be renamed when using the template
  - `.../main.py` or `.../__init__.py` - entrypoint of the Python codebase
- `data/` - directory for (large) data, which should not be version controlled by default
- `tmp/` - directory for temporary outputs of operations, contents are not version controlled
- `utils/` - project-independent scripts, e.g., downloading datasets from UniCloud or similar
- `Dockerfile` - project-specific Docker image definition, likely building upon one of the [AMML base images](https://github.com/IDeaLab-uni-graz/AMML-Python-Base)
- `docker-compose.yaml` - declarative configuration for building and running project Docker containers
- `entrypoint.sh` - custom entrypoint of the project Docker image to properly support PyCharm

> [!TIP]
> If you need a newer version of one of the base images, you might need to "force pull" the image from DockerHub to replace the locally cached version
> ```shell
> docker pull sceptri/amml-python-base-cpu:latest
> ```