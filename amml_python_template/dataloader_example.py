import os
import sys


utils_dir = os.path.join(os.path.dirname(os.path.realpath(__file__)), "../utils")
sys.path.append(os.path.abspath(utils_dir))
from nextcloud_data_loader import load_dataset_as_tensor

tensor = load_dataset_as_tensor("EXAMPLE", "train")
print(f"Shape of tensor: {tensor.shape}")
