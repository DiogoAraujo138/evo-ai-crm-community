# frozen_string_literal: true

module Chordata
  module MultiEmpresa
    # Bot Runtime (serviço Go que debounça mensagens e chama o Processor).
    #
    # Ida: o evento enviado ao Bot Runtime leva `empresa_id` (vindo do escopo do job), para ele repassar
    # ao Processor (a chave de API do agente só existe dentro da empresa).
    # Volta: o retorno (postback) é uma chamada de serviço; confere o segredo (before_action original) e só
    # então lê X-Evo-Tenant-Id. `conversations.display_id` NÃO é global com multi-empresa (cada empresa tem a
    # sua sequência), então a conversa não basta para achar a empresa.
    module BotRuntime
      # Prepend em ::BotRuntime::Client: acrescenta empresa_id ao evento sem editar app/.
      module Cliente
        def send_event(event)
          id = Chordata::MultiEmpresa::Current.empresa_id
          if id.blank?
            Rails.logger.warn '[Chordata::MultiEmpresa] evento do Bot Runtime sem empresa no escopo; Processor vai recusar'
            return super
          end

          super(event.merge(empresa_id: id))
        end
      end

      module Retorno
        def self.around(controller)
          id = Requisicao.servico!(controller.request.headers[Requisicao::CABECALHO])
          EvoExtensionPoints::RuntimeContext.with_scope(id) { yield }
        rescue Requisicao::Recusada => e
          controller.render(json: { error: e.message }, status: e.status)
        end
      end

      CONTROLLER = 'Webhooks::BotRuntimeController'

      def self.ligar!
        cliente = '::BotRuntime::Client'.safe_constantize
        cliente.prepend(Cliente) if cliente && !cliente.include?(Cliente)

        klass = CONTROLLER.safe_constantize
        return if klass.nil? || klass.method_defined?(:chordata_escopo_retorno)

        klass.define_method(:chordata_escopo_retorno) do |&bloco|
          Chordata::MultiEmpresa::BotRuntime::Retorno.around(self, &bloco)
        end
        # append: roda DEPOIS do before_action :validate_secret da classe (segredo antes de confiar no cabeçalho).
        klass.append_around_action(:chordata_escopo_retorno)
      end
    end
  end
end
