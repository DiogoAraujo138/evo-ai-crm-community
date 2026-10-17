# frozen_string_literal: true

module Chordata
  module MultiEmpresa
    # Workers NATIVOS do Sidekiq (include Sidekiq::Worker/Job: e-mail de resposta, publicação de eventos no Flow, SendGrid...)
    # não passam pelo EscopoDoJob (que é do ActiveJob) e rodavam sem empresa: o RLS escondia o registro e o job morria com
    # RecordNotFound (achado no teste de carga: 299 jobs mortos). Cliente grava a empresa no job; servidor roda dentro dela.
    module Sidekiq
      CHAVE = 'chordata_empresa_id'
      # Jobs do ActiveJob já levam e restauram a empresa pelo EscopoDoJob (inclusive na desserialização).
      WRAPPER_ACTIVEJOB = 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper'

      class Cliente
        def call(_worker, job, _queue, _redis_pool = nil)
          atual = Chordata::MultiEmpresa::Current.empresa_id
          job[CHAVE] ||= atual if atual
          yield
        end
      end

      class Servidor
        def call(worker, job, _queue)
          id = job[CHAVE]
          return yield if id.blank? || ativo_job?(worker, job)

          EvoExtensionPoints::RuntimeContext.with_scope(id) { yield }
        end

        private

        def ativo_job?(worker, job)
          worker.class.name == WRAPPER_ACTIVEJOB || job['class'] == WRAPPER_ACTIVEJOB || job['wrapped'].present?
        end
      end

      def self.ligar!
        return unless defined?(::Sidekiq)

        ::Sidekiq.configure_client { |c| c.client_middleware { |chain| chain.add Cliente } }
        ::Sidekiq.configure_server do |c|
          c.client_middleware { |chain| chain.add Cliente }   # job que enfileira outro job propaga a empresa
          c.server_middleware { |chain| chain.add Servidor }
        end
      end
    end
  end
end
