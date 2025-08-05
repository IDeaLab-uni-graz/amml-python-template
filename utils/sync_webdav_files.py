from nc_py_api import Nextcloud
import os
import zipfile

# If .env is not loaded in the docker-compose
# from dotenv import load_dotenv
# load_dotenv("../.env")

# create Nextcloud client instance class
print("Setting up Nextcloud connection...")
nc = Nextcloud(
    nextcloud_url=os.getenv("NEXTCLOUD_URL"),
    nc_auth_user=os.getenv("NEXTCLOUD_USERNAME"),
    nc_auth_pass=os.getenv("NEXTCLOUD_PASSWORD"))

tmp_path = "../tmp/webdav_files.zip"

print("Downloading files...")
zip_path = nc.files.download_directory_as_zip("WebDAV_Benchmark/", tmp_path)

print("Extracting files...")
with zipfile.ZipFile(zip_path, "r") as zip_ref:
    zip_ref.extractall("../data")

os.remove(tmp_path)