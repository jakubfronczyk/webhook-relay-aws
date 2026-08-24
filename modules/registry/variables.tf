variable "project_name" {
  description = "Project name, used as the repository namespace"
  type        = string
}

variable "services" {
  description = "Service names to create a repository for. One image per service."
  type        = list(string)
  default     = ["api", "worker"]
}

variable "retained_image_count" {
  description = "Number of recent images to keep per repository. Older ones expire."
  type        = number
  default     = 10
}
