variable "aws_region" {
  description = "Región de AWS donde desplegar"
  default     = "us-east-1"
}

variable "tailscale_auth_key" {
  description = "La clave Auth Key Reusable de Tailscale"
  type        = string
  sensitive   = true
}

variable "vps_monitoring_ip" {
  description = "La IP de Tailscale del VPS de OVH"
  type        = string
}

variable "db_password" {
  description = "Contraseña SA para SQL Server"
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Nombre del proyecto para etiquetas"
  default     = "sql-observability-lab"
}
