# frozen_string_literal: true

# Multi-empresa (ADR-0007). DESLIGADO por padrão: sem MULTI_EMPRESA=on o CRM se comporta como o Evo
# comunitário. Ligar só depois de `rake chordata:multi_empresa:instalar` e com a aplicação conectada
# por um papel que NÃO seja superusuário (senão o RLS não vale).
if ENV['MULTI_EMPRESA'] == 'on'
  require Rails.root.join('lib/chordata/multi_empresa')
  Chordata::MultiEmpresa.ligar!
end
