# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/chordata/multi_empresa')
require Rails.root.join('lib/chordata/multi_empresa/requisicao')

# Roda em um processo próprio (inclui o escopo nos modelos, o que não se desfaz):
#   rspec spec/chordata/multi_empresa/esquema_spec.rb
# O schema é instalado UMA vez numa transação externa e desfeito no fim (DDL do Postgres é transacional).
RSpec.describe 'Multi-empresa: esquema, isolamento e escopo (70 tabelas)' do
  let(:conn) { ActiveRecord::Base.connection }
  let(:tabelas) { Chordata::MultiEmpresa::Tabelas.empresa }
  let(:papel) { 'evo_teste_app' }

  def na_empresa(id, &)
    EvoExtensionPoints::RuntimeContext.with_scope(id, &)
  end

  def como_app
    conn.execute("SET LOCAL ROLE #{papel}")
    yield
  ensure
    conn.execute('RESET ROLE')
  end

  def empresa_nova(slug)
    conn.select_value("INSERT INTO empresas (nome, slug) VALUES (#{conn.quote(slug)}, #{conn.quote(slug)}) RETURNING id")
  end

  def usuario_novo(email)
    conn.select_value(<<~SQL)
      INSERT INTO users (name, email, uid, created_at, updated_at)
      VALUES ('Teste', #{conn.quote(email)}, #{conn.quote(email)}, now(), now()) RETURNING id
    SQL
  end

  before(:all) do
    c = ActiveRecord::Base.connection
    c.begin_transaction(joinable: false)
    # Dado pré-existente: precisa receber a empresa padrão no backfill.
    c.execute("INSERT INTO contacts (name, email, created_at, updated_at) VALUES ('Antigo', 'antigo@exemplo.invalid', now(), now())")
    Chordata::MultiEmpresa::Esquema.instalar!(c)
    Chordata::MultiEmpresa::Esquema.criar_papel_aplicacao!(c, 'evo_teste_app')
    Chordata::MultiEmpresa.install!
    @aplicados = Chordata::MultiEmpresa.aplicar_aos_modelos!
  end

  after(:all) do
    Chordata::MultiEmpresa::Current.reset
    ActiveRecord::Base.connection.rollback_transaction
  end

  describe 'instalação' do
    it 'põe empresa_id NOT NULL, FK, default, índice, RLS forçado e política nas 70 tabelas' do
      problemas = tabelas.flat_map do |t|
        rel = conn.select_one("SELECT relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname = #{conn.quote(t)}")
        col = conn.select_one(<<~SQL)
          SELECT is_nullable, column_default FROM information_schema.columns
          WHERE table_name = #{conn.quote(t)} AND column_name = 'empresa_id'
        SQL
        pol = conn.select_value("SELECT count(*) FROM pg_policies WHERE tablename = #{conn.quote(t)} AND policyname = 'isolamento_por_empresa'").to_i
        fk = conn.select_value("SELECT count(*) FROM pg_constraint WHERE conname = #{conn.quote("fk_#{t}_empresa")}").to_i
        idx = conn.select_value("SELECT count(*) FROM pg_indexes WHERE tablename = #{conn.quote(t)} AND indexdef LIKE '%(empresa_id)%'").to_i
        erros = []
        erros << "#{t}: RLS desligado" unless rel && rel['relrowsecurity'] && rel['relforcerowsecurity']
        erros << "#{t}: sem coluna NOT NULL" unless col && col['is_nullable'] == 'NO'
        erros << "#{t}: sem default de carimbo" unless col && col['column_default'].to_s.include?('chordata_empresa_atual')
        erros << "#{t}: sem política" unless pol == 1
        erros << "#{t}: sem FK" unless fk == 1
        erros << "#{t}: sem índice" unless idx >= 1
        erros
      end

      expect(problemas).to be_empty, problemas.first(10).join("\n")
    end

    it 'não toca nas tabelas globais nem de identidade' do
      (Chordata::MultiEmpresa::Tabelas::GLOBAIS + Chordata::MultiEmpresa::Tabelas::IDENTIDADE).each do |t|
        tem = conn.select_value("SELECT count(*) FROM information_schema.columns WHERE table_name = #{conn.quote(t)} AND column_name = 'empresa_id'").to_i
        expect(tem).to eq(0), "#{t} não deveria ter empresa_id"
      end
    end

    it 'leva o dado que já existia para a empresa padrão' do
      padrao = conn.select_value("SELECT id FROM empresas WHERE slug = 'padrao'")
      antigo = conn.select_value("SELECT empresa_id FROM contacts WHERE email = 'antigo@exemplo.invalid'")

      expect(antigo).to eq(padrao)
    end

    it 'é idempotente: instalar de novo não quebra nem duplica' do
      expect { Chordata::MultiEmpresa::Esquema.instalar!(conn) }.not_to raise_error
      expect(conn.select_value("SELECT count(*) FROM pg_policies WHERE tablename = 'contacts'").to_i).to eq(1)
      expect(conn.select_value("SELECT count(*) FROM empresas WHERE slug = 'padrao'").to_i).to eq(1)
    end

    it 'índices de negócio viram únicos por empresa; os de chave global continuam globais' do
      defs = conn.select_values("SELECT indexdef FROM pg_indexes WHERE tablename = 'contacts' AND indexdef LIKE 'CREATE UNIQUE%'")
      expect(defs.any? { |d| d.include?('(empresa_id, email)') }).to be(true)
      expect(defs.none? { |d| d.include?('USING btree (email)') }).to be(true)

      globais = conn.select_values("SELECT indexdef FROM pg_indexes WHERE tablename = 'channel_whatsapp' AND indexdef LIKE 'CREATE UNIQUE%'")
      expect(globais.any? { |d| d.include?('USING btree (phone_number)') }).to be(true)
    end
  end

  describe 'isolamento nas 70 tabelas (SQL cru, papel sem bypass)' do
    # Cria uma linha mínima em cada tabela, com valores neutros para as colunas obrigatórias.
    def linha_minima(tabela, empresa)
      colunas = conn.select_rows(<<~SQL)
        SELECT column_name, data_type, udt_name FROM information_schema.columns
        WHERE table_name = #{conn.quote(tabela)} AND is_nullable = 'NO' AND column_default IS NULL
          AND column_name <> 'empresa_id' AND is_generated = 'NEVER' AND identity_generation IS NULL
      SQL
      nomes = ['empresa_id']
      valores = [conn.quote(empresa)]
      colunas.each do |nome, tipo, udt|
        nomes << conn.quote_column_name(nome)
        valores << valor_neutro(tipo, udt)
      end
      "INSERT INTO #{conn.quote_table_name(tabela)} (#{nomes.join(', ')}) VALUES (#{valores.join(', ')})"
    end

    def valor_neutro(tipo, udt)
      case tipo
      when 'uuid' then 'gen_random_uuid()'
      when 'integer', 'bigint', 'smallint', 'numeric' then '0'
      when 'boolean' then 'false'
      when 'json', 'jsonb' then "'{}'"
      when /timestamp|date/ then 'now()'
      when 'ARRAY' then "'{}'"
      when 'USER-DEFINED'
        rotulo = conn.select_value("SELECT e.enumlabel FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = #{conn.quote(udt)} ORDER BY e.enumsortorder LIMIT 1")
        conn.quote(rotulo)
      else "'#{SecureRandom.hex(1)}'"
      end
    end

    it 'cada empresa enxerga só a própria linha em toda tabela, e sem empresa não enxerga nada' do
      a = empresa_nova("isolamento-a-#{SecureRandom.hex(3)}")
      b = empresa_nova("isolamento-b-#{SecureRandom.hex(3)}")
      sem_linha = []
      falhas = []

      tabelas.each do |t|
        conn.execute("SAVEPOINT s_#{t}")
        begin
          conn.execute('SET LOCAL session_replication_role = replica') # sem FKs/triggers só para semear
          conn.execute(linha_minima(t, a))
          conn.execute(linha_minima(t, b))
          conn.execute('SET LOCAL session_replication_role = origin')
        rescue ActiveRecord::StatementInvalid => e
          conn.execute("ROLLBACK TO SAVEPOINT s_#{t}")
          sem_linha << "#{t} (#{e.message.lines.first.strip[0, 80]})"
          next
        end

        como_app do
          conn.execute("SELECT set_config('app.empresa_id', #{conn.quote(a)}, true)")
          visiveis = conn.select_values("SELECT empresa_id FROM #{conn.quote_table_name(t)}")
          falhas << "#{t}: A vê #{visiveis.uniq.inspect}" unless visiveis.uniq == [a]
          conn.execute("SELECT set_config('app.empresa_id', '', true)")
          sem_escopo = conn.select_value("SELECT count(*) FROM #{conn.quote_table_name(t)}").to_i
          falhas << "#{t}: sem empresa vê #{sem_escopo} linhas" unless sem_escopo.zero?
        end
      end

      puts "\n[isolamento] #{tabelas.size - sem_linha.size}/#{tabelas.size} tabelas verificadas com dados; sem linha de teste: #{sem_linha.inspect}" if sem_linha.any?
      expect(falhas).to be_empty, falhas.first(10).join("\n")
      # Tabelas em que não foi possível semear (check constraint etc.) ficam como pendência explícita, não como sucesso.
      expect(sem_linha).to be_empty, "muitas tabelas sem linha de teste: #{sem_linha.inspect}"
    end

    it 'o banco carimba a empresa na criação mesmo que o código não informe' do
      a = empresa_nova("carimbo-#{SecureRandom.hex(3)}")
      como_app do
        conn.execute("SELECT set_config('app.empresa_id', #{conn.quote(a)}, true)")
        conn.execute("INSERT INTO contacts (name, email, created_at, updated_at) VALUES ('Carimbado', 'c@exemplo.invalid', now(), now())")
        expect(conn.select_value("SELECT empresa_id FROM contacts WHERE email = 'c@exemplo.invalid'")).to eq(a)
      end
    end

    it 'sem empresa definida o banco recusa gravar' do
      como_app do
        conn.execute("SELECT set_config('app.empresa_id', '', true)")
        expect do
          conn.transaction(requires_new: true) do
            conn.execute("INSERT INTO contacts (name, email, created_at, updated_at) VALUES ('X', 'x@exemplo.invalid', now(), now())")
          end
        end.to raise_error(ActiveRecord::StatementInvalid, /null value|row-level security/)
      end
    end

    it 'duas empresas podem ter o mesmo e-mail de contato; a mesma empresa não' do
      a = empresa_nova("mail-a-#{SecureRandom.hex(3)}")
      b = empresa_nova("mail-b-#{SecureRandom.hex(3)}")
      insere = ->(emp) { "INSERT INTO contacts (name, email, empresa_id, created_at, updated_at) VALUES ('M', 'mesmo@exemplo.invalid', '#{emp}', now(), now())" }

      conn.execute(insere.call(a))
      expect { conn.execute(insere.call(b)) }.not_to raise_error
      conn.execute('SAVEPOINT dup')
      expect { conn.execute(insere.call(a)) }.to raise_error(ActiveRecord::RecordNotUnique)
      conn.execute('ROLLBACK TO SAVEPOINT dup')
    end
  end

  describe 'resolução de canal por webhook (sem usuário logado)' do
    it 'acha a empresa pelo telefone do canal, mesmo sem escopo, e o papel da aplicação continua sem ler a tabela' do
      a = empresa_nova("canal-#{SecureRandom.hex(3)}")
      conn.execute('SET LOCAL session_replication_role = replica')
      conn.execute("INSERT INTO channel_whatsapp (phone_number, provider_config, empresa_id, created_at, updated_at) VALUES ('+5511999990001', '{}', '#{a}', now(), now())") rescue conn.execute(linha_minima('channel_whatsapp', a))
      conn.execute('SET LOCAL session_replication_role = origin')

      como_app do
        expect(Chordata::MultiEmpresa.resolver_empresa_do_canal('channel_whatsapp', 'phone_number', '+5511999990001')).to eq(a)
        expect(conn.select_value('SELECT count(*) FROM channel_whatsapp').to_i).to eq(0)
      end
    end

    it 'devolve nulo para chave desconhecida e recusa tabela ou coluna fora da lista' do
      como_app do
        expect(Chordata::MultiEmpresa.resolver_empresa_do_canal('channel_whatsapp', 'phone_number', 'nao-existe')).to be_nil
        [%w[contacts email], %w[users email], %w[channel_whatsapp provider_config]].each do |tabela, coluna|
          expect do
            conn.transaction(requires_new: true) { Chordata::MultiEmpresa.resolver_empresa_do_canal(tabela, coluna, 'x') }
          end.to raise_error(ActiveRecord::StatementInvalid, /nao permitida/)
        end
      end
    end
  end

  describe 'escopo no modelo' do
    it 'aplica Escopavel a todo modelo de tabela de empresa' do
      expect(@aplicados.size).to be >= 40
      expect(@aplicados.map(&:table_name)).to all(satisfy { |t| tabelas.include?(t) })
      expect(Contact.include?(Chordata::MultiEmpresa::Escopavel)).to be(true)
      expect(Conversation.include?(Chordata::MultiEmpresa::Escopavel)).to be(true)
    end

    it 'cada empresa vê só os próprios contatos; sem empresa dá erro' do
      a = empresa_nova("mod-a-#{SecureRandom.hex(3)}")
      b = empresa_nova("mod-b-#{SecureRandom.hex(3)}")
      na_empresa(a) { Contact.create!(name: 'A1', email: 'a1@exemplo.invalid') }
      na_empresa(b) { Contact.create!(name: 'B1', email: 'b1@exemplo.invalid') }

      expect(na_empresa(a) { Contact.pluck(:name) }).to eq(['A1'])
      expect(na_empresa(b) { Contact.pluck(:name) }).to eq(['B1'])
      expect { Contact.count }.to raise_error(Chordata::MultiEmpresa::SemEscopo)
    end

    it 'a empresa não vaza para depois do bloco' do
      a = empresa_nova("vaza-#{SecureRandom.hex(3)}")
      na_empresa(a) { nil }

      expect(conn.select_value("SELECT coalesce(current_setting('app.empresa_id', true), '')")).to eq('')
    end

    it 'para_cada_empresa roda uma vez por empresa ativa, com o escopo certo' do
      a = empresa_nova("loop-a-#{SecureRandom.hex(3)}")
      conn.execute("UPDATE empresas SET ativa = false WHERE id <> '#{a}'")
      vistos = []
      Chordata::MultiEmpresa.para_cada_empresa { vistos << EvoExtensionPoints::RuntimeContext.current_scope_id }

      expect(vistos).to eq([a])
    end
  end

  describe 'escopo da requisição (quem pode usar qual empresa)' do
    let(:resolver) { Chordata::MultiEmpresa::Requisicao }

    def vincular(user_id, empresa_id, papel = 'agent')
      conn.execute("INSERT INTO empresa_usuarios (user_id, empresa_id, papel) VALUES ('#{user_id}', '#{empresa_id}', '#{papel}')")
    end

    it 'usuário com uma empresa usa essa empresa sem informar nada' do
      a = empresa_nova("req-a-#{SecureRandom.hex(3)}")
      u = usuario_novo("u1-#{SecureRandom.hex(3)}@exemplo.invalid")
      vincular(u, a)

      expect(resolver.resolver!(usuario: OpenStruct.new(id: u), papel: 'agent', cabecalho: nil)).to eq(a)
    end

    it 'usuário com duas empresas precisa escolher, e só entre as dele' do
      a = empresa_nova("req-b-#{SecureRandom.hex(3)}")
      b = empresa_nova("req-c-#{SecureRandom.hex(3)}")
      c = empresa_nova("req-d-#{SecureRandom.hex(3)}")
      u = usuario_novo("u2-#{SecureRandom.hex(3)}@exemplo.invalid")
      vincular(u, a)
      vincular(u, b)
      usuario = OpenStruct.new(id: u)

      expect { resolver.resolver!(usuario: usuario, papel: 'agent', cabecalho: nil) }.to raise_error(resolver::Recusada) { |e| expect(e.status).to eq(:bad_request) }
      expect(resolver.resolver!(usuario: usuario, papel: 'agent', cabecalho: b)).to eq(b)
      expect { resolver.resolver!(usuario: usuario, papel: 'agent', cabecalho: c) }.to raise_error(resolver::Recusada) { |e| expect(e.status).to eq(:forbidden) }
    end

    it 'usuário sem vínculo é recusado, e empresa desativada não vale' do
      a = empresa_nova("req-e-#{SecureRandom.hex(3)}")
      u = usuario_novo("u3-#{SecureRandom.hex(3)}@exemplo.invalid")

      expect { resolver.resolver!(usuario: OpenStruct.new(id: u), papel: 'agent', cabecalho: nil) }.to raise_error(resolver::Recusada)
      vincular(u, a)
      conn.execute("UPDATE empresas SET ativa = false WHERE id = '#{a}'")
      expect { resolver.resolver!(usuario: OpenStruct.new(id: u), papel: 'agent', cabecalho: nil) }.to raise_error(resolver::Recusada)
    end

    it 'super_admin entra em qualquer empresa ativa, mas precisa dizer qual' do
      a = empresa_nova("req-f-#{SecureRandom.hex(3)}")
      admin = OpenStruct.new(id: SecureRandom.uuid)

      expect(resolver.resolver!(usuario: admin, papel: 'super_admin', cabecalho: a)).to eq(a)
      expect { resolver.resolver!(usuario: admin, papel: 'super_admin', cabecalho: nil) }.to raise_error(resolver::Recusada)
      expect { resolver.resolver!(usuario: admin, papel: 'super_admin', cabecalho: 'nao-e-uuid') }.to raise_error(resolver::Recusada)
      expect { resolver.resolver!(usuario: admin, papel: 'super_admin', cabecalho: SecureRandom.uuid) }.to raise_error(resolver::Recusada)
    end

    it 'chamada de serviço confia no cabeçalho, mas só para empresa existente' do
      a = empresa_nova("req-g-#{SecureRandom.hex(3)}")

      expect(resolver.resolver!(usuario: nil, papel: nil, cabecalho: a, servico: true)).to eq(a)
      expect { resolver.resolver!(usuario: nil, papel: nil, cabecalho: nil, servico: true) }.to raise_error(resolver::Recusada)
      expect { resolver.resolver!(usuario: nil, papel: nil, cabecalho: SecureRandom.uuid, servico: true) }.to raise_error(resolver::Recusada)
    end

    it 'sem usuário nem serviço é recusado' do
      expect { resolver.resolver!(usuario: nil, papel: nil, cabecalho: nil) }.to raise_error(resolver::Recusada)
    end
  end

  describe 'jobs em segundo plano' do
    let(:job_class) do
      Class.new(ActiveJob::Base) do
        include Chordata::MultiEmpresa::EscopoDoJob
        cattr_accessor :escopo_visto
        def perform
          self.class.escopo_visto = EvoExtensionPoints::RuntimeContext.current_scope_id
        end

        def self.name = 'ProbeEscopoJob'
      end
    end

    it 'carrega a empresa de quem enfileirou e a restaura ao executar' do
      a = empresa_nova("job-#{SecureRandom.hex(3)}")
      dados = na_empresa(a) { job_class.new.serialize }

      expect(dados['chordata_empresa_id']).to eq(a)
      job = job_class.new
      job.deserialize(dados)
      job.perform_now

      expect(job_class.escopo_visto).to eq(a)
      expect(Chordata::MultiEmpresa::Current.empresa_id).to be_nil
    end

    it 'job enfileirado sem empresa roda sem escopo (e qualquer consulta falha)' do
      dados = job_class.new.serialize
      expect(dados).not_to have_key('chordata_empresa_id')

      job = job_class.new
      job.deserialize(dados)
      job.perform_now
      expect(job_class.escopo_visto).to be_nil
    end
  end
end
