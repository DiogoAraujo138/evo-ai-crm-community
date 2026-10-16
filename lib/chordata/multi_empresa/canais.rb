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
          chave: ->(c) { c.params[:phone_number] } }
      ].freeze

      # Webhooks cuja chave só aparece no CORPO do payload do provedor. Ainda NÃO ligados: sem empresa
      # resolvida, qualquer acesso a dado falha (SemEscopo/RLS), nunca vaza. Cada um precisa ler o
      # identificador do payload e chamar MultiEmpresa.resolver_empresa_do_canal.
      PENDENTES = {
        'Webhooks::GmailController' => 'channel_email.email (mensagem do Pub/Sub)',
        'Webhooks::SendgridController' => 'channel_sendgrid (destinatário)',
        'Api::V1::WebhooksController#twitter_events' => 'channel_twitter_profiles.profile_id',
        'Webhooks::EvolutionHubController' => 'instância do Evolution Hub'
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
          candidatas: ->(c) { [['channel_facebook_pages', 'page_id', c.params.dig(:entry, 0, :id)]] } }
      ].freeze

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

          id = MultiEmpresa.resolver_empresa_do_canal(rota[:tabela], rota[:coluna], valor)
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
