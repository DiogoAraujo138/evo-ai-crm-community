# frozen_string_literal: true

module Chordata
  module MultiEmpresa
    # Classificação das tabelas do CRM (ADR-0007). O spec `esquema_spec` compara esta lista com o
    # banco real: tabela nova do upstream sem classificação FAZ O TESTE FALHAR.
    module Tabelas
      EMPRESA = {
        pessoas_e_conversas: %w[
          contacts contact_inboxes contact_companies conversations conversation_participants messages
          attachments mentions notes csat_survey_responses reporting_events data_privacy_consents
          facebook_comment_moderations data_imports
        ],
        canais_e_integracoes: %w[
          inboxes inbox_members channel_api channel_email channel_facebook_pages channel_instagram
          channel_line channel_sendgrid channel_sms channel_telegram channel_twilio_sms
          channel_twitter_profiles channel_web_widgets channel_whatsapp telegram_bots agent_bots
          agent_bot_inboxes webhooks integrations_hooks working_hours message_templates
        ],
        funis_e_produtos: %w[
          pipelines pipeline_stages pipeline_items pipeline_item_products pipeline_tasks pipeline_teams
          pipeline_service_definitions stage_movements stage_inactivity_executions
          inactivity_action_executions products product_variants ai_agent_products
        ],
        automacao: %w[
          automation_rules automation_rule_runs macros macro_executions scheduled_actions
          scheduled_action_templates scheduled_action_execution_logs scheduled_action_notifications
        ],
        organizacao_e_conteudo: %w[
          teams team_members labels tags taggings canned_responses custom_attribute_definitions
          custom_filters crm_forms chat_pages dashboard_apps notifications notification_settings
          notification_subscriptions
        ]
      }.freeze

      GLOBAIS = %w[
        alembic_version installation_configs runtime_configs app_states action_mailbox_inbound_emails
        active_storage_blobs active_storage_variant_records active_storage_attachments roles
        role_permissions_actions oauth_applications oauth_access_grants oauth_access_tokens access_tokens
        setup_survey_responses user_tours
      ].freeze

      IDENTIDADE = %w[users user_roles].freeze

      # Criadas pelo próprio multi-empresa (não entram na comparação com o upstream).
      PROPRIAS = %w[empresas empresa_usuarios chordata_chaves_resolucao].freeze

      # Tabelas do Rails/infra que não são dados do produto.
      INFRA = %w[schema_migrations ar_internal_metadata].freeze

      def self.empresa
        EMPRESA.values.flatten.freeze
      end

      def self.todas_classificadas
        empresa + GLOBAIS + IDENTIDADE + PROPRIAS + INFRA
      end

      # Índices únicos (fora da PK) das tabelas de empresa, por tabela e colunas.
      #   :convertir -> vira único POR EMPRESA (empresa_id entra no índice)
      #   :global    -> continua único no sistema todo: é chave de resolução (token, telefone, página)
      #                 que o webhook usa para descobrir a empresa SEM usuário logado
      #   :natural   -> formado por ids uuid; já é único por empresa sem mudar nada
      UNICOS = {
        'ai_agent_products' => { 'ai_agent_id,product_id' => :natural },
        'channel_api' => { 'hmac_token' => :global, 'identifier' => :global },
        'channel_email' => { 'email' => :global, 'forward_to_email' => :global },
        'channel_facebook_pages' => { 'page_id' => :global },
        'channel_instagram' => { 'instagram_id' => :global },
        'channel_line' => { 'line_channel_id' => :global },
        'channel_sms' => { 'phone_number' => :global },
        'channel_telegram' => { 'bot_token' => :global },
        'channel_twilio_sms' => {
          'account_sid,phone_number' => :global, 'messaging_service_sid' => :global, 'phone_number' => :global
        },
        'channel_twitter_profiles' => { 'profile_id' => :global },
        'channel_web_widgets' => { 'hmac_token' => :global, 'website_token' => :global },
        'channel_whatsapp' => { 'phone_number' => :global },
        'chat_pages' => { 'slug' => :global },
        'contact_companies' => { 'contact_id,company_id' => :natural },
        'contact_inboxes' => {
          'inbox_id,bsuid' => :natural, 'inbox_id,source_id' => :natural, 'pubsub_token' => :global
        },
        'contacts' => { 'tax_id' => :convertir, 'email' => :convertir, 'identifier' => :convertir },
        'conversation_participants' => { 'user_id,conversation_id' => :natural },
        'conversations' => { 'display_id' => :convertir, 'uuid' => :global },
        'crm_forms' => { 'slug' => :global },
        'csat_survey_responses' => { 'message_id' => :natural },
        'custom_attribute_definitions' => { 'attribute_key,attribute_model' => :convertir },
        'data_privacy_consents' => { 'user_id,consent_type' => :natural },
        'inactivity_action_executions' => { 'conversation_id,action_index' => :natural },
        'inbox_members' => { 'inbox_id,user_id' => :natural },
        'labels' => { 'title' => :convertir },
        'mentions' => { 'user_id,conversation_id' => :natural },
        'message_templates' => { 'external_legacy_id' => :global, 'name' => :convertir },
        'notification_settings' => { 'user_id' => :natural },
        'notification_subscriptions' => { 'identifier' => :global },
        'pipeline_items' => {
          'contact_id,pipeline_id' => :natural, 'conversation_id,pipeline_id' => :natural,
          'pipeline_id' => :natural # índice por expressão (compra); só a coluna pipeline_id é visível
        },
        'pipeline_service_definitions' => { 'pipeline_id,name' => :natural },
        'pipeline_stages' => { 'pipeline_id,position' => :natural },
        'pipeline_teams' => { 'pipeline_id,team_id' => :natural },
        'pipelines' => { 'name' => :convertir },
        'product_variants' => { 'product_id,name' => :natural, 'sku' => :convertir },
        'products' => { 'sku' => :convertir },
        'stage_inactivity_executions' => { 'pipeline_item_id,rule_id' => :natural },
        'taggings' => { 'tag_id,taggable_id,taggable_type,context,tagger_id,tagger_type' => :natural },
        'tags' => { 'name' => :convertir },
        'team_members' => { 'team_id,user_id' => :natural },
        'teams' => { 'name' => :convertir },
        'webhooks' => { 'url' => :convertir }
      }.freeze

      # Identificadores de canal que vivem dentro de provider_config (JSON). NÃO são únicos no banco: o resolvedor
      # devolve nulo se a mesma chave existir em mais de uma empresa.
      CHAVES_EM_JSON = [
        %w[channel_whatsapp provider_config->>phone_number_id],
        %w[channel_whatsapp provider_config->>waba_id],
        %w[channel_whatsapp provider_config->>business_account_id],
        %w[channel_whatsapp provider_config->>instance_id],
        %w[channel_whatsapp provider_config->>instance_uuid],
        %w[channel_whatsapp provider_config->>instance_name]
      ].freeze

      # Chaves por id de registro (PK): o webhook traz o id de uma mensagem nossa (ex.: custom_args do SendGrid).
      CHAVES_POR_ID = [%w[messages id], %w[crm_forms id]].freeze

      # Chaves que o webhook usa para achar a empresa (função chordata_resolver_empresa).
      def self.chaves_de_resolucao
        UNICOS.flat_map do |tabela, indices|
          indices.select { |_cols, tipo| tipo == :global }.keys.reject { |c| c.include?(',') }
                 .map { |coluna| [tabela, coluna] }
        end + CHAVES_EM_JSON + CHAVES_POR_ID
      end
    end
  end
end
