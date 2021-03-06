class ManageIQ::Providers::Awx::AutomationManager::EventCatcher::Stream
  class ProviderUnreachable < ManageIQ::Providers::BaseManager::EventCatcher::Runner::TemporaryFailure
  end

  def initialize(ems, options = {})
    @ems = ems
    @last_activity = nil
    @stop_polling = false
    @poll_sleep = options[:poll_sleep] || 20.seconds
  end

  def start
    @stop_polling = false
  end

  def stop
    @stop_polling = true
  end

  def poll
    @ems.with_provider_connection do |awx|
      catch(:stop_polling) do
        begin
          loop do
            awx.api.activity_stream.all(filter).each do |activity|
              throw :stop_polling if @stop_polling
              yield activity.to_h
              self.last_activity = activity
            end
            sleep @poll_sleep
          end
        rescue => exception
          provider_module = ManageIQ::Providers::Inflector.provider_module(self.class)
          raise provider_module::AutomationManager::EventCatcher::Stream::ProviderUnreachable, exception.message
        end
      end
    end
  end

  private

  def last_activity=(activity)
    @last_activity = activity
  end

  def last_activity
    @last_activity ||= begin
      @ems.with_provider_connection do |awx|
        awx.api.activity_stream.all(:order_by => '-id').first
      end
    end
  end

  def filter
    if last_activity
      {
        :order_by => 'id',
        :id__gt   => last_activity.id
      }
    else
      { :order_by => 'id'}
    end
  end
end
