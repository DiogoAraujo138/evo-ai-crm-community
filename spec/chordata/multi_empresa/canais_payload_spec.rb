# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('lib/chordata/multi_empresa')

RSpec.describe Chordata::MultiEmpresa::Canais::FiltroPayload do
  let(:empresa) { '11111111-1111-1111-1111-111111111111' }
  let(:rota) { Chordata::MultiEmpresa::Canais::PAYLOAD.find { |r| r[:controller] == 'Webhooks::WhatsappController' } }
  let(:whatsapp) { described_class }

  def controller_com(params, corpo = nil)
    double('controller', params: ActionController::Parameters.new(params), render: nil,
                         request: double(raw_post: corpo.to_s))
  end

  def rota_de(nome)
    Chordata::MultiEmpresa::Canais::PAYLOAD.find { |r| r[:controller] == nome }
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

  describe 'Evolution Hub, Gmail e SendGrid' do
    it 'Hub: eventos da Meta repassados usam as mesmas chaves; ciclo de vida do Hub fica sem chave' do
      hub = rota_de('Webhooks::EvolutionHubController')
      wa = { object: 'whatsapp_business_account', entry: [{ id: 'waba-9', changes: [{ value: { metadata: { phone_number_id: 'pn-9' } } }] }] }
      c = controller_com({}, wa.to_json)
      expect(hub[:candidatas].call(c).first).to eq(['channel_whatsapp', 'provider_config->>phone_number_id', 'pn-9'])
      expect(hub[:candidatas].call(controller_com({}, { object: 'page', entry: [{ id: 'p1' }] }.to_json)))
        .to eq([['channel_facebook_pages', 'page_id', 'p1']])
      expect(hub[:candidatas].call(controller_com({}, { object: 'instagram', entry: [{ id: 'i1' }] }.to_json)))
        .to eq([['channel_instagram', 'instagram_id', 'i1']])
      expect(hub[:candidatas].call(controller_com({}, { event_type: 'channel_connected' }.to_json))).to be_empty
      expect(hub[:candidatas].call(controller_com({}, 'não é json'))).to be_empty
    end

    it 'Gmail: lê o e-mail do Pub/Sub (message.data em base64) ou de campos soltos' do
      gmail = rota_de('Webhooks::GmailController')
      dados = Base64.strict_encode64({ emailAddress: 'caixa@exemplo.invalid', historyId: 1 }.to_json)
      corpo = { message: { data: dados, messageId: 'm1' } }.to_json
      expect(gmail[:candidatas].call(controller_com({}, corpo))).to eq([['channel_email', 'email', 'caixa@exemplo.invalid']])
      expect(gmail[:candidatas].call(controller_com({ emailAddress: 'solta@exemplo.invalid' }, '{}')).first.last).to eq('solta@exemplo.invalid')
      expect(gmail[:candidatas].call(controller_com({}, 'lixo')).first.last).to be_nil
    end

    it 'SendGrid: usa o message_id do primeiro evento (direto ou em custom_args)' do
      sg = rota_de('Webhooks::SendgridController')
      expect(sg[:candidatas].call(controller_com({}, [{ event: 'delivered', custom_args: { message_id: 'msg-1' } }].to_json)))
        .to eq([['messages', 'id', 'msg-1']])
      expect(sg[:candidatas].call(controller_com({}, [{ message_id: 'msg-2' }, { message_id: 'msg-3' }].to_json)).first.last).to eq('msg-2')
      expect(sg[:candidatas].call(controller_com({}, 'nada')).first.last).to be_nil
    end
  end
end
