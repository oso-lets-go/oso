# Terraform module for setting up the data warehouse. These modules
# are provided so that one could easily replicate the infrastructure required to
# run the data warehouse. 

# Once the OpenTofu registry is GA, we will publish this terraform code to the
# OpenTofu registry.

# What does this module provide?
# 
# - A publicly accessible BigQuery Dataset
# - A CloudSQL instance
# - A bucket to allow for transfers from bigquery to cloudsql
# - A service accounts that can be used by DBT and bq2cloudsql

data "google_project" "project" {}

locals {
  admin_service_account_name    = "${var.name}-admin"
  readonly_service_account_name = "${var.name}-readonly"
  cloudsql_name                 = "${var.name}-psql"
  cloudsql_db_user              = "${var.name}-admin"
  dataset_id                    = replace(var.name, "-", "_")
}

###
# Google service account to administer the data warehouse
###
resource "google_service_account" "warehouse_admin" {
  account_id   = local.admin_service_account_name
  display_name = "Admin service account for ${var.name}"
}

###
# Read only service account - for outside applications to use
###
resource "google_service_account" "warehouse_readonly" {
  account_id   = local.readonly_service_account_name
  display_name = "Read only service account for ${var.name}"
}


###
# BigQuery Dataset
###
resource "google_bigquery_dataset" "dataset" {
  dataset_id    = local.dataset_id
  friendly_name = var.dataset_name
  description   = var.dataset_description
  location      = var.dataset_location

  labels = {
    environment = var.environment
    dw_name     = var.name
  }

  access {
    role          = "OWNER"
    user_by_email = google_service_account.warehouse_admin.email
  }

  ###
  # Allow public access
  ###
  access {
    role          = "READER"
    special_group = "allAuthenticatedUsers"
  }
}

###
# GCS Bucket
###
resource "google_storage_bucket" "dataset_transfer" {
  name          = "${var.name}-dataset-transfer-bucket"
  location      = var.dataset_location
  force_destroy = true

  uniform_bucket_level_access = true
}

###
# CloudSQL instance
###
module "warehouse_cloudsql" {
  source  = "GoogleCloudPlatform/sql-db/google//modules/postgresql"
  version = "8.0.0"

  project_id       = data.google_project.project.project_id
  database_version = var.cloudsql_postgres_version
  tier             = var.cloudsql_tier
  user_name        = local.cloudsql_db_user
  zone             = var.cloudsql_zone
  name             = local.cloudsql_name
  user_labels = {
    dw_name = var.name
  }
  ip_configuration = var.cloudsql_ip_configuration
}

###
# Add permissions for the cloudsql user to read from the bucket
###
resource "google_storage_bucket_iam_member" "cloudsql_member" {
  bucket = google_storage_bucket.dataset_transfer.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.warehouse_cloudsql.instance_service_account_email_address}"
}

###
# Service account permissions
###
resource "google_project_iam_custom_role" "readonly_custom_role" {
  role_id     = "${local.dataset_id}_readonly"
  title       = "Read-Only Role for ${local.dataset_id}"
  description = "Read-Only Role for ${local.dataset_id}"
  permissions = [
    "bigquery.datasets.get",
    "bigquery.datasets.getIamPolicy",
    "bigquery.jobs.create",
    "bigquery.models.export",
    "bigquery.models.getData",
    "bigquery.models.getMetadata",
    "bigquery.models.list",
    "bigquery.routines.get",
    "bigquery.routines.list",
    "bigquery.tables.createSnapshot",
    "bigquery.tables.export",
    "bigquery.tables.get",
    "bigquery.tables.getData",
    "bigquery.tables.getIamPolicy",
    "bigquery.tables.list",
    "resourcemanager.projects.get",
  ]
}


resource "google_project_iam_member" "service_account_binding" {
  project = data.google_project.project.project_id
  role    = "roles/cloudsql.admin"

  member = "serviceAccount:${google_service_account.warehouse_admin.email}"

  condition {
    expression  = "resource.name == 'projects/${data.google_project.project.project_id}/instances/${var.cloudsql_name}' && resource.type == 'sqladmin.googleapis.com/Instance'"
    title       = "created"
    description = "Cloud SQL instance creation"
  }
}

resource "google_storage_bucket_iam_member" "member" {
  bucket = google_storage_bucket.dataset_transfer.name
  role   = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.warehouse_admin.email}"
}

resource "google_bigquery_dataset_iam_member" "readonly" {
  dataset_id = local.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.warehouse_readonly.email}"
}

resource "google_project_iam_member" "readonly_custom_role" {
  project = data.google_project.project.project_id
  role    = google_project_iam_custom_role.readonly_custom_role.id
  member  = "serviceAccount:${google_service_account.warehouse_readonly.email}"

  condition {
    expression  = "resource.name.startsWith('projects/${data.google_project.project.project_id}/datasets/${google_bigquery_dataset.dataset.dataset_id}')"
    title       = "restrict_to_dataset"
    description = "restrict bigquery readonly to ${local.dataset_id}"
  }
}
