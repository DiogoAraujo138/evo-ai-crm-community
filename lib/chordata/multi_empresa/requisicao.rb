# frozen_string_literal: true

module Chordata
  module MultiEmpresa
    class Empresa < ActiveRecord::Base
      self.table_name = 'empresas'
      has_many :vinculos, class_name: 'Chordata::MultiEmpresa::EmpresaUsuario', foreign_key: :empresa_id, dependent: :destroy
    end

    class EmpresaUsuario < ActiveRecord::Base
      self.table_name = 'empresa_usuarios'
      belongs_to :empresa, class_name: 'Chordata::MultiEmpresa::Empresa'
    end

    # Decide QUAL empresa vale em uma requisição autenticada. A empresa nunca vem "de graça" do cliente:
    #   - usuário comum: só empresas em que tem vínculo (empresa_usuarios);
    #   - super_admin do grupo: qualquer empresa ativa;
    #   - chamada de serviço (ex.: Flow): confia no cabeçalho X-Evo-Tenant-Id, mesma convenção do Flow.
    # Sem empresa resolvida, a requisição é recusada (nunca roda "sem escopo").
    module Requisicao
      CABECALHO = 'X-Evo-Tenant-Id'

      class Recusada < StandardError
        attr_reader :status

        def initialize(mensagem, status)
          super(mensagem)
          @status = status
        end
      end

      class << self
        # Chamada de serviço já autenticada por segredo (ex.: retorno do Bot Runtime): só confia no cabeçalho.
        def servico!(cabecalho)
          resolver_servico!(cabecalho.to_s.strip.presence)
        end

        # Devolve o id da empresa ou levanta Recusada.
        def resolver!(usuario:, papel:, cabecalho:, servico: false)
          pedida = cabecalho.to_s.strip.presence
          return resolver_servico!(pedida) if servico

          raise Recusada.new('Autenticação necessária', :unauthorized) if usuario.nil?

          if papel.to_s == 'super_admin'
            return pedida_valida!(pedida) if pedida

            raise Recusada.new("Informe a empresa no cabeçalho #{CABECALHO}", :bad_request)
          end

          vinculadas = EmpresaUsuario.joins(:empresa).where(user_id: usuario.id, empresas: { ativa: true }).pluck(:empresa_id)
          raise Recusada.new('Usuário sem empresa', :forbidden) if vinculadas.empty?

          if pedida
            raise Recusada.new('Sem acesso a esta empresa', :forbidden) unless vinculadas.include?(pedida)

            return pedida
          end
          return vinculadas.first if vinculadas.size == 1

          raise Recusada.new("Informe a empresa no cabeçalho #{CABECALHO}", :bad_request)
        end

        private

        def resolver_servico!(pedida)
          raise Recusada.new("Chamada de serviço sem #{CABECALHO}", :bad_request) unless pedida

          pedida_valida!(pedida)
        end

        def pedida_valida!(pedida)
          raise Recusada.new('Empresa inválida', :bad_request) unless pedida.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
          raise Recusada.new('Empresa inexistente ou inativa', :forbidden) unless Empresa.where(id: pedida, ativa: true).exists?

          pedida
        end
      end

      # around_action ligado em Api::BaseController por config/initializers (sem editar app/).
      module Filtro
        def self.around(controller)
          usuario = controller.send(:current_user)
          papel = PAPEL_ATUAL.call
          servico = controller.send(:service_token_present?) && usuario.nil?
          # Rota pública (webhook, widget): sem usuário nem serviço não há como saber a empresa aqui.
          # Segue SEM escopo: qualquer consulta falha (SemEscopo/RLS) até o controller resolver a empresa
          # pelo canal (MultiEmpresa.resolver_empresa_do_canal).
          return yield if usuario.nil? && !servico

          id = Requisicao.resolver!(
            usuario: usuario, papel: papel, cabecalho: controller.request.headers[CABECALHO], servico: servico
          )
          EvoExtensionPoints::RuntimeContext.with_scope(id) { yield }
        rescue Requisicao::Recusada => e
          controller.render(json: { success: false, error: { code: 'EMPRESA', message: e.message } }, status: e.status)
        end

        PAPEL_ATUAL = -> { defined?(::Current) ? ::Current.evo_role_key : nil }
      end
    end

    # Jobs em segundo plano não têm requisição: carregam a empresa de quem os enfileirou.
    module EscopoDoJob
      extend ActiveSupport::Concern

      included do
        around_perform do |job, bloco|
          id = job.instance_variable_get(:@chordata_empresa_id)
          if id
            EvoExtensionPoints::RuntimeContext.with_scope(id, &bloco)
          elsif Chordata::MultiEmpresa::Current.empresa_id.blank? && Chordata::MultiEmpresa::TempoReal.agendado?(job.class)
            # Tarefa agendada (config/schedule.yml): não tem requisição nem quem a enfileirou. Roda uma vez por
            # empresa ativa; os jobs filhos que ela enfileirar já levam a empresa.
            Chordata::MultiEmpresa::TempoReal.para_cada_empresa_ativa(job.class) { bloco.call }
          else
            bloco.call
          end
        end
      end

      def serialize
        atual = Chordata::MultiEmpresa::Current.empresa_id
        atual ? super.merge('chordata_empresa_id' => atual) : super
      end

      def deserialize(dados)
        super
        @chordata_empresa_id = dados['chordata_empresa_id']
      end

      private

      # O Rails desserializa os argumentos (GlobalID => busca o registro no banco) ANTES de rodar os callbacks de
      # perform. Sem empresa na sessão, o RLS esconde a linha e o job é descartado com DeserializationError
      # (achado no teste de carga: ContactIpLookupJob, AvatarFromGravatarJob... ~1.900 jobs perdidos). Por isso a
      # desserialização também acontece DENTRO da empresa de quem enfileirou.
      def deserialize_arguments_if_needed
        id = @chordata_empresa_id
        return super unless id

        EvoExtensionPoints::RuntimeContext.with_scope(id) { super }
      end
    end
  end
end
