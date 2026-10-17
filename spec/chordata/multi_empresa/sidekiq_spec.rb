# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/chordata/multi_empresa')
require Rails.root.join('lib/chordata/multi_empresa/sidekiq')

# Workers nativos do Sidekiq: a empresa precisa ir no job e voltar a valer na execução.
RSpec.describe Chordata::MultiEmpresa::Sidekiq do
  let(:empresa) { SecureRandom.uuid }

  describe Chordata::MultiEmpresa::Sidekiq::Cliente do
    it 'grava a empresa do escopo atual no job' do
      job = { 'class' => 'ConversationReplyEmailWorker', 'args' => [] }
      Chordata::MultiEmpresa::Current.set(empresa_id: empresa) { described_class.new.call(nil, job, 'mailers') { } }
      expect(job['chordata_empresa_id']).to eq(empresa)
    end

    it 'sem escopo não inventa empresa' do
      job = { 'class' => 'X', 'args' => [] }
      described_class.new.call(nil, job, 'default') { }
      expect(job).not_to have_key('chordata_empresa_id')
    end

    it 'não sobrescreve a empresa que o job já leva' do
      job = { 'class' => 'X', 'chordata_empresa_id' => 'outra' }
      Chordata::MultiEmpresa::Current.set(empresa_id: empresa) { described_class.new.call(nil, job, 'default') { } }
      expect(job['chordata_empresa_id']).to eq('outra')
    end
  end

  describe Chordata::MultiEmpresa::Sidekiq::Servidor do
    it 'roda o worker dentro da empresa gravada no job' do
      visto = nil
      allow(EvoExtensionPoints::RuntimeContext).to receive(:with_scope) { |id, &b| Chordata::MultiEmpresa::Current.set(empresa_id: id, &b) }
      described_class.new.call(Object.new, { 'chordata_empresa_id' => empresa }, 'default') { visto = Chordata::MultiEmpresa::Current.empresa_id }
      expect(visto).to eq(empresa)
    end

    it 'job sem empresa roda como antes (sem escopo)' do
      visto = :nao_rodou
      described_class.new.call(Object.new, {}, 'default') { visto = Chordata::MultiEmpresa::Current.empresa_id }
      expect(visto).to be_nil
    end

    it 'deixa os jobs do ActiveJob com o EscopoDoJob (não escopa duas vezes)' do
      chamou = false
      allow(EvoExtensionPoints::RuntimeContext).to receive(:with_scope) { chamou = true }
      described_class.new.call(Object.new, { 'chordata_empresa_id' => empresa, 'wrapped' => 'AlgumJob' }, 'default') { }
      expect(chamou).to be(false)
    end
  end
end
