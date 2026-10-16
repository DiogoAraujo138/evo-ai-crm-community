# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/chordata/multi_empresa')

# Ida e volta: remover devolve a unicidade original (sem isso o banco perde a regra de e-mail único).
RSpec.describe 'Multi-empresa: remover' do
  let(:conn) { ActiveRecord::Base.connection }

  before(:all) { ActiveRecord::Base.connection.begin_transaction(joinable: false) }
  after(:all) { ActiveRecord::Base.connection.rollback_transaction }

  it 'devolve os índices únicos originais e tira a coluna empresa_id' do
    unico_email = lambda do
      conn.select_values("SELECT indexdef FROM pg_indexes WHERE tablename = 'contacts' AND indexdef LIKE 'CREATE UNIQUE%' AND indexdef LIKE '%(email)%'")
    end
    expect(unico_email.call.size).to eq(1)

    Chordata::MultiEmpresa::Esquema.instalar!(conn)
    expect(unico_email.call).to be_empty # virou composto (empresa_id, email)

    Chordata::MultiEmpresa::Esquema.remover!(conn)

    expect(unico_email.call.size).to eq(1)
    colunas = conn.select_value("SELECT count(*) FROM information_schema.columns WHERE table_name = 'contacts' AND column_name = 'empresa_id'").to_i
    expect(colunas).to eq(0)
    expect(conn.select_value("SELECT count(*) FROM information_schema.tables WHERE table_name = 'empresas'").to_i).to eq(0)
  end
end
