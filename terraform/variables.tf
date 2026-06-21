variable "sel_domain" {
  type = string
  description = "Номер аккаунта в Selectel"
}

variable "sel_username" {
  type = string
  description = "Имя пользователя панели управления"
}

variable "sel_password" {
  type = string
  description = "Пароль пользователя панели управления"
  sensitive = true
}

variable "sel_service_account_username" {
  type = string
  description = "Имя сервисного аккаунта"
}

variable "sel_service_account_password" {
  type = string
  description = "Пароль сервисного аккаунта"
  sensitive = true
}