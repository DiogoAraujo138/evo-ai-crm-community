class Api::V1::EvoFlow::CampaignsController < Api::V1::BaseController
  include EvoFlowProxy

  PERMISSION_KEYS = %w[
    campaigns.read campaigns.create campaigns.update campaigns.delete
    campaigns.schedule campaigns.execute campaigns.pause campaigns.resume campaigns.stop
    campaigns.duplicate campaigns.bulk_action
  ].freeze
  PERMISSION_KEYS.each { |key| EvoPermissionConcern.register_permission_key(key) }

  # POST /campaigns/:id/<action> and POST /campaigns/bulk-action, by last segment.
  ACTION_PERMISSIONS = {
    'schedule' => 'campaigns.schedule',
    'execute' => 'campaigns.execute',
    'pause' => 'campaigns.pause',
    'resume' => 'campaigns.resume',
    'stop' => 'campaigns.stop',
    'duplicate' => 'campaigns.duplicate',
    'bulk-action' => 'campaigns.bulk_action'
  }.freeze

  private

  def evo_flow_resource
    'campaigns'
  end

  def required_permission_key
    sub = params[:path].to_s.downcase

    case request.request_method_symbol
    when :get, :head then 'campaigns.read'
    when :delete     then 'campaigns.delete'
    when :post       then sub.empty? ? 'campaigns.create' : ACTION_PERMISSIONS.fetch(sub.split('/').last, 'campaigns.update')
    else 'campaigns.update'
    end
  end
end
