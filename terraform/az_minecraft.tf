terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
    remote = {
      source = "tenstad/remote"
    }
  }
}

provider "azurerm" {
    features {}
}
provider "remote" {}
variable "az_private_key" {}
variable "az_username" {}
variable "az_location" {}
variable "az_instance_type" {}

resource "azurerm_resource_group" "tf-test-app" {
  name     = "terraform-test-resources"
  location = var.az_location
}

resource "azurerm_virtual_network" "mainnet" {
  name                = "main-network"
  address_space       = ["172.25.15.0/24"]
  location            = azurerm_resource_group.tf-test-app.location
  resource_group_name = azurerm_resource_group.tf-test-app.name
}

resource "azurerm_subnet" "pub-subnet" {
  name                 = "public"
  resource_group_name  = azurerm_resource_group.tf-test-app.name
  virtual_network_name = azurerm_virtual_network.mainnet.name
  address_prefixes     = ["172.25.15.128/25"]
}

resource "azurerm_public_ip" "pub-ip" {
  name                 = "pub-ip"
  resource_group_name  = azurerm_resource_group.tf-test-app.name
  location            = azurerm_resource_group.tf-test-app.location
  allocation_method       = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "app-nic" {
  name                = "app-nic"
  location            = azurerm_resource_group.tf-test-app.location
  resource_group_name = azurerm_resource_group.tf-test-app.name

  ip_configuration {
    name                          = "public"
    subnet_id                     = azurerm_subnet.pub-subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pub-ip.id
  }
}

resource "azurerm_linux_virtual_machine" "test-instance" {
  name                = "tf-machine"
  resource_group_name = azurerm_resource_group.tf-test-app.name
  location            = azurerm_resource_group.tf-test-app.location
  size                = var.az_instance_type
  admin_username      = var.az_username
  network_interface_ids = [
    azurerm_network_interface.app-nic.id,
  ]

  admin_ssh_key {
    username   = var.az_username
    public_key = file("${var.az_private_key}.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Debian"
    offer     = "debian-13"
    sku       = "13-arm64"
    version   = "latest"
  }
}

resource "azurerm_network_security_group" "app-sec-group" {
  name                = "apptestgroup"
  location            = azurerm_resource_group.tf-test-app.location
  resource_group_name = azurerm_resource_group.tf-test-app.name

  security_rule {
    name                       = "testrule"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = [
        "22",
        "25565"
    ]
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "instance-group-assoc" {
  network_interface_id      = azurerm_network_interface.app-nic.id
  network_security_group_id = azurerm_network_security_group.app-sec-group.id
}

resource "terraform_data" "ansible_minecraft" {
  depends_on = [
    azurerm_public_ip.pub-ip,
    azurerm_linux_virtual_machine.test-instance,
    azurerm_network_interface_security_group_association.instance-group-assoc
  ]
  provisioner "local-exec" {
    command = "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u ${var.az_username} -i '${azurerm_public_ip.pub-ip.ip_address},' --private-key ${var.az_private_key} --tags 'common, minecraft' ../ansible/site2.yml"
  }
}


output "instance_public_ip" {
  value = azurerm_public_ip.pub-ip.ip_address
}
