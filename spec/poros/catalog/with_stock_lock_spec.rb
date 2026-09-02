# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable-next RSpec/ExampleLength, RSpec/MultipleExpectations
RSpec.describe Catalog::WithStockLock, type: :poro do
  # Este describe cubre la parte que justifica la card entera: que el advisory
  # lock realmente serializa escrituras entre conexiones/threads distintos.
  # Para eso hace falta desactivar el wrapping transaccional de RSpec: si no,
  # los "threads" concurrentes viven dentro de la misma transacción de test y
  # nunca compiten de verdad por el lock (ver ADR-009, sección Consecuencias).
  describe 'concurrencia real (sin transactional tests)' do
    self.use_transactional_tests = false

    let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
    let(:warehouse) do
      Warehouse.create!(company: company, name: 'Central', zip_code: '1900', address: 'Calle 1')
    end
    let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Widget') }
    let(:stock) { Stock.create!(product: product, warehouse: warehouse, quantity: 10) }

    after do
      # use_transactional_tests = false implica que nada se revierte solo:
      # hay que limpiar a mano, y en orden por las FKs. unscoped porque el
      # default_scope de CompanyScoped filtraría por el Current.company_id
      # del thread principal, que en algunos ejemplos ya fue reseteado.
      Stock.unscoped.delete_all
      Product.unscoped.delete_all
      Warehouse.unscoped.delete_all
      Company.unscoped.delete_all
    end

    # Levanta un thread que hace un incremento read-modify-write sobre `stock`
    # dentro de la sección crítica dada. Cada thread necesita su propia
    # conexión del pool y su propio Current.company_id: ninguno de los dos se
    # comparte entre threads.
    def spawn_incrementer(errors)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.company_id = company.id
          yield
        rescue StandardError => e
          errors << e
        end
      end
    end

    context 'with the lock held via wait: true (the default)' do
      it 'no pierde updates entre 5 threads que incrementan la misma fila' do
        stock
        errors = []
        # timeout_ms generoso: 5 threads serializándose por el lock, cada uno
        # reteniéndolo ~0.05s, puede acercarse al DEFAULT_TIMEOUT_MS de 3000ms
        # sumando overhead de scheduling. 10_000 evita un flake por timeout
        # sin relacionarse con lo que el ejemplo realmente verifica.
        threads = Array.new(5) do
          spawn_incrementer(errors) do
            described_class.new(product_id: product.id, timeout_ms: 10_000).call do
              row = Stock.unscoped.find(stock.id)
              current_quantity = row.quantity
              sleep 0.05
              row.update!(quantity: current_quantity + 1)
            end
          end
        end
        threads.each(&:join)

        expect(errors).to be_empty
        expect(Stock.unscoped.find(stock.id).quantity).to eq(15)
      end
    end

    context 'without the lock' do
      it 'SÍ pierde updates entre 5 threads que incrementan la misma fila' do
        # Sin el advisory lock, los 5 threads leen `quantity` antes de que
        # ninguno escriba (gracias al sleep), así que las 5 escrituras se
        # basan en el mismo valor inicial: se pisan entre sí y el resultado
        # queda estrictamente por debajo de inicial + 5. Esto es justamente
        # lo que el PORO existe para evitar.
        stock
        errors = []
        threads = Array.new(5) do
          spawn_incrementer(errors) do
            ActiveRecord::Base.transaction do
              row = Stock.unscoped.find(stock.id)
              current_quantity = row.quantity
              sleep 0.05
              row.update!(quantity: current_quantity + 1)
            end
          end
        end
        threads.each(&:join)

        expect(errors).to be_empty
        expect(Stock.unscoped.find(stock.id).quantity).to be < 15
      end
    end

    it 'no bloquea entre productos distintos, aunque sí choca contra la misma clave' do
      other_company = Current.set(company_id: nil) do
        Company.create!(name: 'Other Corp', tax_id: '30-99999999-9')
      end
      other_warehouse = Current.set(company_id: nil) do
        Warehouse.create!(company: other_company, name: 'Other WH', zip_code: '2000',
                          address: 'Otra calle')
      end
      other_product = Current.set(company_id: nil) do
        Product.create!(company: other_company, sku: 'SKU-002', name: 'Other Widget')
      end
      Current.set(company_id: nil) do
        Stock.create!(product: other_product, warehouse: other_warehouse, quantity: 1)
      end

      release = Queue.new
      holder_ready = Queue.new
      errors = []
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.company_id = company.id
          described_class.new(product_id: product.id).call do
            holder_ready << true
            release.pop
          end
        rescue StandardError => e
          errors << e
        end
      end

      begin
        holder_ready.pop

        # Otro producto (de otra empresa, para que el caso sea el real) pide su
        # propio lock mientras el primero sigue tomado: la clave es distinta,
        # así que no debería haber contención.
        Current.company_id = other_company.id
        expect do
          described_class.new(product_id: other_product.id, wait: false).call { 1 }
        end.not_to raise_error

        # En cambio, pedir la MISMA clave (el producto original) sí choca: esto
        # prueba que lo anterior pasó por la clave del lock y no porque el lock
        # no estuviera realmente tomado.
        Current.company_id = company.id
        expect do
          described_class.new(product_id: product.id, wait: false).call { 1 }
        end.to raise_error(Catalog::LockTimeoutError)
      ensure
        release << true
        holder.join
      end

      expect(errors).to be_empty
    end

    it 'con wait: false falla al instante si el mismo lock ya está tomado' do
      Current.company_id = company.id
      release = Queue.new
      holder_ready = Queue.new
      errors = []
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.company_id = company.id
          described_class.new(product_id: product.id).call do
            holder_ready << true
            release.pop
          end
        rescue StandardError => e
          errors << e
        end
      end

      begin
        holder_ready.pop

        expect do
          described_class.new(product_id: product.id, wait: false).call { 1 }
        end.to raise_error(Catalog::LockTimeoutError)
      ensure
        release << true
        holder.join
      end

      expect(errors).to be_empty
    end

    it 'con wait: true respeta el lock_timeout configurado' do
      Current.company_id = company.id
      release = Queue.new
      holder_ready = Queue.new
      errors = []
      holder = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Current.company_id = company.id
          described_class.new(product_id: product.id).call do
            holder_ready << true
            release.pop
          end
        rescue StandardError => e
          errors << e
        end
      end

      begin
        holder_ready.pop

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect do
          described_class.new(product_id: product.id, timeout_ms: 300).call { 1 }
        end.to raise_error(Catalog::LockTimeoutError)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        # Aserción laxa a propósito: sólo confirma que el timeout se respetó y
        # no que colgó esperando indefinidamente (bien por debajo del
        # DEFAULT_TIMEOUT_MS de 3000 que hubiéramos visto sin pasar timeout_ms).
        expect(elapsed).to be < 3
      ensure
        release << true
        holder.join
      end

      expect(errors).to be_empty
    end
  end

  # El resto de los ejemplos no necesitan concurrencia real: alcanza con el
  # wrapping transaccional default de RSpec, que revierte todo solo.
  describe 'comportamiento sin concurrencia' do
    let(:company) { Company.create!(name: 'Acme', tax_id: '20-12345678-9') }
    let(:product) { Product.create!(company: company, sku: 'SKU-001', name: 'Widget') }

    before { Current.company_id = company.id }

    describe '#call' do
      it 'devuelve el valor del bloque' do
        result = described_class.new(product_id: product.id).call { 'block result' }
        expect(result).to eq('block result')
      end

      # La clave no depende del tenant, así que el lock se puede tomar desde
      # una consola, una tarea de rake o un bloque unscoped, donde no hay
      # Current.company_id que valga.
      it 'funciona sin Current.company_id seteado' do
        Current.company_id = nil
        block_called = false

        expect do
          described_class.new(product_id: product.id).call { block_called = true }
        end.not_to raise_error
        expect(block_called).to be(true)
      end
    end

    describe '#lock_key' do
      it 'es determinista para el mismo producto' do
        key_a = described_class.new(product_id: product.id).lock_key
        key_b = described_class.new(product_id: product.id).lock_key
        expect(key_a).to eq(key_b)
      end

      # products.id es PK global: dos empresas nunca comparten un product_id,
      # así que meter el tenant en la clave no aislaría nada que el product_id
      # no aísle solo.
      it 'no depende de la empresa activa' do
        base_key = described_class.new(product_id: product.id).lock_key
        other_company = Current.set(company_id: nil) do
          Company.create!(name: 'Other Corp', tax_id: '30-99999999-9')
        end

        Current.company_id = other_company.id
        other_key = described_class.new(product_id: product.id).lock_key

        expect(other_key).to eq(base_key)
      end

      it 'cambia si cambia el producto' do
        other_product = Product.create!(company: company, sku: 'SKU-002', name: 'Other Widget')

        base_key = described_class.new(product_id: product.id).lock_key
        other_key = described_class.new(product_id: other_product.id).lock_key

        expect(other_key).not_to eq(base_key)
      end

      it 'cambia si cambia el namespace' do
        base_key = described_class.new(product_id: product.id).lock_key
        other_key = described_class.new(product_id: product.id, namespace: 'orders').lock_key

        expect(other_key).not_to eq(base_key)
      end
    end
  end
end
