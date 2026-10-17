# frozen_string_literal: true

module Chordata
  module MultiEmpresa
    # Troca o filtro `ILIKE` da busca de contatos por `id IN (chordata_buscar_contatos(padrão))`, que usa o índice trigram
    # (ver Esquema.criar_busca_de_contatos). O resto da ação (lista, ordenação, paginação, resposta) é o do upstream.
    module Busca
      PADRAO_UPSTREAM = "name ILIKE :search OR email ILIKE :search OR phone_number ILIKE :search OR contacts.identifier LIKE :search"

      module Contatos
        # A contagem em cache (1 min) é por EMPRESA: a chave do upstream ("contacts_count/all") era global e, usada na resposta,
        # mostraria o total de uma empresa para outra.
        def cache_key_for_contacts_count
          "#{super}/emp:#{Chordata::MultiEmpresa::Current.empresa_id}"
        end

        # O upstream calcula @contacts_count (em cache no index) mas a resposta pagina com `total_count` do Kaminari, que refaz
        # um COUNT(*) de ~300 ms (100 mil contatos) a cada página. Reaproveita o número que já temos.
        def apply_pagination
          super
          total = @contacts_count
          return unless total && @contacts.respond_to?(:total_count)

          @contacts.instance_variable_set(:@total_count, total.to_i)
        end

        def search
          return super if params[:q].blank? || !Chordata::MultiEmpresa::Busca.funcao_instalada?

          contacts = listable_contacts.where('contacts.id IN (SELECT chordata_buscar_contatos(?))', "%#{params[:q].strip}%")
          @contacts_count = contacts.count
          @contacts = fetch_contacts(contacts)

          apply_pagination

          paginated_response(
            data: ContactSerializer.serialize_collection(@contacts, include_contact_inboxes: @include_contact_inboxes),
            collection: @contacts,
            message: 'Contacts search completed successfully'
          )
        end
      end

      # Banco ainda sem a função (código publicado antes de rodar o instalador): cai na busca original, mais lenta.
      def self.funcao_instalada?
        return @funcao_instalada if @funcao_instalada

        @funcao_instalada = ActiveRecord::Base.connection.select_value("SELECT to_regprocedure('chordata_buscar_contatos(text)') IS NOT NULL") == true
      end

      def self.ligar!
        klass = 'Api::V1::ContactsController'.safe_constantize
        return if klass.nil? || klass.ancestors.include?(Contatos)

        klass.prepend(Contatos)
      end
    end
  end
end
