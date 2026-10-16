# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/chordata/multi_empresa')

# Guarda contra o upstream: tabela ou índice único novo do Evo sem classificação faz este teste FALHAR,
# obrigando a decidir se é dado de empresa, global ou identidade (ADR-0007).
RSpec.describe Chordata::MultiEmpresa::Tabelas do
  let(:conn) { ActiveRecord::Base.connection }

  it 'classifica todas as tabelas do banco, sem sobra e sem faltar' do
    reais = conn.tables.sort
    classificadas = described_class.todas_classificadas

    expect(reais - classificadas).to be_empty, "tabelas sem classificação: #{(reais - classificadas).inspect}"
    ausentes = (classificadas - reais - described_class::PROPRIAS).sort
    expect(ausentes).to be_empty, "classificadas mas inexistentes: #{ausentes.inspect}"
  end

  it 'não classifica a mesma tabela duas vezes' do
    todas = described_class.empresa + described_class::GLOBAIS + described_class::IDENTIDADE
    repetidas = todas.group_by(&:itself).select { |_, v| v.size > 1 }.keys

    expect(repetidas).to be_empty
  end

  it 'classifica todo índice único das tabelas de empresa' do
    rows = conn.select_rows(<<~SQL)
      SELECT t.relname,
        (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
           FROM unnest(ix.indkey) WITH ORDINALITY k(attnum, ord)
           JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = k.attnum)
      FROM pg_index ix JOIN pg_class t ON t.oid = ix.indrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
      WHERE n.nspname = 'public' AND ix.indisunique AND NOT ix.indisprimary
    SQL
    reais = rows.select { |tabela, _| described_class.empresa.include?(tabela) }
    sem_classificacao = reais.reject { |tabela, cols| described_class::UNICOS.dig(tabela, cols) }

    expect(sem_classificacao).to be_empty, "índices únicos sem classificação: #{sem_classificacao.inspect}"

    declarados = described_class::UNICOS.flat_map { |t, idx| idx.keys.map { |c| [t, c] } }
    inexistentes = declarados - reais.uniq
    expect(inexistentes).to be_empty, "classificados mas inexistentes no banco: #{inexistentes.inspect}"
  end

  it 'toda chave de resolução é uma coluna única global de tabela de empresa' do
    described_class.chaves_de_resolucao.each do |tabela, coluna|
      expect(described_class.empresa).to include(tabela)
      next if (described_class::CHAVES_EM_JSON + described_class::CHAVES_POR_ID).include?([tabela, coluna]) # JSON/PK: tratadas à parte

      expect(described_class::UNICOS.dig(tabela, coluna)).to eq(:global)
    end
    expect(described_class.chaves_de_resolucao.size).to be >= 15
  end
end
