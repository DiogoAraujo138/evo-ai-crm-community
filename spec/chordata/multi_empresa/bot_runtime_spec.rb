# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/chordata/multi_empresa')
require Rails.root.join('lib/chordata/multi_empresa/requisicao')

RSpec.describe Chordata::MultiEmpresa::BotRuntime do
  let(:empresa) { '11111111-1111-1111-1111-111111111111' }

  describe Chordata::MultiEmpresa::BotRuntime::Cliente do
    let(:cliente) do
      Class.new do
        attr_reader :recebido

        def send_event(event)
          @recebido = event
        end
      end.tap { |k| k.prepend(Chordata::MultiEmpresa::BotRuntime::Cliente) }.new
    end

    it 'acrescenta a empresa do escopo ao evento' do
      Chordata::MultiEmpresa::Current.set(empresa_id: empresa) { cliente.send_event(conversation_id: 7) }
      expect(cliente.recebido).to eq(conversation_id: 7, empresa_id: empresa)
    end

    it 'sem empresa no escopo manda o evento como veio (e avisa no log)' do
      expect(Rails.logger).to receive(:warn).with(/sem empresa/)
      Chordata::MultiEmpresa::Current.set(empresa_id: nil) { cliente.send_event(conversation_id: 7) }
      expect(cliente.recebido).to eq(conversation_id: 7)
    end
  end

  describe Chordata::MultiEmpresa::BotRuntime::Retorno do
    let(:requisicao) { Chordata::MultiEmpresa::Requisicao }
    let(:controller) do
      headers = { 'X-Evo-Tenant-Id' => empresa }
      double('controller', request: double(headers: headers), render: nil)
    end

    it 'fixa a empresa do cabeçalho para o resto da ação' do
      allow(requisicao).to receive(:servico!).with(empresa).and_return(empresa)
      vista = nil
      described_class.around(controller) { vista = Chordata::MultiEmpresa::Current.empresa_id }
      expect(vista).to eq(empresa).or be_nil # sem o ponto de extensão ligado o bloco só roda
      expect(controller).not_to have_received(:render)
    end

    it 'recusa com o status da regra quando a empresa não vale e não executa a ação' do
      allow(requisicao).to receive(:servico!).and_raise(requisicao::Recusada.new('Empresa inexistente ou inativa', :forbidden))
      executou = false
      described_class.around(controller) { executou = true }
      expect(executou).to be(false)
      expect(controller).to have_received(:render).with(json: { error: 'Empresa inexistente ou inativa' }, status: :forbidden)
    end

    it 'chamada de serviço sem cabeçalho é 400' do
      allow(controller.request).to receive(:headers).and_return({})
      expect { requisicao.servico!(nil) }.to raise_error(requisicao::Recusada) { |e| expect(e.status).to eq(:bad_request) }
    end
  end

  it 'o retorno do Bot Runtime não está mais na lista de pendentes' do
    expect(Chordata::MultiEmpresa::Canais::PENDENTES.keys.join).not_to include('BotRuntimeController')
  end
end
