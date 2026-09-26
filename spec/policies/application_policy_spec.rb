# frozen_string_literal: true

require 'rails_helper'

# La base de la que heredan todas las policies (TESIS-93).
#
# Lo que se prueba acá no es una regla de negocio sino una postura: **nada está
# permitido salvo que una policy concreta lo permita**. Cada uno de estos
# defaults es lo que va a contestar una acción nueva cuya policy todavía no se
# escribió, o un recurso al que alguien le agregó un endpoint y se olvidó del
# permiso. Que respondan `false` es la diferencia entre un permiso faltante que
# se nota y uno que se filtra.
#
# Ninguna policy real ejercita estos métodos —todas los pisan—, así que sin
# estos ejemplos el comportamiento por defecto no lo verifica nadie.
RSpec.describe ApplicationPolicy do
  subject(:policy) { described_class.new(user, record) }

  let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
  let(:user) { User.create!(email: 'a@acme.com', password: 'pass123', company: company) }
  let(:record) { Product.new(company: company, sku: 'SKU-1', name: 'Widget') }

  describe 'the default answer to every action' do
    it 'refuses to list', :aggregate_failures do
      expect(policy.index?).to be(false)
      expect(policy.show?).to be(false)
    end

    it 'refuses to write', :aggregate_failures do
      expect(policy.create?).to be(false)
      expect(policy.update?).to be(false)
      expect(policy.destroy?).to be(false)
    end

    # Con un usuario presente y un registro de su propia empresa: la negativa no
    # depende de que falte el usuario, es el default.
    it 'refuses even to an authenticated user over a record of their own company' do
      expect(policy.index?).to be(false)
    end
  end

  # `new?` y `edit?` no tienen regla propia: son las vistas de `create?` y
  # `update?`. Si alguien redefine `create?` y se olvida de `new?`, esto fija
  # que no hacía falta acordarse.
  describe 'the aliases of the write actions' do
    it 'answers new? with create?' do
      expect(policy.new?).to eq(policy.create?)
    end

    it 'answers edit? with update?' do
      expect(policy.edit?).to eq(policy.update?)
    end

    context 'when a subclass allows creating and updating' do
      let(:permissive) do
        Class.new(described_class) do
          def create? = true
          def update? = true
        end
      end

      it 'follows the subclass instead of the default', :aggregate_failures do
        subclass_policy = permissive.new(user, record)

        expect(subclass_policy.new?).to be(true)
        expect(subclass_policy.edit?).to be(true)
      end
    end
  end

  describe ApplicationPolicy::Scope do
    # Un Scope que no define `resolve` no devuelve "todo": explota. Es el otro
    # lado de la misma postura — una policy a medio escribir falla a la vista y
    # no filtra la tabla entera del tenant equivocado.
    it 'refuses to resolve a scope that did not define it' do
      scope = described_class.new(user, Product.all)

      expect { scope.resolve }.to raise_error(NoMethodError, /must define #resolve/)
    end

    it 'names the class that has to define it' do
      incomplete = Class.new(described_class)
      stub_const('IncompleteScope', incomplete)

      expect { incomplete.new(user, Product.all).resolve }
        .to raise_error(NoMethodError, /IncompleteScope/)
    end
  end
end
