# frozen_string_literal: true

module Chordata
  module MultiEmpresa
    # Instala/remove o isolamento por empresa no banco do CRM (todas as 70 tabelas de empresa de uma vez).
    # Tudo roda em uma transação: se algo falhar, nada muda. Idempotente.
    #
    # Em cada tabela de empresa:
    #   - coluna empresa_id (uuid, NOT NULL, FK para empresas), preenchida com a empresa padrão nos dados existentes
    #   - DEFAULT chordata_empresa_atual(): o próprio banco carimba a empresa na criação
    #   - ENABLE + FORCE ROW LEVEL SECURITY e política única de isolamento
    # Além disso: índices únicos de negócio viram únicos por empresa, e a função
    # chordata_resolver_empresa() deixa o webhook achar a empresa por token/telefone sem usuário logado.
    module Esquema
      PAPEL_RESOLVEDOR = 'chordata_resolvedor'
      SLUG_PADRAO = 'padrao'

      class << self
        def instalar!(conn = ActiveRecord::Base.connection)
          conn.transaction do
            criar_tabelas_proprias(conn)
            criar_funcoes(conn)
            Tabelas.empresa.each { |tabela| isolar_tabela(conn, tabela) }
            converter_indices_unicos(conn)
            criar_resolvedor(conn)
            criar_busca_de_contatos(conn)
          end
        end

        def remover!(conn = ActiveRecord::Base.connection)
          conn.transaction do
            conn.execute('DROP FUNCTION IF EXISTS chordata_buscar_contatos(text)')
            conn.execute('DROP FUNCTION IF EXISTS chordata_contato_email_existe(text, uuid)')
            conn.execute('DROP FUNCTION IF EXISTS chordata_buscar_mensagens(text, timestamp, integer)')
            conn.execute('DROP FUNCTION IF EXISTS chordata_conversas_com_mensagem(text, integer)')
            conn.execute('DROP INDEX IF EXISTS index_contacts_on_empresa_lower_email')
            conn.execute('DROP INDEX IF EXISTS index_contacts_on_company_name_trgm')
            conn.execute('DROP FUNCTION IF EXISTS chordata_resolver_empresa(text, text, text)')
            conn.execute('DROP TABLE IF EXISTS chordata_chaves_resolucao')
            restaurar_indices_unicos(conn)
            Tabelas.empresa.each { |tabela| desisolar_tabela(conn, tabela) }
            conn.execute('DROP TABLE IF EXISTS empresa_usuarios')
            conn.execute('DROP TABLE IF EXISTS empresas CASCADE')
            conn.execute('DROP FUNCTION IF EXISTS chordata_empresa_atual()')
          end
        end

        # Papel comum para a aplicação (NÃO superusuário, SEM bypass de RLS). O RLS não vale para
        # superusuário, então em produção a aplicação precisa conectar com um papel assim.
        def criar_papel_aplicacao!(conn, nome)
          nome_q = conn.quote_column_name(nome)
          conn.execute("CREATE ROLE #{nome_q} NOLOGIN NOSUPERUSER NOBYPASSRLS") unless papel?(conn, nome)
          conn.execute("GRANT USAGE ON SCHEMA public TO #{nome_q}")
          conn.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO #{nome_q}")
          conn.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO #{nome_q}")
          conn.execute("GRANT EXECUTE ON FUNCTION chordata_resolver_empresa(text, text, text) TO #{nome_q}")
          conn.execute("GRANT EXECUTE ON FUNCTION chordata_buscar_contatos(text) TO #{nome_q}")
          conn.execute("GRANT EXECUTE ON FUNCTION chordata_contato_email_existe(text, uuid) TO #{nome_q}")
          conn.execute("GRANT EXECUTE ON FUNCTION chordata_buscar_mensagens(text, timestamp, integer) TO #{nome_q}")
          conn.execute("GRANT EXECUTE ON FUNCTION chordata_conversas_com_mensagem(text, integer) TO #{nome_q}")
        end

        private

        # Devolve os índices únicos originais (tira empresa_id dos `*_empresa`) antes de apagar a coluna.
        def restaurar_indices_unicos(conn)
          conn.select_rows("SELECT i.relname, pg_get_indexdef(ix.indexrelid) FROM pg_index ix JOIN pg_class i ON i.oid = ix.indexrelid WHERE ix.indisunique AND i.relname LIKE '%\_empresa'").each do |nome, definicao|
            original = nome.sub(/_empresa\z/, '')
            novo = definicao.sub('USING btree (empresa_id, ', 'USING btree (').sub(/INDEX \S+ ON/, "INDEX #{conn.quote_column_name(original)} ON")
            conn.execute("DROP INDEX IF EXISTS #{conn.quote_table_name(nome)}")
            conn.execute(novo)
          end
        end

        def papel?(conn, nome)
          conn.select_value("SELECT 1 FROM pg_roles WHERE rolname = #{conn.quote(nome)}").present?
        end

        def criar_tabelas_proprias(conn)
          conn.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS empresas (
              id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
              nome text NOT NULL,
              slug text NOT NULL UNIQUE,
              ativa boolean NOT NULL DEFAULT true,
              created_at timestamp(6) NOT NULL DEFAULT now(),
              updated_at timestamp(6) NOT NULL DEFAULT now()
            );
            CREATE TABLE IF NOT EXISTS empresa_usuarios (
              id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
              empresa_id uuid NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
              user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
              papel text NOT NULL DEFAULT 'agent',
              created_at timestamp(6) NOT NULL DEFAULT now(),
              updated_at timestamp(6) NOT NULL DEFAULT now(),
              UNIQUE (empresa_id, user_id)
            );
            CREATE INDEX IF NOT EXISTS index_empresa_usuarios_on_user_id ON empresa_usuarios (user_id);
            INSERT INTO empresas (nome, slug) VALUES ('Empresa padrão', '#{SLUG_PADRAO}') ON CONFLICT (slug) DO NOTHING;
          SQL
        end

        def criar_funcoes(conn)
          conn.execute(<<~SQL)
            CREATE OR REPLACE FUNCTION chordata_empresa_atual() RETURNS uuid
              LANGUAGE sql STABLE
              AS $$ SELECT NULLIF(current_setting('app.empresa_id', true), '')::uuid $$;
          SQL
        end

        def isolar_tabela(conn, tabela)
          t = conn.quote_table_name(tabela)
          conn.execute(<<~SQL)
            ALTER TABLE #{t} ADD COLUMN IF NOT EXISTS empresa_id uuid;
            UPDATE #{t} SET empresa_id = (SELECT id FROM empresas WHERE slug = '#{SLUG_PADRAO}') WHERE empresa_id IS NULL;
            ALTER TABLE #{t} ALTER COLUMN empresa_id SET NOT NULL;
            ALTER TABLE #{t} ALTER COLUMN empresa_id SET DEFAULT chordata_empresa_atual();
          SQL
          conn.execute("CREATE INDEX IF NOT EXISTS #{conn.quote_column_name("index_#{tabela}_on_empresa_id")} ON #{t} (empresa_id)")
          unless conn.select_value("SELECT 1 FROM pg_constraint WHERE conname = #{conn.quote("fk_#{tabela}_empresa")}")
            conn.execute("ALTER TABLE #{t} ADD CONSTRAINT #{conn.quote_column_name("fk_#{tabela}_empresa")} " \
                         'FOREIGN KEY (empresa_id) REFERENCES empresas(id)')
          end
          conn.execute(<<~SQL)
            ALTER TABLE #{t} ENABLE ROW LEVEL SECURITY;
            ALTER TABLE #{t} FORCE ROW LEVEL SECURITY;
            DROP POLICY IF EXISTS isolamento_por_empresa ON #{t};
            CREATE POLICY isolamento_por_empresa ON #{t}
              USING (empresa_id = chordata_empresa_atual())
              WITH CHECK (empresa_id = chordata_empresa_atual());
          SQL
        end

        def desisolar_tabela(conn, tabela)
          t = conn.quote_table_name(tabela)
          conn.execute(<<~SQL)
            DROP POLICY IF EXISTS isolamento_por_empresa ON #{t};
            ALTER TABLE #{t} NO FORCE ROW LEVEL SECURITY;
            ALTER TABLE #{t} DISABLE ROW LEVEL SECURITY;
            ALTER TABLE #{t} DROP COLUMN IF EXISTS empresa_id CASCADE;
          SQL
        end

        # Índices únicos de negócio (:convertir) passam a incluir empresa_id.
        def converter_indices_unicos(conn)
          Tabelas::UNICOS.each do |tabela, indices|
            indices.each do |colunas, tipo|
              next unless tipo == :convertir

              indice_unico(conn, tabela, colunas).each do |nome, definicao|
                novo = definicao.sub('USING btree (', 'USING btree (empresa_id, ').sub(/INDEX \S+ ON/, "INDEX #{conn.quote_column_name("#{nome}_empresa")} ON")
                conn.execute("DROP INDEX IF EXISTS #{conn.quote_table_name(nome)}")
                conn.execute(novo)
              end
            end
          end
        end

        def indice_unico(conn, tabela, colunas)
          conn.select_rows(<<~SQL).to_h
            SELECT i.relname, pg_get_indexdef(ix.indexrelid)
            FROM pg_index ix
            JOIN pg_class t ON t.oid = ix.indrelid
            JOIN pg_class i ON i.oid = ix.indexrelid
            WHERE t.relname = #{conn.quote(tabela)} AND ix.indisunique AND NOT ix.indisprimary
              AND i.relname NOT LIKE '%\\_empresa' AND #{chave_sql(colunas)}
          SQL
        end

        # Colunas reais do índice, na ordem (ignora expressões), como "a,b".
        def chave_sql(colunas)
          "(SELECT string_agg(a.attname, ',' ORDER BY k.ord) FROM unnest(ix.indkey) WITH ORDINALITY k(attnum, ord) "             "JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = k.attnum) = "             "#{ActiveRecord::Base.connection.quote(colunas)}"
        end

        # Busca de contatos rápida SEM abrir mão do isolamento. Com RLS o Postgres não usa índice para LIKE/ILIKE/->> (os
        # operadores não são "leakproof"): a busca por trecho varria todas as linhas da empresa (226 ms com 100 mil contatos
        # contra 7 ms sem RLS). Esta função roda como o papel do resolvedor (sem RLS) mas filtra a empresa da SESSÃO de forma
        # explícita, e devolve só os ids; o CRM filtra o resto por `id IN (...)`, que continua sob RLS. Sem empresa na sessão
        # não devolve nada. O padrão (`%termo%`) é o mesmo que o CRM já montava.
        def criar_busca_de_contatos(conn)
          conn.execute(<<~SQL)
            CREATE INDEX IF NOT EXISTS index_contacts_on_company_name_trgm
              ON contacts USING gin ((additional_attributes ->> 'company_name') gin_trgm_ops);
            CREATE OR REPLACE FUNCTION chordata_buscar_contatos(p_padrao text)
            RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
              SELECT c.id FROM contacts c
              WHERE c.empresa_id = chordata_empresa_atual()
                AND (c.name ILIKE p_padrao OR c.email ILIKE p_padrao OR c.phone_number ILIKE p_padrao
                     OR c.identifier LIKE p_padrao OR c.additional_attributes ->> 'company_name' ILIKE p_padrao)
            $fn$;
            REVOKE ALL ON FUNCTION chordata_buscar_contatos(text) FROM PUBLIC;
            ALTER FUNCTION chordata_buscar_contatos(text) OWNER TO #{PAPEL_RESOLVEDOR};
            GRANT SELECT (id, empresa_id, name, email, phone_number, identifier, additional_attributes) ON contacts TO #{PAPEL_RESOLVEDOR};

            -- Busca de texto em MENSAGENS (busca global e filtro `q` da lista de conversas). Com RLS, `content ILIKE` varria as
            -- mensagens da empresa inteira (6,7 s + 2,8 s da contagem, 500 mil mensagens). Aqui o banco escolhe o melhor plano (índice
            -- trigram para termo raro, índice de data para termo comum) com a empresa da sessão explícita, e devolve só os ids mais
            -- recentes (p_limite) para a consulta de fora paginar.
            CREATE OR REPLACE FUNCTION chordata_buscar_mensagens(p_padrao text, p_desde timestamp, p_limite integer)
            RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
              SELECT m.id FROM messages m
              WHERE m.empresa_id = chordata_empresa_atual() AND m.created_at >= p_desde AND m.content ILIKE p_padrao
              ORDER BY m.created_at DESC LIMIT p_limite
            $fn$;
            CREATE OR REPLACE FUNCTION chordata_conversas_com_mensagem(p_padrao text, p_limite integer)
            RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
              SELECT DISTINCT conversation_id FROM (
                SELECT m.conversation_id FROM messages m
                WHERE m.empresa_id = chordata_empresa_atual() AND m.message_type IN (0, 1) AND m.content ILIKE p_padrao
                ORDER BY m.created_at DESC LIMIT p_limite) t
            $fn$;
            REVOKE ALL ON FUNCTION chordata_buscar_mensagens(text, timestamp, integer) FROM PUBLIC;
            REVOKE ALL ON FUNCTION chordata_conversas_com_mensagem(text, integer) FROM PUBLIC;
            ALTER FUNCTION chordata_buscar_mensagens(text, timestamp, integer) OWNER TO #{PAPEL_RESOLVEDOR};
            ALTER FUNCTION chordata_conversas_com_mensagem(text, integer) OWNER TO #{PAPEL_RESOLVEDOR};
            GRANT SELECT (id, empresa_id, conversation_id, message_type, content, created_at) ON messages TO #{PAPEL_RESOLVEDOR};

            -- Validação "e-mail único sem diferenciar maiúsculas" do modelo Contact: o upstream faz LOWER(email) = LOWER(?) e não há
            -- índice para isso; com RLS ainda varria as linhas de TODAS as empresas (1 s com 400 mil contatos), a cada criação
            -- e a cada linha de importação. Mesma regra, mas com índice e a empresa da sessão filtrada de forma explícita.
            CREATE INDEX IF NOT EXISTS index_contacts_on_empresa_lower_email ON contacts (empresa_id, lower(email));
            CREATE OR REPLACE FUNCTION chordata_contato_email_existe(p_email text, p_excluir uuid)
            RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
              SELECT EXISTS (SELECT 1 FROM contacts c
                             WHERE c.empresa_id = chordata_empresa_atual() AND lower(c.email) = lower(p_email)
                               AND (p_excluir IS NULL OR c.id <> p_excluir))
            $fn$;
            REVOKE ALL ON FUNCTION chordata_contato_email_existe(text, uuid) FROM PUBLIC;
            ALTER FUNCTION chordata_contato_email_existe(text, uuid) OWNER TO #{PAPEL_RESOLVEDOR};
          SQL
        end

        # Função que descobre a empresa de um canal pela chave do webhook, sem usuário logado.
        # Roda como um papel com BYPASSRLS que só enxerga (empresa_id + a coluna da chave).
        def criar_resolvedor(conn)
          conn.execute(<<~SQL)
            CREATE TABLE IF NOT EXISTS chordata_chaves_resolucao (
              tabela text NOT NULL, coluna text NOT NULL, PRIMARY KEY (tabela, coluna)
            );
            DELETE FROM chordata_chaves_resolucao;
          SQL
          Tabelas.chaves_de_resolucao.each do |tabela, coluna|
            conn.execute("INSERT INTO chordata_chaves_resolucao VALUES (#{conn.quote(tabela)}, #{conn.quote(coluna)})")
          end
          unless papel?(conn, PAPEL_RESOLVEDOR)
            conn.execute("CREATE ROLE #{PAPEL_RESOLVEDOR} NOLOGIN NOSUPERUSER BYPASSRLS")
          end
          conn.execute(<<~SQL)
            CREATE OR REPLACE FUNCTION chordata_resolver_empresa(p_tabela text, p_coluna text, p_valor text)
            RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $fn$
            DECLARE empresas_achadas uuid[]; v_coluna text; v_chave text;
            BEGIN
              IF NOT EXISTS (SELECT 1 FROM chordata_chaves_resolucao WHERE tabela = p_tabela AND coluna = p_coluna) THEN
                RAISE EXCEPTION 'chave de resolucao nao permitida: %.%', p_tabela, p_coluna;
              END IF;
              IF position('->>' IN p_coluna) > 0 THEN
                -- chave dentro de uma coluna JSON (ex.: provider_config->>phone_number_id)
                v_coluna := split_part(p_coluna, '->>', 1);
                v_chave := split_part(p_coluna, '->>', 2);
                EXECUTE format('SELECT array_agg(DISTINCT empresa_id) FROM %I WHERE %I ->> %L = $1', p_tabela, v_coluna, v_chave)
                  INTO empresas_achadas USING p_valor;
              ELSE
                EXECUTE format('SELECT array_agg(DISTINCT empresa_id) FROM %I WHERE %I::text = $1', p_tabela, p_coluna)
                  INTO empresas_achadas USING p_valor;
              END IF;
              -- Mesma chave em duas empresas: ambíguo, NUNCA adivinhar (entregar o webhook na empresa errada).
              IF empresas_achadas IS NULL OR array_length(empresas_achadas, 1) <> 1 THEN
                RETURN NULL;
              END IF;
              RETURN empresas_achadas[1];
            END
            $fn$;
            REVOKE ALL ON FUNCTION chordata_resolver_empresa(text, text, text) FROM PUBLIC;
            ALTER FUNCTION chordata_resolver_empresa(text, text, text) OWNER TO #{PAPEL_RESOLVEDOR};
            GRANT SELECT ON chordata_chaves_resolucao TO #{PAPEL_RESOLVEDOR};
          SQL
          Tabelas.chaves_de_resolucao.each do |tabela, coluna|
            conn.execute("GRANT SELECT (empresa_id, #{conn.quote_column_name(coluna.split('->>').first)}) ON #{conn.quote_table_name(tabela)} TO #{PAPEL_RESOLVEDOR}")
          end
        end
      end
    end
  end
end
