# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/chordata/multi_empresa')
require Rails.root.join('lib/chordata/multi_empresa/busca')

# A contagem de contatos fica em cache (Redis, 1 min). A chave do upstream não tinha a empresa: sem esta camada, o total de
# uma empresa apareceria para outra.
RSpec.describe Chordata::MultiEmpresa::Busca::Contatos do
  let(:base) do
    Class.new do
      attr_reader :params, :contacts_count_visto

      def initialize
        @params = {}
      end

      def cache_key_for_contacts_count
        'contacts_count/all'
      end

      def apply_pagination; end
    end
  end
  let(:controller) { Class.new(base) { prepend Chordata::MultiEmpresa::Busca::Contatos }.new }

  it 'a chave do cache da contagem é diferente em cada empresa' do
    a = SecureRandom.uuid
    b = SecureRandom.uuid
    chave_a = Chordata::MultiEmpresa::Current.set(empresa_id: a) { controller.cache_key_for_contacts_count }
    chave_b = Chordata::MultiEmpresa::Current.set(empresa_id: b) { controller.cache_key_for_contacts_count }

    expect(chave_a).not_to eq(chave_b)
    expect(chave_a).to include(a)
    expect(chave_b).to include(b)
  end

  it 'reaproveita a contagem já calculada na paginação, sem novo COUNT' do
    colecao = Class.new { def total_count = raise('não deveria contar de novo') }.new
    controller.instance_variable_set(:@contacts, colecao)
    controller.instance_variable_set(:@contacts_count, 123)

    controller.apply_pagination

    expect(colecao.instance_variable_get(:@total_count)).to eq(123)
  end
end
