from dotenv import load_dotenv
import importlib.util
from nc_py_api import Nextcloud
import os
import pathlib
import sys
import zipfile


def load_env_file():
    dir_path = os.path.dirname(os.path.realpath(__file__))
    env_file = os.path.join(dir_path, "../.env")
    if pathlib.Path(env_file).is_file():
        load_dotenv(env_file)
    else:
        print("WARNING: .env file not found!")


def get_base_dir():
    load_env_file()
    base_dir = os.getenv("BASE_DIRECTORY")
    # Alternative option, maybe even better!
    # Assumes that the folder above the one containing this script is the base directory!
    #dir_path = os.path.dirname(os.path.realpath(__file__))
    #base_dir = os.path.join(dir_path, "../")
    return base_dir


def nextcloud_login():
    load_env_file()

    # create Nextcloud client instance class
    print("Setting up Nextcloud connection...")
    nc = Nextcloud(
        nextcloud_url=os.getenv("NEXTCLOUD_URL"),
        nc_auth_user=os.getenv("NEXTCLOUD_USERNAME"),
        nc_auth_pass=os.getenv("NEXTCLOUD_PASSWORD"))
    return nc


def list_directory(directory):
    nc = nextcloud_login()
    print("Files on the instance for the selected user:")

    def list_dir(direc):
        # usual recursive traversing over directories
        for node in nc.files.listdir(direc):
            if node.is_dir:
                list_dir(node)
            else:
                print(f"{node.user_path}")

    list_dir(directory)


def _download_files(directory, override=False):
    load_env_file()

    base_dir = get_base_dir()
    tmp_path = os.path.join(base_dir, os.getenv("TMP_DIRECTORY"), "webdav_files.zip")
    data_dir = os.path.join(base_dir, os.getenv("DATA_DIRECTORY"))

    if os.path.exists(os.path.join(data_dir, pathlib.Path(directory).name)) and not override:
        print("Folder already present...")
        return

    nc = nextcloud_login()

    print("Downloading files...")
    zip_path = nc.files.download_directory_as_zip(directory, tmp_path)

    print("Extracting files...")
    with zipfile.ZipFile(zip_path, "r") as zip_ref:
        zip_ref.extractall(data_dir)

    os.remove(tmp_path)


def download_dataset(dataset_name, override=False):
    assert dataset_name in get_available_datasets()
    print(f"Loading dataset '{dataset_name}'...")
    load_env_file()
    _download_files(os.path.join(os.getenv("DATASETS_DIRECTORY"), dataset_name), override=override)
    base_dir = get_base_dir()
    data_dir = os.path.join(base_dir, os.getenv("DATA_DIRECTORY"))
    spec = importlib.util.spec_from_file_location("load_" + dataset_name, os.path.join(data_dir, dataset_name, "load_data.py"))
    mfs = importlib.util.module_from_spec(spec)
    sys.modules["load_" + dataset_name] = mfs
    spec.loader.exec_module(mfs)
    mfs.download_dataset(data_dir)


def _get_load_data_module(dataset_name):
    load_env_file()

    base_dir = get_base_dir()
    data_dir = os.path.join(base_dir, os.getenv("DATA_DIRECTORY"), dataset_name)

    spec = importlib.util.spec_from_file_location("load_" + dataset_name, os.path.join(data_dir, "load_data.py"))
    mfs = importlib.util.module_from_spec(spec)
    sys.modules["load_" + dataset_name] = mfs
    spec.loader.exec_module(mfs)
    return mfs, data_dir


def get_available_datasets():
    list_available_datasets = []
    load_env_file()
    nc = nextcloud_login()
    for node in nc.files.listdir(os.getenv("DATASETS_DIRECTORY")):
        if node.is_dir:
            list_available_datasets.append(node.name)
    return list_available_datasets


def load_dataset_as_tensor(dataset_name, data_type="full", override=False):
    assert dataset_name in get_available_datasets()
    assert data_type in ["full", "train", "test", "val"]
    download_dataset(dataset_name, override=override)
    mfs, data_dir = _get_load_data_module(dataset_name)
    return mfs.load_dataset_as_tensor(data_dir, data_type)


def get_dataset(dataset_name, data_type="full", override=False, **kwargs):
    assert dataset_name in get_available_datasets()
    assert data_type in ["full", "train", "test", "val"]
    download_dataset(dataset_name, override=override)
    mfs, data_dir = _get_load_data_module(dataset_name)
    return mfs.CustomDataset(data_dir, data_type, **kwargs)


if __name__ == "__main__":
    print("List of available datasets:")
    for dataset in get_available_datasets():
        print(dataset)