terraform {
  required_version = ">= 1.9.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 8.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.13"
    }
  }
}
