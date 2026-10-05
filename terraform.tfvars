subscription_id      = "8ef2bbd6-812a-4a98-a662-76228574fc04"
location             = "australiaeast"
resource_group_name  = "bigwx-rg-kvrot-sri"
name_prefix          = "kvrot-sri"
storage_account_name = "bigwxkvrotsri"

# Storage accounts in bigwx-rg-sri (the policy's scope) are covered automatically. List only
# accounts outside it here.
rotation_storage_accounts = {}

alert_email = "sri@test.com"

# Turn on after the function code is deployed
create_remediation = true
