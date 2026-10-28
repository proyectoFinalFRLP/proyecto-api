# frozen_string_literal: true

module Demo
  # Un cliente al azar para las ventas que genera Demo::GenerateRealActivity:
  # los datos del alta manual (Api::V1::OrdersController::ORDER_FIELDS), con
  # una dirección que el entorno de prueba de OCA cotiza y acepta.
  #
  # Los destinos son ciudades reales con su código postal de 4 dígitos. Todos se
  # probaron contra la tarifa de la cuenta de prueba pública de OCA (operativa
  # 64665, desde La Plata): ninguno sale sin cobertura. Mendoza y Ushuaia
  # cuestan más que el resto, así las tarifas de Reportes no son todas iguales.
  #
  # Personas y comercios inventados: nombres comunes y documentos con un formato
  # de CUIT/CUIL, sin dígito verificador real.
  class RandomCustomer < ApplicationPoro
    # [código postal, ciudad, provincia, calles]
    DESTINATIONS = [
      ['1043', 'CABA', 'Ciudad Autónoma de Buenos Aires', ['Av. Corrientes', 'Talcahuano']],
      ['1406', 'CABA', 'Ciudad Autónoma de Buenos Aires', ['Av. Rivadavia', 'Puan']],
      ['1900', 'La Plata', 'Buenos Aires', ['Calle 50', 'Calle 7', 'Diagonal 74']],
      ['1878', 'Quilmes', 'Buenos Aires', ['Rivadavia', 'Av. Calchaquí']],
      ['1640', 'Martínez', 'Buenos Aires', ['Av. Santa Fe', 'Alvear']],
      ['1708', 'Morón', 'Buenos Aires', ['Av. Rivadavia', 'Belgrano']],
      ['7600', 'Mar del Plata', 'Buenos Aires', ['Av. Colón', 'Güemes']],
      ['8000', 'Bahía Blanca', 'Buenos Aires', ['Alsina', 'Av. Alem']],
      ['2000', 'Rosario', 'Santa Fe', ['Córdoba', 'Bv. Oroño']],
      ['3000', 'Santa Fe', 'Santa Fe', ['San Martín', 'Bv. Gálvez']],
      ['3100', 'Paraná', 'Entre Ríos', ['Urquiza', 'Av. Ramírez']],
      ['5000', 'Córdoba', 'Córdoba', ['Av. Colón', 'Deán Funes']],
      ['5500', 'Mendoza', 'Mendoza', ['Av. San Martín', 'Las Heras']],
      ['4000', 'San Miguel de Tucumán', 'Tucumán', ['24 de Septiembre', 'Av. Mate de Luna']],
      ['8300', 'Neuquén', 'Neuquén', ['Av. Argentina', 'Belgrano']],
      ['9410', 'Ushuaia', 'Tierra del Fuego', ['San Martín', 'Maipú']]
    ].freeze

    FIRST_NAMES = %w[Lucía Martín Sofía Mateo Valentina Joaquín Camila Tomás Florencia
                     Nicolás Agustina Santiago Julieta Facundo Micaela Ignacio Paula Gonzalo].freeze
    LAST_NAMES = %w[González Rodríguez Fernández López Martínez Pérez Gómez Díaz Sosa Romero
                    Álvarez Torres Ruiz Ramírez Flores Benítez Acosta Medina Herrera Suárez].freeze
    BUSINESSES = ['Ferretería', 'Librería', 'Estudio Contable', 'Farmacia', 'Taller',
                  'Consultorio', 'Almacén', 'Imprenta', 'Óptica', 'Distribuidora'].freeze

    # Uno de cada tres clientes es un comercio.
    BUSINESS_SHARE = 1.0 / 3

    def initialize(random: Random.new)
      super()
      @random = random
    end

    def call
      zip_code, city, province, streets = DESTINATIONS.sample(random: @random)
      business = @random.rand < BUSINESS_SHARE
      { customer_name: business ? business_name : person_name,
        customer_document: document(business ? 30 : 20),
        customer_phone: format('11 %<a>04d-%<b>04d', a: number(1000..9999), b: number(0..9999)),
        customer_address: "#{streets.sample(random: @random)} #{number(100..4999)}",
        customer_zip_code: zip_code, customer_city: city, customer_province: province }
    end

    private

    def person_name = "#{pick(FIRST_NAMES)} #{pick(LAST_NAMES)}"

    def business_name = "#{pick(BUSINESSES)} #{pick(LAST_NAMES)}"

    def document(prefix)
      format('%<p>d-%<n>08d-%<d>d', p: prefix, n: number(10_000_000..45_000_000), d: number(0..9))
    end

    def pick(list) = list.sample(random: @random)

    def number(range) = @random.rand(range)
  end
end
