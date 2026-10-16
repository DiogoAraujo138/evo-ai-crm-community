# frozen_string_literal: true

namespace :chordata do
  namespace :multi_empresa do
    desc 'Instala o isolamento por empresa nas tabelas do CRM (transação única; idempotente)'
    task instalar: :environment do
      require Rails.root.join('lib/chordata/multi_empresa')
      puts "Banco: #{ActiveRecord::Base.connection.current_database}"
      Chordata::MultiEmpresa::Esquema.instalar!
      puts "Instalado em #{Chordata::MultiEmpresa::Tabelas.empresa.size} tabelas."
    end

    desc 'Remove o isolamento por empresa (apaga a coluna empresa_id e as tabelas empresas)'
    task remover: :environment do
      require Rails.root.join('lib/chordata/multi_empresa')
      puts "Banco: #{ActiveRecord::Base.connection.current_database}"
      Chordata::MultiEmpresa::Esquema.remover!
      puts 'Removido.'
    end

    desc 'Cria o papel de banco da aplicação (sem superusuário, sem bypass de RLS). Uso: PAPEL=evo_app'
    task papel_aplicacao: :environment do
      require Rails.root.join('lib/chordata/multi_empresa')
      nome = ENV.fetch('PAPEL', 'evo_app')
      Chordata::MultiEmpresa::Esquema.criar_papel_aplicacao!(ActiveRecord::Base.connection, nome)
      puts "Papel #{nome} pronto."
    end
  end
end
