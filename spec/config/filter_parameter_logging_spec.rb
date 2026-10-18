# frozen_string_literal: true

require 'rails_helper'

# Lo que el log de producción escribe en la línea `Parameters:` pasa por este
# filtro. Las credenciales de una integración se cargan desde Avo con el nombre
# que les da el proveedor, así que no alcanza con filtrar `password`.
RSpec.describe 'config/initializers/filter_parameter_logging.rb' do # rubocop:disable RSpec/DescribeClass
  let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

  it 'hides every credential the Avo connection action sends', :aggregate_failures do
    fields = { 'credentials__usr' => 'test@oca.com.ar', 'credentials__psw' => '123456',
               'settings__cuit' => '30-53625919-4' }

    filtered = filter.filter('fields' => fields)['fields']

    expect(filtered.values_at('credentials__usr', 'credentials__psw')).to all(eq('[FILTERED]'))
    expect(filtered['settings__cuit']).to eq('30-53625919-4')
  end

  it 'hides an OCA password sent without the prefix' do
    expect(filter.filter('psw' => '123456')['psw']).to eq('[FILTERED]')
  end
end
