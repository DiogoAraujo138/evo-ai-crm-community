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

      # Troca a validação de e-mail único (LOWER(email) = LOWER(?), sem índice, e que o RLS faz varrer tudo) por
      # chordata_contato_email_existe(). Mesma regra e mesma mensagem ("has already been taken").
      module EmailUnico
        def self.ligar!
          klass = 'Contact'.safe_constantize
          return if klass.nil? || klass.method_defined?(:chordata_email_unico)

          antigo = klass._validate_callbacks.find do |cb|
            cb.filter.is_a?(ActiveRecord::Validations::UniquenessValidator) && cb.filter.attributes == [:email]
          end
          klass._validate_callbacks.delete(antigo) if antigo
          klass.validate :chordata_email_unico
          klass.define_method(:chordata_email_unico) do
            return if email.blank? || !(new_record? || will_save_change_to_email?)
            return unless Chordata::MultiEmpresa::Busca.funcao_email_instalada?

            existe = self.class.connection.select_value(
              self.class.sanitize_sql_array(['SELECT chordata_contato_email_existe(?, ?)', email, id])
            )
            errors.add(:email, :taken, value: email) if existe == true
          end
        end
      end

      LIMITE_BUSCA_MENSAGENS = 1000

      # Busca global de mensagens (SearchService) e filtro de texto `q` da lista de conversas (ConversationFinder).
      module Mensagens
        module Servico
          private

          def filter_messages_with_like
            return super unless Chordata::MultiEmpresa::Busca.funcao_mensagens_instalada?

            ids = Message.sanitize_sql_array(['SELECT chordata_buscar_mensagens(?, ?, ?)', "%#{search_query}%", 3.months.ago, LIMITE_BUSCA_MENSAGENS])
            message_base_query.where("messages.id IN (#{ids})").reorder('created_at DESC').page(params[:page]).per(15)
          end
        end

        module Localizador
          private

          def apply_query_filter(query)
            return super unless Chordata::MultiEmpresa::Busca.funcao_mensagens_instalada?

            ids = Conversation.sanitize_sql_array(['SELECT chordata_conversas_com_mensagem(?, ?)', "%#{@params[:q]}%", LIMITE_BUSCA_MENSAGENS])
            query.where("conversations.id IN (#{ids})")
          end
        end

        def self.ligar!
          { 'SearchService' => Servico, 'ConversationFinder' => Localizador }.each do |nome, modulo|
            klass = nome.safe_constantize
            klass.prepend(modulo) if klass && !klass.ancestors.include?(modulo)
          end
        end
      end

      def self.funcao_mensagens_instalada?
        return @funcao_mensagens_instalada if @funcao_mensagens_instalada

        @funcao_mensagens_instalada = ActiveRecord::Base.connection.select_value("SELECT to_regprocedure('chordata_buscar_mensagens(text,timestamp,integer)') IS NOT NULL") == true
      end

      def self.funcao_email_instalada?
        return @funcao_email_instalada if @funcao_email_instalada

        @funcao_email_instalada = ActiveRecord::Base.connection.select_value("SELECT to_regprocedure('chordata_contato_email_existe(text,uuid)') IS NOT NULL") == true
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
        EmailUnico.ligar!
        Mensagens.ligar!
      end
    end
  end
end
