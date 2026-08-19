# frozen_string_literal: true

module Products
  class UpdateProduct < ApplicationPoro
    include Concerns::WarehouseValidation

    def initialize(product:, params:, stocks:)
      super()
      @product = product
      @params = params
      @stocks_params = stocks
    end

    def call
      Product.transaction do
        @product.update!(@params)

        if @stocks_params.present?
          write_stocks!
          reload_for_render!
        end

        @product
      end
    end

    private

    # Advisory lock y no sólo FOR UPDATE: el upsert puede crear filas de
    # stocks que todavía no existen, y ahí FOR UPDATE no tiene nada que
    # bloquear. Además la operación abarca varias filas del mismo producto,
    # así que se serializa por producto y no fila por fila.
    #
    # Ojo con el alcance: esto ordena las escrituras, no detecta ediciones
    # concurrentes. Como la cantidad llega absoluta desde el request, dos
    # operadores que editan el mismo producto siguen pisándose — el último
    # gana. Detectar eso pide locking optimista (lock_version / If-Match) y
    # un cambio de contrato; ver ADR-009.
    #
    # El lock envuelve sólo la escritura de stocks y no el update! del
    # producto: editar el nombre no compite por stock con nadie, y con
    # wait: false envolver todo el #call devolvería 409 espurios mientras un
    # job de sincronización toca los stocks en paralelo.
    #
    # wait: false porque esto corre en el ciclo de un request HTTP: conviene
    # devolver 409 enseguida (ApplicationController mapea el
    # Catalog::LockTimeoutError) antes que colgar un thread de Puma esperando.
    # El modo wait: true queda para los jobs de background.
    def write_stocks!
      validate_warehouses_belong_to_company!

      Catalog::WithStockLock.new(product_id: @product.id, wait: false).call do
        upsert_stocks_for_product!
      end
    end

    def upsert_stocks_for_product!
      @stocks_params.each do |stock_attrs|
        stock = @product.stocks.find_or_initialize_by(
          warehouse_id: stock_attrs[:warehouse_id]
        )

        stock.quantity = stock_attrs[:quantity] || 0
        stock.save!
      end
    end

    # find_or_initialize_by no devuelve el objeto que el controller precargó
    # con includes(stocks: :warehouse): emite su propio SELECT y devuelve otra
    # instancia. Para una fila que ya existía eso deja la asociación cargada
    # con la cantidad vieja, y el serializer la devolvería en la respuesta —
    # un body que se contradice, con total_stock nuevo (se calcula por SQL) y
    # stocks[].quantity viejo. Se relee con el mismo eager load para que el
    # body refleje lo que quedó en la base sin reintroducir el N+1 de
    # warehouses.
    def reload_for_render!
      @product = Product.includes(stocks: :warehouse).find(@product.id)
    end
  end
end
