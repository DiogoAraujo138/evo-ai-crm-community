# frozen_string_literal: true

# Piloto de multi-empresa (Caminho C, ADR-0006). Duas defesas independentes:
#   1. default_scope no modelo (Escopavel): filtra pela empresa do escopo atual e FALHA se não houver escopo.
#   2. RLS no Postgres (db/pilot): o banco recusa linhas de outra empresa mesmo que o Ruby esqueça o filtro.
# O escopo vem do ponto de extensão `runtime_context` do Evo (nada em app/ é editado).
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
          ActiveRecord::Base.transaction do
            # set_config(..., true) só expira no fim da TRANSAÇÃO, não do bloco: dentro de uma
            # transação já aberta a empresa vazaria para o resto dela. Por isso restauramos o valor anterior.
            anterior = conn.select_value("SELECT current_setting('app.empresa_id', true)").to_s
            conn.execute("SELECT set_config('app.empresa_id', #{conn.quote(id.to_s)}, true)")
            begin
              block&.call
            ensure
              conn.execute("SELECT set_config('app.empresa_id', #{conn.quote(anterior)}, true)")
            end
          end
        end
      end
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
