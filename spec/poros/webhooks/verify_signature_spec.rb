# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::VerifySignature, type: :poro do
  let(:signature) { 'hmac_sha256_base64' }
  let(:service) do
    Service.create!(service_name: 'Shopify', type: 'ecommerce', http_method: 'POST',
                    uri: 'https://shop.test/graphql.json',
                    webhook_config: { 'signature' => signature,
                                      'signature_header' => 'X-Shopify-Hmac-SHA256',
                                      'secret_key' => 'client_secret' })
  end
  let(:credentials) { { 'client_id' => 'CLIENT-ID', 'client_secret' => 'shpss_SECRET' } }
  let(:integration) do
    CompanyIntegration.create!(company: Company.create!(name: 'Acme', tax_id: '20-12345678-9'),
                               service: service, credentials: credentials)
  end

  # Con espacios y una tilde sin escapar: re-serializar este JSON cambiaría
  # los bytes, y con ellos el HMAC.
  def raw_body = '{"id": 1, "shipping_address": {"name": "Juana Pérez"}}'

  def hmac(body = raw_body, secret = 'shpss_SECRET')
    OpenSSL::HMAC.digest('SHA256', secret, body)
  end

  def verify(headers)
    described_class.new(company_integration: integration, raw_body: raw_body,
                        headers: headers).call
  end

  it 'accepts the event signed with the secret of the integration' do
    expect { verify('X-Shopify-Hmac-SHA256' => Base64.strict_encode64(hmac)) }.not_to raise_error
  end

  it 'reads the header case-insensitively, the way Rails exposes it' do
    headers = ActionDispatch::Http::Headers.from_hash(
      'HTTP_X_SHOPIFY_HMAC_SHA256' => Base64.strict_encode64(hmac)
    )
    expect { verify(headers) }.not_to raise_error
  end

  it 'rejects a body altered after it was signed' do
    signed = Base64.strict_encode64(hmac(raw_body.sub('1', '2')))
    expect { verify('X-Shopify-Hmac-SHA256' => signed) }
      .to raise_error(Webhooks::InvalidSignatureError, 'signature does not match')
  end

  it 'rejects an event signed with the app of another company' do
    signed = Base64.strict_encode64(hmac(raw_body, 'shpss_OTHER_COMPANY'))
    expect { verify('X-Shopify-Hmac-SHA256' => signed) }
      .to raise_error(Webhooks::InvalidSignatureError)
  end

  it 'rejects an event without the signature header' do
    expect { verify({}) }
      .to raise_error(Webhooks::InvalidSignatureError, /X-Shopify-Hmac-SHA256 header is missing/)
  end

  context 'when the integration has no secret to verify with' do
    let(:credentials) { { 'client_id' => 'CLIENT-ID' } }

    it 'rejects the event instead of skipping the verification' do
      expect { verify('X-Shopify-Hmac-SHA256' => Base64.strict_encode64(hmac)) }
        .to raise_error(Webhooks::InvalidSignatureError, /client_secret is not configured/)
    end
  end

  context 'when the provider signs in hex' do
    let(:signature) { 'hmac_sha256_hex' }

    it 'accepts the hex digest' do
      expect { verify('X-Shopify-Hmac-SHA256' => hmac.unpack1('H*')) }.not_to raise_error
    end

    it 'rejects the base64 one' do
      expect { verify('X-Shopify-Hmac-SHA256' => Base64.strict_encode64(hmac)) }
        .to raise_error(Webhooks::InvalidSignatureError)
    end
  end

  context 'when the template does not declare a signature' do
    let(:service) do
      Service.create!(service_name: 'Mercado Libre', type: 'ecommerce', http_method: 'GET',
                      uri: 'https://api.ml.test')
    end

    it 'accepts the event as before' do
      expect { verify({}) }.not_to raise_error
    end
  end
end
