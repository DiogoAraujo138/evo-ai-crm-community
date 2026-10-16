# frozen_string_literal: true

require 'rails_helper'

# Cross-request cache of the auth-service permission verdict.
# Only grants may be cached: a false can mean "auth unreachable", and caching it
# would lock a legitimate user out for the whole TTL.
RSpec.describe EvoPermissionConcern do
  let(:harness) { Class.new { include EvoPermissionConcern }.new }
  let(:store) { ActiveSupport::Cache::MemoryStore.new }
  let(:calls) { [] }

  before do
    allow(Rails).to receive(:cache).and_return(store)
    allow(EvoExtensionPoints::RuntimeContext).to receive(:current_scope_id).and_return(nil)
    Current.evo_permission_cache = nil
  end

  after do
    EvoExtensionPoints.reset!
    Current.reset
  end

  def stub_resolver(&verdict)
    EvoExtensionPoints.replace(:permission_resolver) do |user_id:, permission_key:, **|
      calls << [user_id, permission_key]
      verdict.call
    end
  end

  def new_request
    Current.evo_permission_cache = nil
  end

  it 'asks the auth-service once and serves later requests from the cache' do
    stub_resolver { true }

    expect(harness.send(:has_user_permission?, 'u1', 'contacts.read')).to be(true)
    new_request
    expect(harness.send(:has_user_permission?, 'u1', 'contacts.read')).to be(true)

    expect(calls.size).to eq(1)
  end

  it 'never caches a denial or an auth failure' do
    verdicts = [false, true]
    stub_resolver { verdicts.shift }

    expect(harness.send(:has_user_permission?, 'u1', 'contacts.read')).to be(false)
    new_request
    expect(harness.send(:has_user_permission?, 'u1', 'contacts.read')).to be(true)

    expect(calls.size).to eq(2)
  end

  it 'keeps verdicts of different users and permissions apart' do
    stub_resolver { true }

    harness.send(:has_user_permission?, 'u1', 'contacts.read')
    new_request
    harness.send(:has_user_permission?, 'u2', 'contacts.read')
    new_request
    harness.send(:has_user_permission?, 'u1', 'contacts.write')

    expect(calls.size).to eq(3)
  end

  it 'asks again once the cached grant expires' do
    stub_resolver { true }

    harness.send(:has_user_permission?, 'u1', 'contacts.read')
    new_request
    travel_to(Time.current + EvoPermissionConcern::AUTHZ_REMOTE_CACHE_TTL + 1.second) do
      harness.send(:has_user_permission?, 'u1', 'contacts.read')
    end

    expect(calls.size).to eq(2)
  end
end
