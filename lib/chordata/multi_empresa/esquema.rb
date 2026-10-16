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
          end
        end

        def remover!(conn = ActiveRecord::Base.connection)
          conn.transaction do
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
            DECLARE resultado uuid;
            BEGIN
              IF NOT EXISTS (SELECT 1 FROM chordata_chaves_resolucao WHERE tabela = p_tabela AND coluna = p_coluna) THEN
                RAISE EXCEPTION 'chave de resolucao nao permitida: %.%', p_tabela, p_coluna;
              END IF;
              EXECUTE format('SELECT empresa_id FROM %I WHERE %I::text = $1 LIMIT 1', p_tabela, p_coluna)
                INTO resultado USING p_valor;
              RETURN resultado;
            END
            $fn$;
            REVOKE ALL ON FUNCTION chordata_resolver_empresa(text, text, text) FROM PUBLIC;
            ALTER FUNCTION chordata_resolver_empresa(text, text, text) OWNER TO #{PAPEL_RESOLVEDOR};
            GRANT SELECT ON chordata_chaves_resolucao TO #{PAPEL_RESOLVEDOR};
          SQL
          Tabelas.chaves_de_resolucao.each do |tabela, coluna|
            conn.execute("GRANT SELECT (empresa_id, #{conn.quote_column_name(coluna)}) ON #{conn.quote_table_name(tabela)} TO #{PAPEL_RESOLVEDOR}")
          end
        end
      end
    end
  end
end
