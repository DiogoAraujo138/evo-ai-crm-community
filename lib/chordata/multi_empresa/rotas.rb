# frozen_string_literal: true

module Chordata
  module MultiEmpresa
    module Rotas
      def self.ligar!
        Rails.application.routes.prepend do
          scope '/api/v1', defaults: { format: 'json' } do
            get 'empresas', to: 'chordata/multi_empresa/empresas#index'
            post 'empresas', to: 'chordata/multi_empresa/empresas#create'
            patch 'empresas/:id', to: 'chordata/multi_empresa/empresas#update'
            get 'empresas/:id/usuarios', to: 'chordata/multi_empresa/empresas#usuarios'
            post 'empresas/:id/usuarios', to: 'chordata/multi_empresa/empresas#vincular'
            delete 'empresas/:id/usuarios/:user_id', to: 'chordata/multi_empresa/empresas#desvincular'
          end
        end
      end
    end
  end
end
