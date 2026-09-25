# frozen_string_literal: true

require 'rails_helper'

# Login y sesión del backoffice (QA de TESIS-129). El administrador ve los
# datos de todas las empresas, así que una sesión que dura de más o que
# sobrevive al logout las expone a todas a la vez.
RSpec.describe 'Admin backoffice session', type: :request do
  let(:admin_user) { AdminUser.create!(email: 'admin@backoffice.com', password: 'admin123') }

  def log_in(email: admin_user.email, password: 'admin123', remember: '0')
    post '/admin/sign_in', params: { admin_user: { email:, password:, remember_me: remember } }
  end

  # El status y el mensaje de alerta con que responde un intento de login.
  def login_answer(**credentials)
    log_in(**credentials)
    [response.status, response.body[/class="alert">([^<]*)/, 1]]
  end

  # Cuántas veces corrió bcrypt durante un intento de login.
  def bcrypt_runs_for(**credentials)
    runs = 0
    allow(BCrypt::Engine).to receive(:hash_secret).and_wrap_original do |original, *args|
      runs += 1
      original.call(*args)
    end
    log_in(**credentials)
    runs
  end

  describe 'failed login' do
    let(:generic_answer) { [422, 'Invalid email or password.'] }

    it 'answers a wrong password and an unknown email the same way', :aggregate_failures do
      expect(login_answer(password: 'wrong')).to eq(generic_answer)
      expect(login_answer(email: 'nadie@backoffice.com', password: 'wrong')).to eq(generic_answer)
    end

    # Sin config.paranoid el login de un email inexistente volvía ~200 ms antes,
    # porque bcrypt sólo corría cuando había cuenta: el tiempo decía qué emails
    # existen aunque el mensaje fuera el mismo.
    it 'runs bcrypt as many times for an unknown email as for a wrong password' do
      admin_user
      wrong_password = bcrypt_runs_for(password: 'wrong')

      expect(bcrypt_runs_for(email: 'nadie@backoffice.com', password: 'wrong')).to eq(wrong_password)
    end
  end
end
