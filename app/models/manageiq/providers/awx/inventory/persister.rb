class ManageIQ::Providers::Awx::Inventory::Persister < ManageIQ::Providers::Inventory::Persister
  require_nested :AutomationManager
  require_nested :TargetCollection
end
