# frozen_string_literal: true

require 'rails_helper'

# The pipelines list gets counts and totals from PipelineListStats (one aggregate query)
# instead of loading every item. The numbers must match the model methods exactly.
RSpec.describe PipelineListStats do
  let(:user) { User.create!(email: "stats-#{SecureRandom.hex(4)}@example.com", name: 'Stats User') }
  let!(:pipeline) { Pipeline.create!(name: 'Stats Pipeline', pipeline_type: 'sales', created_by: user) }
  let!(:stage_a) { PipelineStage.create!(pipeline: pipeline, name: 'A', position: 1) }
  let!(:stage_b) { PipelineStage.create!(pipeline: pipeline, name: 'B', position: 2) }
  let!(:empty_pipeline) { Pipeline.create!(name: 'Empty', pipeline_type: 'sales', created_by: user) }

  def add_item(stage, custom_fields)
    contact = Contact.create!(name: "Lead #{SecureRandom.hex(3)}", email: "lead-#{SecureRandom.hex(4)}@example.com")
    item = PipelineItem.create!(pipeline: stage.pipeline, pipeline_stage: stage, contact: contact,
                                entered_at: Time.current)
    # update_columns skips validations: rows written by imports/SQL can hold shapes the
    # model would reject, and the totals must still agree with services_total_value.
    item.update_columns(custom_fields: custom_fields)
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
    add_item(stage_a, { 'services' => [{ 'name' => 'x', 'value' => '100.10' }, { 'name' => 'y', 'value' => '0.20' },
                                       { 'name' => 'z', 'value' => 'abc' }] })
    add_item(stage_a, { 'services' => [{ 'name' => 'w', 'value' => 50 }] })
    add_item(stage_b, {})
    add_item(stage_b, { 'services' => 'not-an-array' })
  end

  it 'matches the model counts and totals for the pipeline and each stage' do
    stats = described_class.new([pipeline.id, empty_pipeline.id])

    expect(stats.pipeline(pipeline.id).count).to eq(pipeline.item_count)
    expect(stats.pipeline(pipeline.id).value).to eq(pipeline.total_value)
    [stage_a, stage_b].each do |stage|
      expect(stats.stage(stage.id).count).to eq(stage.item_count)
      expect(stats.stage(stage.id).value).to eq(stage.pipeline_items.sum(&:services_total_value))
    end
  end

  it 'reports zero for a pipeline without items' do
    stats = described_class.new([pipeline.id, empty_pipeline.id])

    expect(stats.pipeline(empty_pipeline.id).count).to eq(0)
    expect(stats.pipeline(empty_pipeline.id).value).to eq(empty_pipeline.total_value)
  end

  it 'produces the same serialized list as the unoptimized path' do
    options = { include_stages: true, include_items: false, include_services_info: true }
    pipelines = Pipeline.where(id: [pipeline.id, empty_pipeline.id]).includes(:pipeline_teams, pipeline_stages: [], pipeline_items: []).order(:name)

    expected = PipelineSerializer.serialize_collection(pipelines, **options)
    actual = PipelineSerializer.serialize_collection(
      Pipeline.where(id: [pipeline.id, empty_pipeline.id]).includes(:pipeline_teams, pipeline_stages: []).order(:name),
      **options, stats: described_class.new([pipeline.id, empty_pipeline.id])
    )

    expect(actual.to_json).to eq(expected.to_json)
  end

  it 'does not instantiate pipeline items' do
    built = instantiated_pipeline_items { described_class.new([pipeline.id]) }

    expect(built).to eq(0)
  end
end
