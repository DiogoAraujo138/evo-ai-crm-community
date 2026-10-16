# frozen_string_literal: true

# Item count and services total per pipeline and per stage, computed with ONE query
# that plucks only `custom_fields->'services'`. The pipelines list needs these numbers
# for every card but never the items themselves, so it must not instantiate them.
#
# Values go through PipelineItem.services_value and are summed with Array#sum, the same
# rule and the same summation as Pipeline#total_value / PipelineStage#pipeline_items.sum.
class PipelineListStats
  Totals = Struct.new(:count, :value)
  EMPTY = Totals.new(0, 0).freeze

  def initialize(pipeline_ids)
    pipeline_values = Hash.new { |hash, key| hash[key] = [] }
    stage_values = Hash.new { |hash, key| hash[key] = [] }

    rows = PipelineItem.where(pipeline_id: pipeline_ids)
                       .pluck(:pipeline_id, :pipeline_stage_id, Arel.sql("custom_fields->'services'"))
    rows.each do |pipeline_id, stage_id, services|
      value = PipelineItem.services_value(services)
      pipeline_values[pipeline_id] << value
      stage_values[stage_id] << value
    end

    @pipelines = totals_from(pipeline_values)
    @stages = totals_from(stage_values)
  end

  def pipeline(id)
    @pipelines.fetch(id, EMPTY)
  end

  def stage(id)
    @stages.fetch(id, EMPTY)
  end

  private

  def totals_from(values_by_id)
    values_by_id.transform_values { |values| Totals.new(values.size, values.sum) }
  end
end
