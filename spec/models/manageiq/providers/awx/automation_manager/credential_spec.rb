require 'ansible_tower_client'

describe ManageIQ::Providers::Awx::AutomationManager::ScmCredential do
  let(:manager) do
    FactoryBot.create(:provider_awx, :with_authentication).managers.first
  end
  let(:finished_task) { FactoryBot.create(:miq_task, :state => "Finished") }
  let(:atc)           { double("AnsibleTowerClient::Connection", :api => api) }
  let(:api)           { double("AnsibleTowerClient::Api", :credentials => credentials) }

  context "Tower 3.3 needs pk as integer" do
    let(:machine_credential) { FactoryBot.create(:awx_machine_credential, :manager_ref => '1', :resource => manager) }
    it "native_ref returns integer" do
      expect(machine_credential.manager_ref).to eq('1')
      expect(machine_credential.native_ref).to eq(1)
    end

    it "native_ref blows up for nil manager_ref" do
      machine_credential.manager_ref = nil
      expect(machine_credential.manager_ref).to be_nil
      expect{ machine_credential.native_ref }.to raise_error(TypeError)
    end
  end

  context "Create through API" do
    let(:credentials)     { double("AnsibleTowerClient::Collection", :create! => credential) }
    let(:credential)      { AnsibleTowerClient::Credential.new(nil, credential_json) }
    let(:credential_json) do
      params.merge(
        :id => 10,
      ).stringify_keys.to_json
    end
    let(:params) do
      {
        :description => "Description",
        :name        => "My Credential",
        :related     => {},
        :userid      => 'john'
      }
    end
    let(:expected_params) do
      {
        :description => "Description",
        :name        => "My Credential",
        :related     => {},
        :username    => "john",
        :kind        => described_class::TOWER_KIND
      }
    end
    let(:expected_notify) do
      {
        :type    => :tower_op_success,
        :options => {
          :op_name => "#{described_class::FRIENDLY_NAME} creation",
          :op_arg  => "(name=My Credential)",
          :tower   => "EMS(manager_id=#{manager.id})"
        }
      }
    end

    it ".create_in_provider to succeed and send notification" do
      expected_params[:organization] = 1 if described_class.name.include?("::EmbeddedAnsible::")
      expect(Vmdb::Settings).to receive(:decrypt_passwords!).with(expected_params)
      expect(AnsibleTowerClient::Connection).to receive(:new).and_return(atc)
      store_new_credential(credential, manager)
      expect(EmsRefresh).to receive(:queue_refresh_task).with(manager).and_return([finished_task.id])
      expect(ExtManagementSystem).to receive(:find).with(manager.id).and_return(manager)
      expect(credentials).to receive(:create!).with(expected_params)
      expect(Notification).to receive(:create).with(expected_notify)
      expect(described_class.create_in_provider(manager.id, params)).to be_a(described_class)
    end

    it ".create_in_provider to fail (not found during refresh) and send notification" do
      expected_params[:organization] = 1 if described_class.name.include?("::EmbeddedAnsible::")
      expect(Vmdb::Settings).to receive(:decrypt_passwords!).with(expected_params)
      expect(AnsibleTowerClient::Connection).to receive(:new).and_return(atc)
      expect(EmsRefresh).to receive(:queue_refresh_task).and_return([finished_task.id])
      expect(ExtManagementSystem).to receive(:find).with(manager.id).and_return(manager)
      expect(credentials).to receive(:create!).with(expected_params)
      expected_notify[:type] = :tower_op_failure
      expect(Notification).to receive(:create).with(expected_notify).and_return(double(Notification))
      expect { described_class.create_in_provider(manager.id, params) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it ".create_in_provider_queue" do
      expect(Vmdb::Settings).to receive(:encrypt_passwords!).with(params)
      task_id = described_class.create_in_provider_queue(manager.id, params)
      expect(MiqTask.find(task_id)).to have_attributes(:name => "Creating #{described_class::FRIENDLY_NAME} (name=#{params[:name]})")
      expect(MiqQueue.first).to have_attributes(
        :args        => [manager.id, params],
        :class_name  => described_class.name,
        :method_name => "create_in_provider",
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => "ems_operations",
        :zone        => manager.my_zone
      )
    end

    it ".create_in_provider_queue to fail with incompatible manager" do
      wrong_manager = FactoryBot.create(:configuration_manager_foreman)
      expect { described_class.create_in_provider_queue(wrong_manager.id, params) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    def store_new_credential(credential, manager)
      described_class.create!(
        :resource    => manager,
        :manager_ref => credential.id.to_s,
        :name        => credential.name,
      )
    end
  end

  context "Delete through API" do
    let(:credentials)   { double("AnsibleTowerClient::Collection", :find => credential) }
    let(:credential)    { double("AnsibleTowerClient::Credential", :destroy! => nil, :id => '1') }
    let(:awx_cred)  { described_class.create!(:resource => manager, :manager_ref => credential.id) }
    let(:expected_notify) do
      {
        :type    => :tower_op_success,
        :options => {
          :op_name => "#{described_class::FRIENDLY_NAME} deletion",
          :op_arg  => "(manager_ref=#{credential.id})",
          :tower   => "EMS(manager_id=#{manager.id})"
        }
      }
    end

    it "#delete_in_provider to succeed and send notification" do
      expect(AnsibleTowerClient::Connection).to receive(:new).and_return(atc)
      expect(EmsRefresh).to receive(:queue_refresh_task).and_return([finished_task.id])
      expect(Notification).to receive(:create).with(expected_notify)
      awx_cred.delete_in_provider
    end

    it "#delete_in_provider to fail (finding credential) and send notification" do
      expect(AnsibleTowerClient::Connection).to receive(:new).and_return(atc)
      allow(credentials).to receive(:find).and_raise(AnsibleTowerClient::ClientError)
      expected_notify[:type] = :tower_op_failure
      expect(Notification).to receive(:create).with(expected_notify)
      expect { awx_cred.delete_in_provider }.to raise_error(AnsibleTowerClient::ClientError)
    end

    it "#delete_in_provider_queue" do
      task_id = awx_cred.delete_in_provider_queue
      expect(MiqTask.find(task_id)).to have_attributes(:name => "Deleting #{described_class::FRIENDLY_NAME} (Tower internal reference=#{awx_cred.manager_ref})")
      expect(MiqQueue.first).to have_attributes(
        :instance_id => awx_cred.id,
        :args        => [],
        :class_name  => described_class.name,
        :method_name => "delete_in_provider",
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => "ems_operations",
        :zone        => manager.my_zone
      )
    end
  end

  context "Update through API" do
    let(:credentials)     { double("AnsibleTowerClient::Collection", :find => credential) }
    let(:credential)      { double("AnsibleTowerClient::Credential", :id => 1) }
    let(:awx_cred)    { described_class.create!(:resource => manager, :manager_ref => credential.id) }
    let(:params)          { {:userid => 'john', :miq_task_id => 1, :task_id => 1} }
    let(:expected_params) { {:username => 'john', :kind => described_class::TOWER_KIND} }
    let(:expected_notify) do
      {
        :type    => :tower_op_success,
        :options => {
          :op_name => "#{described_class::FRIENDLY_NAME} update",
          :op_arg  => "()",
          :tower   => "EMS(manager_id=#{manager.id})"
        }
      }
    end

    it "#update_in_provider to succeed and send notification" do
      expect(Vmdb::Settings).to receive(:decrypt_passwords!).with(params)
      expected_params[:organization] = 1 if described_class.name.include?("::EmbeddedAnsible::")
      expect(AnsibleTowerClient::Connection).to receive(:new).and_return(atc)
      expect(credential).to receive(:update!).with(expected_params)
      expect(EmsRefresh).to receive(:queue_refresh_task).and_return([finished_task.id])
      expect(Notification).to receive(:create).with(expected_notify)
      expect(awx_cred.update_in_provider(params)).to be_a(described_class)
    end

    it "#update_in_provider to fail (doing update!) and send notification" do
      expected_params[:organization] = 1 if described_class.name.include?("::EmbeddedAnsible::")
      expect(AnsibleTowerClient::Connection).to receive(:new).and_return(atc)
      expect(credential).to receive(:update!).with(expected_params).and_raise(AnsibleTowerClient::ClientError)
      expected_notify[:type] = :tower_op_failure
      expect(Notification).to receive(:create).with(expected_notify).and_return(double(Notification))
      expect { awx_cred.update_in_provider(params) }.to raise_error(AnsibleTowerClient::ClientError)
    end

    it "#update_in_provider_queue" do
      expect(Vmdb::Settings).to receive(:encrypt_passwords!).with(params)
      task_id = awx_cred.update_in_provider_queue(params)
      expect(MiqTask.find(task_id)).to have_attributes(:name => "Updating #{described_class::FRIENDLY_NAME} (Tower internal reference=#{awx_cred.manager_ref})")
      params[:task_id] = task_id
      expect(MiqQueue.first).to have_attributes(
        :instance_id => awx_cred.id,
        :args        => [params],
        :class_name  => described_class.name,
        :method_name => "update_in_provider",
        :priority    => MiqQueue::HIGH_PRIORITY,
        :role        => "ems_operations",
        :zone        => manager.my_zone
      )
    end
  end
end
