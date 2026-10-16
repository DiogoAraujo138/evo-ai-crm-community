# frozen_string_literal: true

module Chordata
  module MultiEmpresa
    # API para o frontend listar as empresas do usuário e para o super_admin (e o dono de cada empresa)
    # gerir empresas e vínculos. Roda SEM escopo de empresa: as tabelas empresas/empresa_usuarios são globais.
    #   GET    /api/v1/empresas                         empresas do usuário (super_admin: todas)
    #   POST   /api/v1/empresas                         cria empresa (super_admin)
    #   PATCH  /api/v1/empresas/:id                     renomeia/ativa/desativa (super_admin)
    #   GET    /api/v1/empresas/:id/usuarios            vínculos da empresa (super_admin ou dono dela)
    #   POST   /api/v1/empresas/:id/usuarios            vincula usuário {user_id|email, papel}
    #   DELETE /api/v1/empresas/:id/usuarios/:user_id   remove vínculo
    class EmpresasController < ::Api::BaseController
      skip_around_action :chordata_escopo, raise: false

      PAPEIS = %w[owner admin agent].freeze

      def index
        empresas = if super_admin?
                     Empresa.order(:nome).map { |e| serializar(e, 'super_admin') }
                   else
                     vinculos = EmpresaUsuario.includes(:empresa).where(user_id: current_user.id)
                     vinculos.select { |v| v.empresa.ativa }.sort_by { |v| v.empresa.nome }.map { |v| serializar(v.empresa, v.papel) }
                   end
        success_response(data: empresas, message: 'Empresas')
      end

      def create
        return negar unless super_admin?

        empresa = Empresa.new(params.permit(:nome, :slug))
        empresa.slug = empresa.nome.to_s.parameterize if empresa.slug.blank?
        return invalido('Informe nome e slug') if empresa.nome.blank? || empresa.slug.blank?
        return invalido('Slug já usado') if Empresa.exists?(slug: empresa.slug)

        empresa.save!
        success_response(data: serializar(empresa, 'super_admin'), message: 'Empresa criada', status: :created)
      end

      def update
        return negar unless super_admin?

        empresa = Empresa.find(params[:id])
        atributos = params.permit(:nome, :ativa).to_h
        return invalido('Nada para atualizar') if atributos.empty?

        empresa.update!(atributos)
        success_response(data: serializar(empresa, 'super_admin'), message: 'Empresa atualizada')
      end

      def usuarios
        empresa = Empresa.find(params[:id])
        return negar unless gestor_de?(empresa)

        vinculos = empresa.vinculos.order(:created_at).to_a
        usuarios = ::User.where(id: vinculos.map(&:user_id)).index_by(&:id)
        dados = vinculos.map do |v|
          { user_id: v.user_id, papel: v.papel, nome: usuarios[v.user_id]&.name, email: usuarios[v.user_id]&.email }
        end
        success_response(data: dados, message: 'Vínculos')
      end

      def vincular
        empresa = Empresa.find(params[:id])
        return negar unless gestor_de?(empresa)

        papel = params[:papel].presence || 'agent'
        return invalido("Papel inválido (#{PAPEIS.join(', ')})") unless PAPEIS.include?(papel)

        user_id = params[:user_id].presence || ::User.find_by(email: params[:email].to_s.downcase)&.id
        return invalido('Usuário não encontrado') if user_id.blank? || !::User.exists?(user_id)

        vinculo = EmpresaUsuario.find_or_initialize_by(empresa_id: empresa.id, user_id: user_id)
        vinculo.papel = papel
        vinculo.save!
        success_response(data: { user_id: user_id, papel: papel }, message: 'Usuário vinculado')
      end

      def desvincular
        empresa = Empresa.find(params[:id])
        return negar unless gestor_de?(empresa)

        removidos = EmpresaUsuario.where(empresa_id: empresa.id, user_id: params[:user_id]).delete_all
        success_response(data: { removidos: removidos }, message: 'Vínculo removido')
      end

      private

      def super_admin?
        ::Current.evo_role_key.to_s == 'super_admin'
      end

      def gestor_de?(empresa)
        super_admin? || EmpresaUsuario.exists?(empresa_id: empresa.id, user_id: current_user&.id, papel: 'owner')
      end

      def serializar(empresa, papel)
        { id: empresa.id, nome: empresa.nome, slug: empresa.slug, ativa: empresa.ativa, papel: papel }
      end

      def negar
        error_response(ApiErrorCodes::FORBIDDEN, 'Sem permissão para esta ação', status: :forbidden)
      end

      def invalido(mensagem)
        error_response(ApiErrorCodes::INVALID_PARAMETER, mensagem, status: :unprocessable_entity)
      end
    end
  end
end
