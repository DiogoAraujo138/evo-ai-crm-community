# frozen_string_literal: true

# Migration PILOTO (fora de db/migrate de propósito: não roda sozinha em nenhum banco).
# Adiciona empresa_id em contacts e liga RLS. Usada pelo spec dentro de uma transação desfeita.
#
# ATENÇÃO (achado do piloto): o RLS NÃO vale para superusuário. O compose do Evo conecta como
# `postgres`; em produção a aplicação precisa de um papel sem BYPASSRLS (ex.: evo_app).
class AddEmpresaIdToContactsPilot < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      ALTER TABLE contacts ADD COLUMN empresa_id uuid;
      CREATE INDEX index_contacts_on_empresa_id ON contacts (empresa_id);
      ALTER TABLE contacts ENABLE ROW LEVEL SECURITY;
      ALTER TABLE contacts FORCE ROW LEVEL SECURITY;
      CREATE POLICY isolamento_por_empresa ON contacts
        USING (empresa_id = NULLIF(current_setting('app.empresa_id', true), '')::uuid)
        WITH CHECK (empresa_id = NULLIF(current_setting('app.empresa_id', true), '')::uuid);
    SQL
  end

  def down
    execute <<~SQL
      DROP POLICY IF EXISTS isolamento_por_empresa ON contacts;
      ALTER TABLE contacts NO FORCE ROW LEVEL SECURITY;
      ALTER TABLE contacts DISABLE ROW LEVEL SECURITY;
      DROP INDEX IF EXISTS index_contacts_on_empresa_id;
      ALTER TABLE contacts DROP COLUMN IF EXISTS empresa_id;
    SQL
  end
end
