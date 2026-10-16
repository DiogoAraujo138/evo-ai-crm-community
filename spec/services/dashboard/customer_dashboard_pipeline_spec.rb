# frozen_string_literal: true

require 'rails_helper'

# The pipeline and channel blocks of the customer dashboard read three values per lead
# (stage, conversation inbox, services total) in a single plucked query. Numbers must
# match what the PipelineItem model computes, and no PipelineItem may be instantiated.
RSpec.describe Dashboard::CustomerDashboardService do
  let(:user) { User.create!(email: "dash-#{SecureRandom.hex(4)}@example.com", name: 'Dash User') }
  let(:pipeline) { Pipeline.create!(name: 'Dash Pipeline', pipeline_type: 'sales', created_by: user) }
  let(:stage_a) { PipelineStage.create!(pipeline: pipeline, name: 'A', position: 1) }
  let(:stage_b) { PipelineStage.create!(pipeline: pipeline, name: 'B', position: 2) }
  let(:inbox_one) { Inbox.create!(name: 'Dash Inbox 1', channel: Channel::Api.create!) }
  let(:inbox_two) { Inbox.create!(name: 'Dash Inbox 2', channel: Channel::Api.create!) }
  let(:service) { described_class.new(params: ActionController::Parameters.new({}).permit!) }

  def lead(stage, services, inbox: nil)
    contact = Contact.create!(name: "Lead #{SecureRandom.hex(3)}", email: "dash-lead-#{SecureRandom.hex(4)}@example.com")
    conversation = nil
    if inbox
      contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(4))
      conversation = Conversation.create!(contact: contact, inbox: inbox, contact_inbox: contact_inbox)
    end
    # A lead links either a conversation or a contact, never both.
    item = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, entered_at: Time.current,
                                **(conversation ? { conversation: conversation } : { contact: contact }))
    item.update_columns(custom_fields: { 'services' => services })
    item
  end

  # Counts PipelineItem records Active Record builds while the block runs.
  def instantiated_pipeline_items
    count = 0
    callback = lambda do |*, payload|
      count += payload[:record_count].to_i if payload[:class_name] == 'PipelineItem'
    end
    ActiveSupport::Notifications.subscribed(callback, 'instantiation.active_record') { yield }
    count
  end

  before do
    lead(stage_a, [{ 'name' => 'x', 'value' => '100.10' }, { 'name' => 'y', 'value' => '0.20' }], inbox: inbox_one)
    lead(stage_a, [{ 'name' => 'z', 'value' => 50 }], inbox: inbox_two)
    lead(stage_b, [{ 'name' => 'w', 'value' => 'abc' }], inbox: inbox_one)
    lead(stage_b, 'not-an-array')
  end

  it 'reports pipeline totals and per-stage counts that match the model' do
    block = service.send(:build_pipeline)
    items = PipelineItem.all.to_a

    expect(block[:total]).to eq(items.size)
    expect(block[:total_value]).to eq(items.sum(&:services_total_value).round(2))

    by_stage = block[:stages].index_by { |stage| stage[:id] }
    [stage_a, stage_b].each do |stage|
      stage_items = items.select { |item| item.pipeline_stage_id == stage.id }
      expect(by_stage[stage.id]).to include(name: stage.name, count: stage_items.size,
                                            value: stage_items.sum(&:services_total_value).round(2))
    end
  end

  it 'reports the lead value of each channel, ignoring leads without a conversation' do
    channels = service.send(:build_channels).index_by { |channel| channel[:id] }

    expect(channels[inbox_one.id][:value]).to eq(100.3)
    expect(channels[inbox_two.id][:value]).to eq(50.0)
  end

  it 'does not instantiate pipeline items to build the pipeline and channel blocks' do
    built = instantiated_pipeline_items do
      service.send(:build_pipeline)
      service.send(:build_channels)
    end

    expect(built).to eq(0)
  end
end
