terraform {
  required_providers {
    selectel  = {
      source  = "selectel/selectel"
      version = "~> 7.1.0"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "2.1.0"
    }
  }
}

# Авторизация в панели Selectel 
provider "selectel" {
  domain_name = var.sel_domain
  username    = var.sel_username
  password    = var.sel_password
  auth_region = "ru-9"
  auth_url    = "https://cloud.api.selcloud.ru/identity/v3/"
}

resource "selectel_vpc_project_v2" "project_1" {
  name = "project"
}

# Создание пользователя для управления инфраструктурой
resource "selectel_iam_serviceuser_v1" "serviceuser_1" {
  name         = var.sel_service_account_username
  password     = var.sel_service_account_password
  role {
    role_name  = "member"
    scope      = "project"
    project_id = selectel_vpc_project_v2.project_1.id
  }
}

# Авторизация в OpenStack для создания ВМ и сетей
provider "openstack" {
  auth_url    = "https://cloud.api.selcloud.ru/identity/v3"
  domain_name = "526898"
  tenant_id   = selectel_vpc_project_v2.project_1.id
  user_name   = selectel_iam_serviceuser_v1.serviceuser_1.name
  password    = selectel_iam_serviceuser_v1.serviceuser_1.password
  region      = "ru-9"
}

# Создание базовой сети (L2)
resource "openstack_networking_network_v2" "network_1" {
  name           = "private-network"
  admin_state_up = "true"

  depends_on = [
    selectel_vpc_project_v2.project_1,
    selectel_iam_serviceuser_v1.serviceuser_1
  ]
}

# Создание подсети 
resource "openstack_networking_subnet_v2" "subnet_1" {
  name       = "private-subnet"
  network_id = openstack_networking_network_v2.network_1.id
  cidr       = "192.168.199.0/24"
}

# Привязать SSH ключ
resource "selectel_vpc_keypair_v2" "keypair_1" {
  name       = "keypair"
  public_key = file("~/.ssh/id_ed25519.pub")
  user_id    = selectel_iam_serviceuser_v1.serviceuser_1.id
}

# Создание облачного роутера
data "openstack_networking_network_v2" "external_network_1" {
  external = true
}

resource "openstack_networking_router_v2" "router_1" {
  name                = "router"
  external_network_id = data.openstack_networking_network_v2.external_network_1.id
}

resource "openstack_networking_router_interface_v2" "router_interface_1" {
  router_id = openstack_networking_router_v2.router_1.id
  subnet_id = openstack_networking_subnet_v2.subnet_1.id
}

# Создание порта для облачного сервера
resource "openstack_networking_port_v2" "port_1" {
  name       = "port"
  network_id = openstack_networking_network_v2.network_1.id

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.subnet_1.id
  }
}

# Публичный образ
data "openstack_images_image_v2" "image_1" {
  name        = "Ubuntu 24.04 LTS 64-bit"
  most_recent = true
  visibility  = "public"
}

# Создание загрузочного сетевого диска
resource "openstack_blockstorage_volume_v3" "volume_1" {
  name                 = "boot-volume-for-server"
  size                 = "20"
  image_id             = data.openstack_images_image_v2.image_1.id
  volume_type          = "fast.ru-9a"
  availability_zone    = "ru-9a"
  enable_online_resize = true

  lifecycle {
    ignore_changes = [image_id]
  }

}

# Создание ВМ
resource "openstack_compute_instance_v2" "server_1" {
  name              = "server"
  flavor_id         = "1011"
  key_pair          = selectel_vpc_keypair_v2.keypair_1.name
  availability_zone = "ru-9a"

  network {
    port = openstack_networking_port_v2.port_1.id
  }

  lifecycle {
    ignore_changes = [image_id]
  }

  block_device {
    uuid             = openstack_blockstorage_volume_v3.volume_1.id
    source_type      = "volume"
    destination_type = "volume"
    boot_index       = 0
  }

  vendor_options {
    ignore_resize_confirmation = true
  }
}

# Создание публичного адреса 
resource "openstack_networking_floatingip_v2" "floatingip_1" {
  pool = "external-network"
}

# Привязка ip к ВМы
resource "openstack_networking_floatingip_associate_v2" "association_1" {
  port_id     = openstack_networking_port_v2.port_1.id
  floating_ip = openstack_networking_floatingip_v2.floatingip_1.address
}

# Получить IP-адрес облачного сервера
output "public_ip_address" {
  value = openstack_networking_floatingip_v2.floatingip_1.fixed_ip
}



