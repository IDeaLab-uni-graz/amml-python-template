# AMML Python Template

This is the basic light-weight template for Python + Pytorch projects running on Docker at the Martin Holler's team @ IDea_Lab, University of Graz.

For standard machine learning Python projects in the AMML team use the complete [AMML Python ML template](https://github.com/IDeaLab-uni-graz/amml-python-ml-template). More information regarding the design and contents of the base images can be found in the [respective repository](https://github.com/IDeaLab-uni-graz/AMML-Python-Base).

To make a quick testrun (for testing only!), copy the `.env.example` file, rename the copy to `.env` and run

```
docker compose run --build --rm amml-project-cpu
```

## Using this as base for a new project

1) **Use it as a template:**
   1) **GitHub**: Create new repository and in the _Configuration_ section set **Start with a template** to `IDeaLab-uni-graz/amml-python-template`, then `git clone` it
   2) **Locally**: Download the content of this repository (do **not** `git clone` it!) into your desired project directory.
2) Rename the project in `docker-compose.yaml`: the project name `name: "amml_python_template"` and the image names `devidealab/amml-python-template-<hardware>:local` (they should match `IMAGE_NAME` in `.container/image.conf`, see step 6)
3) Rename source folder, called `amml-python-template/` in the template
4) Setup project Docker image by updating `Dockerfile`, `requirements.txt` or `docker-compose.yaml`
5) Write a (good) `README.md`, possibly also change a license
6) Set `IMAGE_NAME` in `.container/image.conf` (e.g. `devidealab/<project-name>`) and run `.container/image.sh install` (see [HPC images](#hpc-images-apptainersingularity))

After this, you can run your project **locally** with 

```shell
docker compose run --build --rm amml-project-cpu # Local CPU Version
```

or 

```shell
docker compose run --build --rm amml-project-cuda # Local GPU Version
```

> [!NOTE]
> If you have not changed the docker files, you can just run without the "--build" flag to avoid that docker is forced to rebuild the image every time you run it.
> 
> However, if the Dockerfile was not changed since the last time the `docker compose` command was run, it will not force rebuild the image but use the cached version (nevertheless, the check for changes in `Dockerfile` slows it down a bit).

> [!IMPORTANT]
> On Hydra, you should use Hydra-specific Docker compose targets to ensure the MLFlow (and other over-the-network apps) are available:
> 
> ```shell
> docker compose run --build --rm amml-project-hydra-cpu # Hydra CPU Version
> ```
> 
> or
> 
> ```shell
> docker compose run --build --rm amml-project-hydra-cuda # Hydra CUDA Version
> ```

> [!TIP]
> When trying to connect to MLFlow running on hydra from your computer, you **must**:
> 1. open ssh connection with port-forwarding, which listens on port 8080 for connections from any address, i.e.,
> ```shell
> ssh -A -L 0.0.0.0:8080:localhost:8080 <hydra-username>@hydra
> ```
> 2. allow port 8080 (both udp and tcp to be sure) in your **local firewall** settings (distro-dependent), see [this guide](https://www.digitalocean.com/community/tutorials/opening-a-port-on-linux) for an example.
>
> You can check the connection by running `curl host.docker.internal:8080` in the Docker shell (`curl` likely needs to be installed manually) -- you should *not* get a timeout or destination unreachable, etc. :)

## HPC images (Apptainer/Singularity)

Committing a change to `Dockerfile`, `requirements.txt` or `entrypoint.sh` builds and pushes the project image to DockerHub in the background (the commit stays instant). On the HPC, `.container/hpc-pull.sh` pulls the matching image as a `.sif`. Full guide: [UniCloud Wiki](https://cloud.uni-graz.at/apps/files/files/302280881?dir=/AMML_shared/Organizatorial/Project%20workflow&editing=false&openfile=true).

```shell
# dev server, once per clone (after setting DOCKERHUB_TOKEN in .env)
.container/image.sh install
# dev server, daily: git image status / logs -f / stop / trigger [--force]
git image status
# HPC
git pull && .container/hpc-pull.sh cuda
```

> [!IMPORTANT]
> The `Dockerfile` intentionally pins the AMML-Python-Base image to a fixed tag (`ARG base_tag="main-<sha>"`) instead of `latest`, so that the base image never changes unnoticed and every base update triggers exactly one rebuild. Update it with `git image bump-base` (or `.container/image.sh bump-base`) and commit the `Dockerfile`. A daily GitHub Action (`.github/workflows/bump-base-image.yml`) opens a PR when a new base image is available.

### Optional: Dataset usage

Due to the complexity of correctly handing datasets of different types and structures, a decision was made to move this code to a separate repository/Python package. 

For more information see [amml-utils](https://github.com/IDeaLab-uni-graz/amml-utils).

### Optional: Using the template with PyCharm

If you want to use PyCharm for your project, the following needs to be done in addition:What needs to be done after starting a new project to use it with PyCharm:

- [ ] Set up the Python interpreter to use **Docker compose**, or possibly also Docker.
- [ ] Set the Jupyter server to listen on all addresses by adding `--ip 0.0.0.0` to _command line arguments_ for the local Jupyter connection.

In case one decides to use the **Docker Python interpreter**, it is also necessary to do:

- [ ] Make sure to have access to the gpu's in the Docker container (e.g., with the flag `--gpus all`)
- [ ] Make sure to expose the host network to the Docker container (e.g., with the flag `--add-host=host.docker.internal:host-gateway` locally or `--add-host=host.docker.internal:10.18.74.13` on Hydra)
  - Alternatively, one can set the container to use the same network as the host using `--network host`, but this does not work with Jupyter and PyCharm - in such case, replace `host.docker.internal` address with `localhost` in the source code and config
  - Note that using the host network mode for the Docker container does **not** work in general on Hydra for all users

## Structure

Description of files and directories belonging to this repository:

- `amml-python-template/` - source code directory to be renamed when using the template
  - `.../main.py` or `.../__init__.py` - entrypoint of the Python codebase
- `data/` - directory for (large) data, which should not be version controlled by default
- `tmp/` - directory for temporary outputs of operations, contents are not version controlled
- `Dockerfile` - project-specific Docker image definition, likely building upon one of the [AMML base images](https://github.com/IDeaLab-uni-graz/AMML-Python-Base)
- `docker-compose.yaml` - declarative configuration for building and running project Docker containers
- `entrypoint.sh` - custom entrypoint of the project Docker image to properly support PyCharm
- `.container/` - build & push of the project image for the HPC (`image.sh`, configured in `image.conf`) and pulling it there (`hpc-pull.sh`)
- `.githooks/` - git hooks triggering the background image build, installed by `.container/image.sh install`
