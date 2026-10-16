# frozen_string_literal: true

require 'yaml'

module Chordata
  module MultiEmpresa
    # Coisas que acontecem SEM uma requisição HTTP: tarefas agendadas (sidekiq-cron) e WebSocket (ActionCable).
    module TempoReal
      CANAL = 'RoomChannel'

      class << self
        # Classes de job listadas em config/schedule.yml.
        def jobs_agendados
          @jobs_agendados ||= begin
            caminho = Rails.root.join('config/schedule.yml')
            (File.exist?(caminho) ? YAML.safe_load_file(caminho, aliases: true) : {}).values.filter_map { |v| v['class'] if v.is_a?(Hash) }.to_set
          end
        end

        def agendado?(classe)
          jobs_agendados.include?(classe.to_s)
        end

        # Roda o bloco uma vez por empresa ativa. Uma empresa que falha não impede as outras; o primeiro erro é
        # relançado no fim para o job ser reprocessado/alertado como qualquer falha.
        def para_cada_empresa_ativa(classe)
          primeiro_erro = nil
          ids = ActiveRecord::Base.connection.select_values('SELECT id FROM empresas WHERE ativa ORDER BY nome')
          ids.each do |id|
            EvoExtensionPoints::RuntimeContext.with_scope(id) { yield }
          rescue StandardError => e
            Rails.logger.error "[Chordata::MultiEmpresa] #{classe} falhou na empresa #{id}: #{e.class}: #{e.message}"
            primeiro_erro ||= e
          end
          raise primeiro_erro if primeiro_erro
        end

        # Empresa de quem assina o canal como CONTATO (widget): vem do pubsub_token do contact_inbox. Agente
        # (User) não lê tabela de empresa na assinatura, então segue sem escopo.
        def empresa_do_assinante(params)
          return nil if params[:user_id].present? || params[:pubsub_token].blank?

          MultiEmpresa.resolver_empresa_do_canal('contact_inboxes', 'pubsub_token', params[:pubsub_token])
        end
      end

      module Assinatura
        def subscribed
          id = Chordata::MultiEmpresa::TempoReal.empresa_do_assinante(params)
          return super if id.blank?

          EvoExtensionPoints::RuntimeContext.with_scope(id) { super }
        end
      end

      def self.ligar!
        canal = CANAL.safe_constantize
        canal.prepend(Assinatura) if canal && !canal.include?(Assinatura)
      end
    end
  end
end
