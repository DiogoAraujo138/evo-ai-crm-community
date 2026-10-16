# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/chordata/multi_empresa')
require Rails.root.join('db/pilot/add_empresa_id_to_contacts')

# Piloto: a empresa A não lê, não grava e não altera dado da empresa B.
# O schema muda DENTRO da transação do exemplo e é desfeito no fim (DDL do Postgres é transacional).
RSpec.describe 'Multi-empresa: isolamento de contacts (piloto)' do
  let(:empresa_a) { SecureRandom.uuid }
  let(:empresa_b) { SecureRandom.uuid }
  let(:conn) { ActiveRecord::Base.connection }

  def na_empresa(id, &)
    EvoExtensionPoints::RuntimeContext.with_scope(id, &)
  end

  before do
    AddEmpresaIdToContactsPilot.new.up
    Contact.reset_column_information
    Contact.include(Chordata::MultiEmpresa::Escopavel) unless Contact.include?(Chordata::MultiEmpresa::Escopavel)
    Chordata::MultiEmpresa.install!
  end

  after do
    Chordata::MultiEmpresa::Current.reset
  end

  def criar(nome, email)
    Contact.create!(name: nome, email: email)
  end

  describe 'defesa 1: escopo no modelo' do
    it 'cada empresa vê só os próprios contatos' do
      na_empresa(empresa_a) { criar('Contato A1', 'a1@exemplo.invalid') }
      na_empresa(empresa_b) { criar('Contato B1', 'b1@exemplo.invalid') }

      expect(na_empresa(empresa_a) { Contact.pluck(:name) }).to eq(['Contato A1'])
      expect(na_empresa(empresa_b) { Contact.pluck(:name) }).to eq(['Contato B1'])
    end

    it 'a empresa A não encontra o contato da B nem pelo id' do
      b = na_empresa(empresa_b) { criar('Contato B1', 'b1@exemplo.invalid') }

      expect { na_empresa(empresa_a) { Contact.find(b.id) } }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'carimba a empresa atual ao criar, ignorando uma empresa informada à mão' do
      c = na_empresa(empresa_a) { Contact.create!(name: 'X', email: 'x@exemplo.invalid', empresa_id: empresa_b) }

      expect(c.empresa_id).to eq(empresa_a)
    end

    it 'FALHA sem empresa definida, em vez de devolver tudo' do
      na_empresa(empresa_a) { criar('Contato A1', 'a1@exemplo.invalid') }

      expect { Contact.count }.to raise_error(Chordata::MultiEmpresa::SemEscopo)
      expect { Contact.create!(name: 'Y', email: 'y@exemplo.invalid') }.to raise_error(Chordata::MultiEmpresa::SemEscopo)
    end
  end

  describe 'defesa 2: RLS no Postgres (rede de segurança)' do
    let(:papel) { 'evo_piloto_app' }

    before do
      na_empresa(empresa_a) { criar('Contato A1', 'a1@exemplo.invalid') }
      na_empresa(empresa_b) { criar('Contato B1', 'b1@exemplo.invalid') }
      conn.execute("CREATE ROLE #{papel} NOLOGIN NOSUPERUSER NOBYPASSRLS")
      conn.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON contacts TO #{papel}")
      conn.execute("SET LOCAL ROLE #{papel}")
    end

    def com_empresa_no_banco(id)
      conn.execute("SELECT set_config('app.empresa_id', #{conn.quote(id)}, true)")
    end

    it 'SQL cru (sem passar pelo modelo) também só enxerga a empresa atual' do
      com_empresa_no_banco(empresa_a)

      nomes = conn.select_values('SELECT name FROM contacts ORDER BY name')
      expect(nomes).to eq(['Contato A1'])
    end

    it 'a empresa de um with_scope não vaza para depois do bloco (mesma transação)' do
      na_empresa(empresa_a) { nil }

      expect(conn.select_value("SELECT coalesce(current_setting('app.empresa_id', true), '')")).to eq('')
    end

    it 'sem empresa no banco, nenhuma linha é visível' do
      expect(conn.select_value('SELECT count(*) FROM contacts').to_i).to eq(0)
    end

    it 'não deixa gravar contato de outra empresa' do
      com_empresa_no_banco(empresa_a)

      sql = "INSERT INTO contacts (name, email, empresa_id, created_at, updated_at) " \
            "VALUES ('Intruso', 'i@exemplo.invalid', '#{empresa_b}', now(), now())"
      expect { conn.execute(sql) }.to raise_error(ActiveRecord::StatementInvalid, /row-level security/)
    end

    it 'um UPDATE da empresa A não alcança linhas da B' do
      com_empresa_no_banco(empresa_a)

      afetadas = conn.exec_update("UPDATE contacts SET name = 'Hackeado'")
      expect(afetadas).to eq(1)
      conn.execute('RESET ROLE')
      expect(conn.select_value("SELECT name FROM contacts WHERE email = 'b1@exemplo.invalid'")).to eq('Contato B1')
    end
  end
end
