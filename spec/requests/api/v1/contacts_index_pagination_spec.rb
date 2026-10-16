# frozen_string_literal: true

require 'rails_helper'

# Regression: GET /api/v1/contacts must only load one page of contacts.
# fetch_contacts used to materialize the whole relation (`.map(&:id)`) before pagination,
# so every listing loaded all contacts with their conversations.
RSpec.describe 'GET /api/v1/contacts pagination', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    5.times { |i| Contact.create!(name: "Paginated #{i}", email: "paginated-#{i}@example.com") }
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def contact_select_statements
    statements = []
    callback = lambda do |*, payload|
      sql = payload[:sql].to_s
      statements << sql if sql.match?(/\ASELECT .* FROM "contacts"/m) && !sql.include?('COUNT(')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    statements
  end

  it 'returns only the requested page' do
    get '/api/v1/contacts', params: { pageSize: 2, page: 1 }, headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['data'].size).to eq(2)
  end

  it 'never selects contacts without a LIMIT' do
    statements = contact_select_statements do
      get '/api/v1/contacts', params: { pageSize: 2, page: 1 }, headers: headers
    end

    expect(statements).not_to be_empty
    expect(statements).to all(include('LIMIT'))
  end
end
