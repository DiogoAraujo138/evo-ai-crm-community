# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/chordata/multi_empresa')
require Rails.root.join('lib/chordata/multi_empresa/requisicao')

RSpec.describe Chordata::MultiEmpresa::TempoReal do
  let(:conn) { ActiveRecord::Base.connection }

  it 'conhece as classes do config/schedule.yml' do
    expect(described_class.agendado?('ScheduledActionsProcessorJob')).to be(true)
    expect(described_class.agendado?(Pipelines::CheckOverdueTasksJob)).to be(true)
    expect(described_class.agendado?('BotRuntime::SendEventJob')).to be(false)
    expect(described_class.jobs_agendados.size).to be >= 14
  end

  describe '.para_cada_empresa_ativa' do
    before do
      allow(conn).to receive(:select_values).with(/FROM empresas/).and_return(%w[
        11111111-1111-1111-1111-111111111111 22222222-2222-2222-2222-222222222222
      ])
      allow(EvoExtensionPoints::RuntimeContext).to receive(:with_scope) { |id, &b| @vistas << id; b.call }
      @vistas = []
    end

    it 'executa uma vez por empresa ativa' do
      described_class.para_cada_empresa_ativa('X') { nil }
      expect(@vistas.size).to eq(2)
    end

    it 'uma empresa com erro não impede as outras, e o erro é relançado no fim' do
      execucoes = 0
      expect do
        described_class.para_cada_empresa_ativa('X') do
          execucoes += 1
          raise 'falhou' if execucoes == 1
        end
      end.to raise_error('falhou')
      expect(execucoes).to eq(2)
    end
  end

  describe '.empresa_do_assinante' do
    it 'só resolve para contato (sem user_id) com pubsub_token' do
      expect(Chordata::MultiEmpresa).to receive(:resolver_empresa_do_canal)
        .with('contact_inboxes', 'pubsub_token', 'tok').and_return('11111111-1111-1111-1111-111111111111')
      expect(described_class.empresa_do_assinante(pubsub_token: 'tok')).to eq('11111111-1111-1111-1111-111111111111')
      expect(described_class.empresa_do_assinante(pubsub_token: 'tok', user_id: 'u')).to be_nil
      expect(described_class.empresa_do_assinante({})).to be_nil
    end
  end

  describe 'job agendado (EscopoDoJob)' do
    let(:job_class) do
      Class.new(ActiveJob::Base) do
        include Chordata::MultiEmpresa::EscopoDoJob
        cattr_accessor :vistas, default: []
        def perform = self.class.vistas << Chordata::MultiEmpresa::Current.empresa_id
      end
    end

    before do
      allow(described_class).to receive(:para_cada_empresa_ativa) { |_c, &b| %w[e1 e2].each { |id| Chordata::MultiEmpresa::Current.set(empresa_id: id, &b) } }
    end

    it 'sem empresa e agendado: roda uma vez por empresa' do
      allow(described_class).to receive(:agendado?).and_return(true)
      job_class.perform_now
      expect(job_class.vistas).to eq(%w[e1 e2])
    end

    it 'sem empresa e NÃO agendado: roda uma vez, sem escopo (falha segura no banco)' do
      allow(described_class).to receive(:agendado?).and_return(false)
      job_class.vistas.clear
      job_class.perform_now
      expect(job_class.vistas).to eq([nil])
    end
  end

  it 'a assinatura roda dentro do escopo da empresa do contato' do
    canal = Class.new do
      attr_reader :params, :visto

      def initialize(params) = @params = params

      def subscribed = @visto = Chordata::MultiEmpresa::Current.empresa_id
    end
    canal.prepend(described_class::Assinatura)
    allow(described_class).to receive(:empresa_do_assinante).and_return('11111111-1111-1111-1111-111111111111')
    allow(EvoExtensionPoints::RuntimeContext).to receive(:with_scope) { |id, &b| Chordata::MultiEmpresa::Current.set(empresa_id: id, &b) }
    instancia = canal.new(pubsub_token: 'tok')
    instancia.subscribed
    expect(instancia.visto).to eq('11111111-1111-1111-1111-111111111111')
  end
end
