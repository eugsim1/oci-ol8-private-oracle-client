terraform {
  required_version = ">= 1.9.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 8.24.0, < 9.0.0"
    }
  }
}
