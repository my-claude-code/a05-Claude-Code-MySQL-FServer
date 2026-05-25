terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

locals {
  prefix          = "flask-notes"
  internal_nlb_ip = "10.0.2.100"
  agw_fqdn        = "${var.agw_dns_label}.canadacentral.cloudapp.azure.com"
  mysql_fqdn      = "${var.mysql_server_name}.mysql.database.azure.com"
  cert_password   = "terraform"
}

# ── Resource Group ───────────────────────────────────────────────────────────
resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.prefix}-fserver"
  location = var.location
}

# ── Virtual Network ──────────────────────────────────────────────────────────
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${local.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "agw" {
  name                 = "subnet-agw"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.0/24"]
}

resource "azurerm_subnet" "web" {
  name                 = "subnet-web"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "app" {
  name                 = "subnet-app"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

# MySQL Flexible Server requires a dedicated delegated subnet
resource "azurerm_subnet" "mysql" {
  name                 = "subnet-mysql"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.3.0/24"]

  delegation {
    name = "mysql-delegation"
    service_delegation {
      name    = "Microsoft.DBforMySQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# ── Separate NSG per subnet (all open for testing) ───────────────────────────
resource "azurerm_network_security_group" "agw" {
  name                = "nsg-agw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow-all-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow-all-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "app" {
  name                = "nsg-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow-all-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "mysql" {
  name                = "nsg-mysql"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow-all-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "agw" {
  subnet_id                 = azurerm_subnet.agw.id
  network_security_group_id = azurerm_network_security_group.agw.id
}

resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.web.id
  network_security_group_id = azurerm_network_security_group.web.id
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

resource "azurerm_subnet_network_security_group_association" "mysql" {
  subnet_id                 = azurerm_subnet.mysql.id
  network_security_group_id = azurerm_network_security_group.mysql.id
}

# ── NAT Gateway — outbound internet for web and app tiers ────────────────────
resource "azurerm_public_ip" "nat" {
  name                = "pip-nat"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "nat" {
  name                = "nat-${local.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "nat" {
  nat_gateway_id       = azurerm_nat_gateway.nat.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "web" {
  subnet_id      = azurerm_subnet.web.id
  nat_gateway_id = azurerm_nat_gateway.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "app" {
  subnet_id      = azurerm_subnet.app.id
  nat_gateway_id = azurerm_nat_gateway.nat.id
}

# ── Public IP for Application Gateway ────────────────────────────────────────
resource "azurerm_public_ip" "agw" {
  name                = "pip-agw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = var.agw_dns_label
}

# ── Self-signed SSL certificate for Application Gateway ──────────────────────
resource "null_resource" "agw_cert" {
  triggers = {
    fqdn = local.agw_fqdn
  }

  provisioner "local-exec" {
    command = <<-EOT
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /tmp/agw.key \
        -out /tmp/agw.crt \
        -subj "/CN=${local.agw_fqdn}"
      openssl pkcs12 -export \
        -out /tmp/agw.pfx \
        -inkey /tmp/agw.key \
        -in /tmp/agw.crt \
        -passout pass:${local.cert_password}
    EOT
  }
}

data "local_file" "agw_pfx" {
  filename   = "/tmp/agw.pfx"
  depends_on = [null_resource.agw_cert]
}

# ── Application Gateway ──────────────────────────────────────────────────────
resource "azurerm_application_gateway" "agw" {
  name                = "agw-${local.prefix}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  gateway_ip_configuration {
    name      = "agw-ip-config"
    subnet_id = azurerm_subnet.agw.id
  }

  frontend_port {
    name = "port-443"
    port = 443
  }

  frontend_port {
    name = "port-80"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "agw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.agw.id
  }

  ssl_certificate {
    name     = "self-signed"
    data     = data.local_file.agw_pfx.content_base64
    password = local.cert_password
  }

  backend_address_pool {
    name = "web-backend-pool"
  }

  backend_http_settings {
    name                                = "http-settings"
    cookie_based_affinity               = "Disabled"
    port                                = 80
    protocol                            = "Http"
    request_timeout                     = 60
    probe_name                          = "http-probe"
    pick_host_name_from_backend_address = true
  }

  probe {
    name                                      = "http-probe"
    protocol                                  = "Http"
    path                                      = "/"
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 5
    pick_host_name_from_backend_http_settings = true
  }

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "agw-frontend-ip"
    frontend_port_name             = "port-443"
    protocol                       = "Https"
    ssl_certificate_name           = "self-signed"
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "agw-frontend-ip"
    frontend_port_name             = "port-80"
    protocol                       = "Http"
  }

  redirect_configuration {
    name                 = "http-to-https"
    redirect_type        = "Permanent"
    target_listener_name = "https-listener"
    include_path         = true
    include_query_string = true
  }

  request_routing_rule {
    name                       = "https-rule"
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "web-backend-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 10
  }

  request_routing_rule {
    name                        = "http-redirect-rule"
    rule_type                   = "Basic"
    http_listener_name          = "http-listener"
    redirect_configuration_name = "http-to-https"
    priority                    = 20
  }

  depends_on = [null_resource.agw_cert]
}

# ── Internal Network Load Balancer (web → app tier) ──────────────────────────
resource "azurerm_lb" "internal" {
  name                = "ilb-${local.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "ilb-frontend"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address            = local.internal_nlb_ip
    private_ip_address_allocation = "Static"
  }
}

resource "azurerm_lb_backend_address_pool" "app" {
  name            = "app-backend-pool"
  loadbalancer_id = azurerm_lb.internal.id
}

resource "azurerm_lb_probe" "app" {
  name            = "gunicorn-probe"
  loadbalancer_id = azurerm_lb.internal.id
  protocol        = "Tcp"
  port            = 5000
}

resource "azurerm_lb_rule" "app" {
  name                           = "gunicorn-rule"
  loadbalancer_id                = azurerm_lb.internal.id
  protocol                       = "Tcp"
  frontend_port                  = 5000
  backend_port                   = 5000
  frontend_ip_configuration_name = "ilb-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.app.id]
  probe_id                       = azurerm_lb_probe.app.id
}

# ── MySQL Flexible Server (private, VNet integration) ────────────────────────
resource "azurerm_private_dns_zone" "mysql" {
  name                = "privatelink.mysql.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "mysql" {
  name                  = "mysql-dns-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.mysql.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_mysql_flexible_server" "mysql" {
  name                   = var.mysql_server_name
  resource_group_name    = azurerm_resource_group.rg.name
  location               = azurerm_resource_group.rg.location
  administrator_login    = var.db_admin_login
  administrator_password = var.db_admin_password
  delegated_subnet_id    = azurerm_subnet.mysql.id
  private_dns_zone_id    = azurerm_private_dns_zone.mysql.id
  sku_name               = "B_Standard_B1ms"
  version                = "8.0.21"

  storage {
    size_gb = 20
  }

  backup_retention_days        = 1
  geo_redundant_backup_enabled = false

  depends_on = [azurerm_private_dns_zone_virtual_network_link.mysql]
}

resource "azurerm_mysql_flexible_database" "flask_notes" {
  name                = "flask_notes"
  resource_group_name = azurerm_resource_group.rg.name
  server_name         = azurerm_mysql_flexible_server.mysql.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

# Disable SSL requirement so PyMySQL can connect without SSL config
resource "azurerm_mysql_flexible_server_configuration" "ssl" {
  name                = "require_secure_transport"
  resource_group_name = azurerm_resource_group.rg.name
  server_name         = azurerm_mysql_flexible_server.mysql.name
  value               = "OFF"
}

# ── Web Tier VMSS (nginx reverse proxy) ──────────────────────────────────────
resource "azurerm_linux_virtual_machine_scale_set" "web" {
  name                            = "vmss-web"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  sku                             = var.vm_size
  instances                       = 2
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false

  custom_data = base64encode(templatefile("${path.module}/scripts/web-setup.sh", {
    internal_nlb_ip = local.internal_nlb_ip
  }))

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  network_interface {
    name    = "nic-web"
    primary = true

    ip_configuration {
      name      = "ipconfig-web"
      primary   = true
      subnet_id = azurerm_subnet.web.id

      application_gateway_backend_address_pool_ids = [
        one([for bp in azurerm_application_gateway.agw.backend_address_pool : bp.id])
      ]
    }
  }
}

# ── App Tier VMSS (gunicorn + Flask) ─────────────────────────────────────────
resource "azurerm_linux_virtual_machine_scale_set" "app" {
  name                            = "vmss-app"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  sku                             = var.vm_size
  instances                       = 2
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false

  custom_data = base64encode(templatefile("${path.module}/scripts/app-setup.sh", {
    entra_client_id     = var.entra_client_id
    entra_client_secret = var.entra_client_secret
    entra_tenant_id     = var.entra_tenant_id
    flask_secret_key    = var.flask_secret_key
    agw_fqdn            = local.agw_fqdn
    mysql_fqdn          = local.mysql_fqdn
    db_name             = "flask_notes"
    db_admin_login      = var.db_admin_login
    db_admin_password   = var.db_admin_password
  }))

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  network_interface {
    name    = "nic-app"
    primary = true

    ip_configuration {
      name      = "ipconfig-app"
      primary   = true
      subnet_id = azurerm_subnet.app.id

      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.app.id]
    }
  }

  depends_on = [
    azurerm_mysql_flexible_server_configuration.ssl,
    azurerm_mysql_flexible_database.flask_notes
  ]
}
