# frozen_string_literal: true

module Products
  class UpdateProduct < ApplicationPoro
    include Concerns::WarehouseValidation

    def initialize(product:, params:, stocks:, expected_version: nil)
      super()
      @product = product
      @params = params
      @stocks_params = stocks
      @expected_version = expected_version
    end

    def call
      Product.transaction do
        within_stock_lock do
          verify_version!
          @product.update!(@params)
          write_stocks! if @stocks_params.present?
        end

        reload_for_render! if @stocks_params.present?
        @product
      end
    end

    private

    # Locking optimista (TESIS-101). El chequeo va DENTRO de la transaccion y
    # detras de un `lock!` --o sea `SELECT ... FOR UPDATE` sobre la fila del
    # producto-- y no antes: comparar afuera dejaria pasar a dos requests que
    # leyeron la misma version, que es exactamente la carrera que esto cierra.
    # Con la fila tomada, el segundo espera, relee el estado que dejo el primero
    # y su version ya no coincide.
    #
    # Sin `expected_version` no hay precondicion que verificar y el update pasa
    # como siempre: es la semantica de `If-Match` en HTTP, y mantiene el
    # contrato anterior para cualquier cliente que no lo mande.
    def verify_version!
      return if @expected_version.blank?

      @product.lock!
      @product.stocks.reload
      current = Catalog::ProductVersion.new(product: @product).call
      return if current == @expected_version

      raise Catalog::StaleProductError.new(current_version: current)
    end

    # Advisory lock y no sólo FOR UPDATE: el upsert puede crear filas de
    # stocks que todavía no existen, y ahí FOR UPDATE no tiene nada que
    # bloquear. Además la operación abarca varias filas del mismo producto,
    # así que se serializa por producto y no fila por fila.
    #
    # Con stocks en el request, el lock se toma ANTES de verificar la versión y
    # cubre las dos cosas. Antes sólo envolvía la escritura: el `lock!` de la
    # versión bloquea la fila de `products`, pero las ventas (`DeductStock`) y
    # las transferencias no la tocan, sólo toman este advisory lock. Entre el
    # chequeo y el lock entraba una venta, la versión ya validada no la veía y
    # la cantidad absoluta del request la borraba sin rastro (hallazgo de la
    # auditoría de TESIS-89). Bajo el mismo lock, la venta espera o el PUT
    # responde 409.
    #
    # Sin stocks, nada: editar el nombre no compite por stock con nadie, y con
    # wait: false envolver ese caso devolvería 409 espurios mientras un job de
    # sincronización toca los stocks en paralelo.
    #
    # wait: false porque esto corre en el ciclo de un request HTTP: conviene
    # devolver 409 enseguida (ApplicationController mapea el
    # Catalog::LockTimeoutError) antes que colgar un thread de Puma esperando.
    # El modo wait: true queda para los jobs de background.
    def within_stock_lock(&)
      return yield if @stocks_params.blank?

      Catalog::WithStockLock.new(product_id: @product.id, wait: false).call(&)
    end

    # Corre ya dentro del advisory lock (ver `within_stock_lock`).
    def write_stocks!
      validate_warehouses_belong_to_company!
      upsert_stocks_for_product!
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
