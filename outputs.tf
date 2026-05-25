output "app_url" {
  description = "Application URL"
  value       = "https://${azurerm_public_ip.agw.fqdn}"
}

output "mysql_fqdn" {
  description = "MySQL Flexible Server private FQDN"
  value       = local.mysql_fqdn
}

output "ACTION_REQUIRED" {
  description = "Add this redirect URI to Azure AD app registration once"
  value       = "Go to Azure AD > App registrations > your app > Authentication > Redirect URIs and add: https://${azurerm_public_ip.agw.fqdn}/auth/callback"
}
