# --------------------------------------------------------------- #
# ------------- Main Cofiguration Files Variables --------------- #
# --------------------------------------------------------------- #

variable "project_id" {
  type        = string
  description = "The Google Cloud project ID where resources will be deployed"
}

variable "region" {
  type        = string
  description = "The region where resources will be deployed"
}

variable "zone" {
  type        = string
  description = "The zone where resources will be deployed"
}