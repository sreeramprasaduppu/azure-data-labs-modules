# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/databricks_workspace
# https://registry.terraform.io/providers/databricks/databricks/latest/docs
# https://learn.microsoft.com/en-us/azure/databricks/administration-guide/cloud-configurations/azure/private-link

resource "azurerm_databricks_workspace" "adl_databricks" {
  name                = "adb-${var.basename}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku

  managed_resource_group_name           = "${var.resource_group_name}-adb-managed"
  public_network_access_enabled         = var.public_network_access_enabled
  network_security_group_rules_required = var.is_private_endpoint ? "NoAzureDatabricksRules" : "AllRules"
  custom_parameters {
    no_public_ip                                         = var.no_public_ip
    public_subnet_name                                   = var.public_subnet_name
    private_subnet_name                                  = var.private_subnet_name
    virtual_network_id                                   = var.virtual_network_id
    public_subnet_network_security_group_association_id  = var.public_subnet_network_security_group_association_id
    private_subnet_network_security_group_association_id = var.private_subnet_network_security_group_association_id
  }
  tags = var.tags

  count = var.module_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = (var.is_private_endpoint || var.public_network_access_enabled)
      error_message = "Deny public access requires a private link endpoint (is_private_endpoint set to 'true')"
    }

    precondition {
      condition     = (!var.is_private_endpoint || var.no_public_ip)
      error_message = "Private link endpoint requires No Public IP (no_public_ip set to 'true')"
    }

    precondition {
      condition     = (!var.enable_ip_access_list || var.public_network_access_enabled)
      error_message = "IP access list only applies to requests made over the Internet (public_network_access_enabled set to 'true')"
    }
  }
}

provider "databricks" {
  alias                       = "adl-adb"
  host                        = azurerm_databricks_workspace.adl_databricks[0].workspace_url
  azure_workspace_resource_id = azurerm_databricks_workspace.adl_databricks[0].id
}

resource "databricks_workspace_conf" "adb_ws_conf" {
  provider = databricks.adl-adb
  custom_config = {
    "enableIpAccessLists" : var.enable_ip_access_list
  }
  depends_on = [azurerm_databricks_workspace.adl_databricks[0]]

  count = var.module_enabled && var.enable_ip_access_list ? 1 : 0
}

resource "databricks_ip_access_list" "adb_ws_allow-list" {
  provider     = databricks.adl-adb
  label        = "allow_in"
  list_type    = "ALLOW"
  ip_addresses = var.allow_ip_list
  depends_on   = [databricks_workspace_conf.adb_ws_conf]

  count = var.module_enabled && var.enable_ip_access_list && length(var.allow_ip_list) > 0 ? 1 : 0
}

resource "databricks_ip_access_list" "adb_ws_block-list" {
  provider     = databricks.adl-adb
  label        = "block_in"
  list_type    = "BLOCK"
  ip_addresses = var.block_ip_list
  depends_on   = [databricks_workspace_conf.adb_ws_conf]

  count = var.module_enabled && var.enable_ip_access_list && length(var.block_ip_list) > 0 ? 1 : 0
}

# Private Endpoint configuration

module "adb_be_pe" {
  source                         = "../private-endpoint"
  basename                       = "${azurerm_databricks_workspace.adl_databricks[0].name}-databricks-be"
  resource_group_name            = var.resource_group_name
  location                       = var.location
  subnet_id                      = var.backend_subnet_id
  private_connection_resource_id = azurerm_databricks_workspace.adl_databricks[0].id
  subresource_names              = ["databricks_ui_api"]
  is_manual_connection           = false
  private_dns_zone_ids           = var.backend_private_dns_zone_ids
  tags                           = var.tags
  module_enabled                 = var.module_enabled && var.is_private_endpoint
}

module "adb_fe_pe" {
  source                         = "../private-endpoint"
  basename                       = "${azurerm_databricks_workspace.adl_databricks[0].name}-databricks-fe"
  resource_group_name            = var.resource_group_name
  location                       = var.location
  subnet_id                      = var.frontend_subnet_id
  private_connection_resource_id = azurerm_databricks_workspace.adl_databricks[0].id
  subresource_names              = ["databricks_ui_api"]
  is_manual_connection           = false
  private_dns_zone_ids           = var.frontend_private_dns_zone_ids
  tags                           = var.tags
  module_enabled                 = var.module_enabled && var.is_private_endpoint && (var.private_link_deployment_type == "standard")
}

module "adb_sso_pe" {
  source                         = "../private-endpoint"
  basename                       = "${azurerm_databricks_workspace.adl_databricks[0].name}-databricks-sso"
  resource_group_name            = var.resource_group_name
  location                       = var.location
  subnet_id                      = var.private_link_deployment_type == "standard" ? var.frontend_subnet_id : var.backend_subnet_id
  private_connection_resource_id = (var.private_web_auth_workspace != null) ? var.private_web_auth_workspace : azurerm_databricks_workspace.adl_databricks[0].id
  subresource_names              = ["browser_authentication"]
  is_manual_connection           = false
  private_dns_zone_ids           = var.frontend_private_dns_zone_ids
  tags                           = var.tags
  module_enabled                 = var.module_enabled && var.is_private_endpoint
}