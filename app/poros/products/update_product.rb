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

        write_stocks! if @stocks_params.present?

        @product
      end
    end

    private

    # Advisory lock y no sólo FOR UPDATE: el upsert puede crear filas de
    # stocks que todavía no existen, y ahí FOR UPDATE no tiene nada que
    # bloquear — dos transacciones concurrentes no se ven entre sí y ambas
    # terminan en el INSERT. Además la operación abarca varias filas del mismo
    # producto, así que se serializa por producto y no fila por fila.
    #
    # El lock envuelve sólo la escritura de stocks y no el update! del
    # producto: editar el nombre no compite por stock con nadie, y con
    # wait: false envolver todo el #call devolvería 409 espurios mientras un
    # job de sincronización toca los stocks en paralelo.
    #
    # wait: false porque esto corre en el ciclo de un request HTTP: conviene
    # devolver 409 enseguida (ApplicationController mapea el
    # Shared::LockTimeoutError) antes que colgar un thread de Puma esperando.
    # El modo wait: true queda para los jobs de background.
    def write_stocks!
      validate_warehouses_belong_to_company!

      Shared::WithAdvisoryLock.new(product_id: @product.id, wait: false).call do
        upsert_stocks_for_product!
      end
    end

    def upsert_stocks_for_product!
      @stocks_params.each do |stock_attrs|
        stock = @product.stocks.find_or_initialize_by(
          warehouse_id: stock_attrs[:warehouse_id]
        )

        # product.stocks llega precargado por el controller (set_product hace
        # includes(stocks: :warehouse)), así que el objeto en memoria puede
        # traer un quantity viejo. lock! relee la fila con FOR UPDATE ya
        # adentro del advisory lock. Va antes de asignar quantity porque
        # lock! falla si el registro tiene cambios sin guardar.
        stock.lock! if stock.persisted?

        stock.quantity = stock_attrs[:quantity] || 0
        stock.save!
      end
    end
  end
end
