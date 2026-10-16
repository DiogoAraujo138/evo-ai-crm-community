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
        'Webhooks::WhatsappController (Cloud API, Evolution, Z-API sem phone_number na URL)' => 'channel_whatsapp.phone_number (metadata do payload)',
        'Webhooks::InstagramController' => 'channel_instagram.instagram_id (entry[].id)',
        'Webhooks::FacebookController' => 'channel_facebook_pages.page_id (entry[].id)',
        'Webhooks::GmailController' => 'channel_email.email (mensagem do Pub/Sub)',
        'Webhooks::SendgridController' => 'channel_sendgrid (destinatário)',
        'Api::V1::WebhooksController#twitter_events' => 'channel_twitter_profiles.profile_id',
        'Webhooks::EvolutionHubController' => 'instância do Evolution Hub',
        'Webhooks::BotRuntimeController' => 'chamada de serviço: X-Evo-Tenant-Id'
      }.freeze

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
      end
    end
  end
end
