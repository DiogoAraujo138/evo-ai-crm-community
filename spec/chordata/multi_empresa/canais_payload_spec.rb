# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/chordata/multi_empresa')

RSpec.describe Chordata::MultiEmpresa::Canais::FiltroPayload do
  let(:empresa) { '11111111-1111-1111-1111-111111111111' }
  let(:rota) { Chordata::MultiEmpresa::Canais::PAYLOAD.find { |r| r[:controller] == 'Webhooks::WhatsappController' } }
  let(:whatsapp) { described_class }

  def controller_com(params)
    double('controller', params: ActionController::Parameters.new(params), render: nil)
  end

  def candidatas(params)
    rota[:candidatas].call(controller_com(params)).reject { |_t, _c, v| v.blank? }
  end

  it 'extrai as chaves de cada provedor do WhatsApp, na ordem do job' do
    cloud = { entry: [{ id: 'waba-1', changes: [{ value: { metadata: { phone_number_id: 'pn-1' } } }] }], object: 'whatsapp_business_account' }
    expect(candidatas(cloud).first).to eq(['channel_whatsapp', 'provider_config->>phone_number_id', 'pn-1'])
    expect(candidatas(cloud).map { |c| c[1] }).to include('provider_config->>waba_id', 'provider_config->>business_account_id')

    expect(candidatas({ instanceId: 'i-1', type: 'ReceivedCallback' }).map { |c| c[1] })
      .to include('provider_config->>instance_id', 'provider_config->>instance_uuid')
    expect(candidatas({ instance: 'minha', event: 'messages.upsert' })).to eq([['channel_whatsapp', 'provider_config->>instance_name', 'minha']])
    expect(candidatas({ 'hub.mode': 'subscribe' })).to be_empty
  end

  it 'Instagram e Facebook usam o id da primeira entrada' do
    ig = Chordata::MultiEmpresa::Canais::PAYLOAD.find { |r| r[:controller] == 'Webhooks::InstagramController' }
    fb = Chordata::MultiEmpresa::Canais::PAYLOAD.find { |r| r[:controller] == 'Webhooks::FacebookController' }
    c = controller_com(entry: [{ id: '123' }, { id: '456' }])
    expect(ig[:candidatas].call(c)).to eq([['channel_instagram', 'instagram_id', '123']])
    expect(fb[:candidatas].call(c)).to eq([['channel_facebook_pages', 'page_id', '123']])
  end

  it 'fixa a empresa achada, tentando as chaves em ordem' do
    allow(Chordata::MultiEmpresa).to receive(:resolver_empresa_do_canal) { |_t, col, _v| col.end_with?('instance_name') ? empresa : nil }
    controller = controller_com(instanceId: 'x', instance: 'minha', event: 'e')
    rodou = false
    whatsapp.around(controller, rota) { rodou = true }
    expect(rodou).to be(true)
    expect(controller).not_to have_received(:render)
  end

  it 'chave presente mas desconhecida (ou ambígua) é 404 e a ação não roda' do
    allow(Chordata::MultiEmpresa).to receive(:resolver_empresa_do_canal).and_return(nil)
    controller = controller_com(instance: 'minha', event: 'e')
    rodou = false
    whatsapp.around(controller, rota) { rodou = true }
    expect(rodou).to be(false)
    expect(controller).to have_received(:render).with(json: { error: 'Canal não encontrado' }, status: :not_found)
  end

  it 'sem nenhuma chave no corpo (verificação GET da Meta) segue sem escopo, como antes' do
    controller = controller_com({})
    rodou = false
    whatsapp.around(controller, rota) { rodou = true }
    expect(rodou).to be(true)
  end

  it 'não reresolve quando a URL já definiu a empresa' do
    expect(Chordata::MultiEmpresa).not_to receive(:resolver_empresa_do_canal)
    rodou = false
    Chordata::MultiEmpresa::Current.set(empresa_id: empresa) { whatsapp.around(controller_com(instance: 'x', event: 'e'), rota) { rodou = true } }
    expect(rodou).to be(true)
  end
end
