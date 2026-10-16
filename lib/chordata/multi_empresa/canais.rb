# frozen_string_literal: true

module Chordata
  module MultiEmpresa
    # Endpoints públicos (widget, webhooks) não têm usuário: a empresa sai da chave do canal que vem na
    # requisição, via chordata_resolver_empresa(). Registro declarativo: controller => de onde vem a chave.
    module Canais
      # obrigatoria: sem a chave a rota responde 404; sem o flag (ex.: WhatsApp sem phone_number na URL) segue sem escopo.
      # chave: proc que recebe o controller e devolve o valor (nil = a chave não veio na URL).
      ROTAS = [
        { controller: 'Api::V1::Widget::BaseController', obrigatoria: true, tabela: 'channel_web_widgets', coluna: 'website_token',
          chave: ->(c) { c.params[:website_token] } },
        { controller: 'Api::V1::Widget::DirectUploadsController', obrigatoria: true, tabela: 'channel_web_widgets', coluna: 'website_token',
          chave: ->(c) { c.params[:website_token] } },
        { controller: 'Webhooks::TelegramController', obrigatoria: true, tabela: 'channel_telegram', coluna: 'bot_token',
          chave: ->(c) { c.params[:bot_token] } },
        { controller: 'Webhooks::LineController', obrigatoria: true, tabela: 'channel_line', coluna: 'line_channel_id',
          chave: ->(c) { c.params[:line_channel_id] } },
        { controller: 'Webhooks::SmsController', obrigatoria: true, tabela: 'channel_sms', coluna: 'phone_number',
          chave: ->(c) { c.params[:phone_number] } },
        { controller: 'Webhooks::WhatsappController', tabela: 'channel_whatsapp', coluna: 'phone_number',
          chave: ->(c) { c.params[:phone_number] } },
        # API pública do canal "API" (inclui contatos, conversas e mensagens): o identificador vem em :inbox_id (ou :id no show).
        { controller: 'Public::Api::V1::InboxesController', obrigatoria: true, tabela: 'channel_api', coluna: 'identifier',
          chave: ->(c) { c.params[:inbox_id].presence || c.params[:id] } },
        { controller: 'Public::Api::V1::ChatPagesController', obrigatoria: true, tabela: 'chat_pages', coluna: 'slug',
          chave: ->(c) { c.params[:slug] } },
        # Formulário público: a chave pode ser o slug ou o id (uuid).
        { controller: 'Public::Api::V1::FormsController', obrigatoria: true, tabela: 'crm_forms',
          coluna: ->(c) { c.params[:slug].to_s.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/) ? 'id' : 'slug' },
          chave: ->(c) { c.params[:slug] } },
        # Pesquisa de satisfação: o :id é o uuid público da conversa.
        { controller: 'Public::Api::V1::CsatSurveyController', obrigatoria: true, tabela: 'conversations', coluna: 'uuid',
          chave: ->(c) { c.params[:id] } }
        # Public::Api::V1::LeadsController NÃO está aqui: autentica por chave de API (AccessToken, global) e a empresa não
        # sai da chave; precisa de decisão (cabeçalho X-Evo-Tenant-Id + vínculo do dono da chave). Falha fechado hoje.
      ].freeze

      # Webhooks cuja chave só aparece no CORPO do payload do provedor. Ainda NÃO ligados: sem empresa
      # resolvida, qualquer acesso a dado falha (SemEscopo/RLS), nunca vaza. Cada um precisa ler o
      # identificador do payload e chamar MultiEmpresa.resolver_empresa_do_canal.
      PENDENTES = {
        # Eventos de ciclo de vida do Evolution Hub (channel_connected...): o formato não traz chave de canal conhecida.
        'Webhooks::EvolutionHubController (event_type de ciclo de vida)' => 'sem chave de canal no payload'
        # Api::V1::WebhooksController#twitter_events: a rota existe, mas a ação não está implementada no upstream.
      }.freeze
      # WhatsApp (todos os provedores sem phone_number na URL), Instagram e Facebook saíram daqui: ver PAYLOAD.
      # Limitação: Meta pode agrupar várias páginas/contas em um mesmo POST; a empresa vem da PRIMEIRA entrada e
      # entradas de outra empresa são descartadas (falham fechado no job), nunca processadas na empresa errada.
      # Webhooks::BotRuntimeController saiu daqui: ver multi_empresa/bot_runtime.rb (segredo + X-Evo-Tenant-Id).

      # Webhooks cuja chave só vem no CORPO. `candidatas` devolve [[tabela, coluna, valor], ...] na ordem em que o
      # job original procura o canal; vale a primeira que resolver para uma única empresa.
      PAYLOAD = [
        { controller: 'Webhooks::WhatsappController',
          candidatas: lambda { |c|
            p = c.params
            id_cloud = p.dig(:entry, 0, :changes, 0, :value, :metadata, :phone_number_id) || p.dig(:metadata, :phone_number_id)
            [
              ['channel_whatsapp', 'provider_config->>phone_number_id', id_cloud],
              ['channel_whatsapp', 'provider_config->>instance_id', (p[:instanceId] if p[:type].present?)],
              ['channel_whatsapp', 'provider_config->>instance_uuid', p[:instanceId]],
              ['channel_whatsapp', 'provider_config->>instance_name', (p[:instance] if p[:event].present?)],
              ['channel_whatsapp', 'phone_number', p[:phone_number]],
              ['channel_whatsapp', 'provider_config->>waba_id', (p.dig(:entry, 0, :id) if p[:object] == 'whatsapp_business_account')],
              ['channel_whatsapp', 'provider_config->>business_account_id', (p.dig(:entry, 0, :id) if p[:object] == 'whatsapp_business_account')]
            ]
          } },
        { controller: 'Webhooks::InstagramController',
          candidatas: ->(c) { [['channel_instagram', 'instagram_id', c.params.dig(:entry, 0, :id)]] } },
        { controller: 'Webhooks::FacebookController',
          candidatas: ->(c) { [['channel_facebook_pages', 'page_id', c.params.dig(:entry, 0, :id)]] } },
        { controller: 'Webhooks::EvolutionHubController',
          candidatas: ->(c) { Canais.candidatas_meta(Canais.corpo_json(c)) } },
        { controller: 'Webhooks::GmailController',
          candidatas: ->(c) { [['channel_email', 'email', Canais.email_do_pubsub(c)]] } },
        { controller: 'Webhooks::SendgridController',
          candidatas: ->(c) { [['messages', 'id', Canais.mensagem_do_sendgrid(c)]] } }
      ].freeze

      # Corpo bruto como JSON (Hub, SendGrid, Gmail); nil se não for JSON.
      def self.corpo_json(controller)
        JSON.parse(controller.request.raw_post.to_s)
      rescue JSON::ParserError
        nil
      end

      # Candidatas de um evento da Meta (WhatsApp Business, Página, Instagram) dado o hash do payload.
      def self.candidatas_meta(corpo)
        return [] unless corpo.is_a?(Hash)

        entrada = Array(corpo['entry']).first || {}
        case corpo['object'].to_s.downcase
        when 'whatsapp_business_account'
          phone_id = entrada.dig('changes', 0, 'value', 'metadata', 'phone_number_id')
          [['channel_whatsapp', 'provider_config->>phone_number_id', phone_id],
           ['channel_whatsapp', 'provider_config->>waba_id', entrada['id']],
           ['channel_whatsapp', 'provider_config->>business_account_id', entrada['id']]]
        when 'page' then [['channel_facebook_pages', 'page_id', entrada['id']]]
        when 'instagram' then [['channel_instagram', 'instagram_id', entrada['id']]]
        else []
        end
      end

      # E-mail do Gmail no Pub/Sub: message.data (base64 de JSON) ou campos soltos.
      def self.email_do_pubsub(controller)
        corpo = corpo_json(controller)
        dados = corpo.is_a?(Hash) ? corpo['message'] : nil
        if dados.is_a?(Hash) && dados['data'].present?
          decodificado = begin
            JSON.parse(Base64.decode64(dados['data']))
          rescue JSON::ParserError, ArgumentError
            nil
          end
          email = decodificado.is_a?(Hash) ? (decodificado['emailAddress'] || decodificado['email_address']) : nil
          return email if email.present?
        end
        p = controller.params
        p[:emailAddress].presence || p[:email_address].presence || (corpo.is_a?(Hash) ? (corpo['emailAddress'] || corpo['email_address']) : nil)
      end

      # Id da primeira mensagem nossa citada num lote de eventos do SendGrid (custom_args.message_id).
      def self.mensagem_do_sendgrid(controller)
        eventos = corpo_json(controller)
        Array(eventos.is_a?(Array) ? eventos : [eventos]).filter_map do |e|
          e.is_a?(Hash) ? (e['message_id'] || e.dig('custom_args', 'message_id')) : nil
        end.first
      end

      module FiltroPayload
        # Sem escopo já definido pela URL e com ao menos uma chave no corpo: acha a empresa ou responde 404.
        # Sem chave nenhuma (ex.: GET de verificação da Meta) segue como antes, sem escopo.
        def self.around(controller, rota)
          return yield if Chordata::MultiEmpresa::Current.empresa_id.present?

          candidatas = Array(rota[:candidatas].call(controller)).select { |_t, _c, valor| valor.present? }
          return yield if candidatas.empty?

          id = candidatas.each do |tabela, coluna, valor|
            achada = MultiEmpresa.resolver_empresa_do_canal(tabela, coluna, valor)
            break achada if achada
          end
          return controller.render(json: { error: 'Canal não encontrado' }, status: :not_found) unless id.is_a?(String)

          EvoExtensionPoints::RuntimeContext.with_scope(id) { yield }
        end
      end

      module Filtro
        def self.around(controller, rota)
          valor = rota[:chave].call(controller)
          if valor.blank?
            # Chave obrigatória ausente: mesmo 404 que o original dava (find_by! sem resultado).
            return controller.render(json: { error: 'Canal não encontrado' }, status: :not_found) if rota[:obrigatoria]

            return yield
          end

          coluna = rota[:coluna].respond_to?(:call) ? rota[:coluna].call(controller) : rota[:coluna]
          id = MultiEmpresa.resolver_empresa_do_canal(rota[:tabela], coluna, valor)
          return controller.render(json: { error: 'Canal não encontrado' }, status: :not_found) if id.nil?

          EvoExtensionPoints::RuntimeContext.with_scope(id) { yield }
        end
      end

      def self.ligar!
        ROTAS.each do |rota|
          klass = rota[:controller].safe_constantize
          next unless klass
          next if klass.method_defined?(:chordata_escopo_canal)

          klass.define_method(:chordata_escopo_canal) do |&bloco|
            Chordata::MultiEmpresa::Canais::Filtro.around(self, rota, &bloco)
          end
          # prepend: tem de rodar ANTES de set_web_widget & cia, que já consultam o banco.
          klass.prepend_around_action(:chordata_escopo_canal)
        end

        PAYLOAD.each do |rota|
          klass = rota[:controller].safe_constantize
          next unless klass
          next if klass.method_defined?(:chordata_escopo_payload)

          klass.define_method(:chordata_escopo_payload) do |&bloco|
            Chordata::MultiEmpresa::Canais::FiltroPayload.around(self, rota, &bloco)
          end
          # Depois do filtro por URL (se houver) e antes do restante; a verificação GET da Meta não tem chave.
          klass.prepend_around_action(:chordata_escopo_payload)
        end
      end
    end
  end
end
