# AMML Python Template

This is the basic template for Python + Pytorch projects running on Docker at the Martin Holler's team @ IDea_Lab, University of Graz.

For more information, see the [repository of the base image](https://github.com/IDeaLab-uni-graz/AMML-Python-Base).

Run with, e.g., 
```
docker compose run --build amml-project-cpu
```

> [!NOTE]
> For PyCharm development, it is recommended one uses the **docker compose** Python interpreter (instead of only the Docker one).

## Template checklist

What needs to be done after starting a new project:

- [ ] Rename project in `docker-compose.yaml`
- [ ] Rename source folder, here `amml-python-template/`
- [ ] Write a (good) `README.md`, possibly also change a license