# frozen_string_literal: true

# Piloto de multi-empresa (Caminho C, ADR-0006). Duas defesas independentes:
#   1. default_scope no modelo (Escopavel): filtra pela empresa do escopo atual e FALHA se não houver escopo.
#   2. RLS no Postgres (db/pilot): o banco recusa linhas de outra empresa mesmo que o Ruby esqueça o filtro.
# O escopo vem do ponto de extensão `runtime_context` do Evo (nada em app/ é editado).
require_relative 'multi_empresa/tabelas'
require_relative 'multi_empresa/esquema'
require_relative 'multi_empresa/canais'
require_relative 'multi_empresa/rotas'
require_relative 'multi_empresa/bot_runtime'
require_relative 'multi_empresa/tempo_real'

module Chordata
  module MultiEmpresa
    class SemEscopo < StandardError; end

    class Current < ActiveSupport::CurrentAttributes
      attribute :empresa_id
    end

    # Liga o escopo ao ponto de extensão runtime_context e ao Postgres (SET LOCAL app.empresa_id).
    def self.install!
      EvoExtensionPoints.replace(:runtime_context_current_id) { Current.empresa_id }
      EvoExtensionPoints.replace(:runtime_context_with_scope) do |id, &block|
        Current.set(empresa_id: id) do
          conn = ActiveRecord::Base.connection
          anterior = conn.select_value("SELECT current_setting('app.empresa_id', true)").to_s
          quoted = conn.quote(id.to_s)
          if conn.transaction_open?
            # Já dentro de uma transação de outro dono: valor LOCAL, restaurado ao sair do bloco. Os after_commit
            # dela rodam fora do nosso controle (e do nosso escopo).
            ActiveRecord::Base.transaction do
              conn.execute("SELECT set_config('app.empresa_id', #{quoted}, true)")
              begin
                block&.call
              ensure
                conn.execute("SELECT set_config('app.empresa_id', #{conn.quote(anterior)}, true)")
              end
            end
          else
            # Transação mais externa: os callbacks after_commit do Rails (ex.: Message#reopen_conversation, despacho
            # de eventos) rodam DEPOIS do COMMIT, já fora da transação. Com valor só LOCAL eles perderiam a empresa e o
            # RLS esconderia os próprios registros. Por isso o valor é da SESSÃO e é restaurado DEPOIS do commit.
            conn.execute("SELECT set_config('app.empresa_id', #{quoted}, false)")
            begin
              ActiveRecord::Base.transaction { block&.call }
            ensure
              conn.execute("SELECT set_config('app.empresa_id', #{conn.quote(anterior)}, false)")
            end
          end
        end
      end
    end


    # Resolve a empresa de um canal pela chave do webhook (token do widget, telefone, página...),
    # sem usuário logado. Só chaves da lista Tabelas.chaves_de_resolucao são aceitas.
    def self.resolver_empresa_do_canal(tabela, coluna, valor)
      conn = ActiveRecord::Base.connection
      conn.select_value(
        "SELECT chordata_resolver_empresa(#{conn.quote(tabela)}, #{conn.quote(coluna)}, #{conn.quote(valor.to_s)})",
      )
    end

    # Roda o bloco uma vez por empresa ativa (tarefas agendadas, que não têm requisição).
    def self.para_cada_empresa(&bloco)
      ids = ActiveRecord::Base.connection.select_values('SELECT id FROM empresas WHERE ativa ORDER BY nome')
      ids.each { |id| EvoExtensionPoints::RuntimeContext.with_scope(id, &bloco) }
    end

    # Inclui Escopavel em todo modelo cuja tabela é de empresa (só a classe-base de cada STI).
    def self.aplicar_aos_modelos!
      Rails.application.eager_load! unless Rails.application.config.eager_load
      aplicados = []
      ActiveRecord::Base.descendants.each do |modelo|
        next if modelo.abstract_class? || modelo.name.to_s.start_with?('Chordata::') || modelo.base_class != modelo
        next unless Tabelas.empresa.include?(modelo.table_name)

        modelo.include(Escopavel) unless modelo.include?(Escopavel)
        aplicados << modelo
      end
      aplicados
    end

    # Liga tudo na aplicação (chamado pelo initializer só com MULTI_EMPRESA=on).
    def self.ligar!
      install!
      Rotas.ligar!
      ActiveSupport.on_load(:active_job) do
        require_relative 'multi_empresa/requisicao'
        include Chordata::MultiEmpresa::EscopoDoJob unless include?(Chordata::MultiEmpresa::EscopoDoJob)
      end
      Rails.application.config.to_prepare do
        require_relative 'multi_empresa/requisicao'
        # 1o o filtro na base dos controllers: callbacks adicionados à base DEPOIS que uma subclasse já foi
        # carregada não chegam nela. 2o os modelos (aplicar_aos_modelos! carrega todo o app).
        Chordata::MultiEmpresa.ligar_filtro_de_requisicao!
        Chordata::MultiEmpresa.aplicar_aos_modelos!
      end
    end

    def self.ligar_filtro_de_requisicao!
      base = ::Api::BaseController
      return if base.method_defined?(:chordata_escopo)

      base.define_method(:chordata_escopo) do |&bloco|
        Chordata::MultiEmpresa::Requisicao::Filtro.around(self, &bloco)
      end
      base.around_action(:chordata_escopo)
      Chordata::MultiEmpresa::Canais.ligar!
      Chordata::MultiEmpresa::BotRuntime.ligar!
      Chordata::MultiEmpresa::TempoReal.ligar!
      require_relative 'multi_empresa/empresas_controller'
    end

    def self.empresa_atual!
      id = EvoExtensionPoints::RuntimeContext.current_scope_id
      raise SemEscopo, 'consulta sem empresa definida; use RuntimeContext.with_scope(empresa_id)' if id.blank?

      id
    end

    # include Chordata::MultiEmpresa::Escopavel no modelo que tem a coluna empresa_id.
    module Escopavel
      extend ActiveSupport::Concern

      included do
        default_scope { where(empresa_id: Chordata::MultiEmpresa.empresa_atual!) }
        before_validation(on: :create) { self.empresa_id = Chordata::MultiEmpresa.empresa_atual! }
      end
    end
  end
end
