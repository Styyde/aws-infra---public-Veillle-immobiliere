# backend.tf
# TEMPORAIREMENT DÉSACTIVÉ POUR TESTS LOCAUX
# terraform {
#   backend "s3" {
#     bucket         = "veille-immo-terraform-state"
#     key            = "prod/terraform.tfstate"
#     region         = "eu-west-3"
#     dynamodb_table = "terraform-locks"
#     encrypt        = true
#   }
# }