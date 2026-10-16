# frozen_string_literal: true

# Respuestas reales del entorno de prueba de OCA e-Pak, capturadas el
# 2026-10-16 (TESIS-186). Ver spec/fixtures/oca/.
module OcaFixtures
  def oca_fixture(name)
    Rails.root.join('spec/fixtures/oca', name).read
  end

  def oca_xml(name)
    { status: 200, headers: { 'Content-Type' => 'text/xml; charset=utf-8' },
      body: oca_fixture("#{name}.xml") }
  end
end

RSpec.configure { |config| config.include OcaFixtures }
