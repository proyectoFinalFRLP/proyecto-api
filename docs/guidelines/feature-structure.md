# Estructura de Features (Dominios de Negocio)

Esta guía define cómo trabajar con la organización basada en dominios de negocio del backend. El objetivo es maximizar la cohesión dentro de cada dominio, reducir el acoplamiento entre ellos y que el código sea predecible de encontrar y navegar.

## 1. Concepto Fundamental

Los archivos se agrupan por **dominio de negocio** (qué hace para el negocio), no por tipo técnico. Un cambio en el dominio `orders` debería tocar solo archivos bajo `orders` — model, PORO, serializer, policy, specs — sin impactar otros dominios.

## 2. Los seis dominios del proyecto

| Dominio        | Epic Jira  | Alcance                                                            |
| -------------- | ---------- | ------------------------------------------------------------------ |
| `auth`         | TESIS-19   | Companies, Users, Warehouses, autenticación JWT, multi-tenancy     |
| `integrations` | TESIS-20   | Plantillas de APIs externas (Services), credenciales (CompanyIntegrations), HTTP Adapter |
| `catalog`      | TESIS-21   | Products, StockPerWarehouse, ProductMappings, Outbound Sync        |
| `webhooks`     | TESIS-22   | WebhookLog, colas de mensajes, bloqueos distribuidos, reintentos   |
| `orders`       | TESIS-23   | Orders, OrderItems, procesamiento de webhooks de canales, idempotencia |
| `shipments`    | TESIS-24   | Shipments, TrackingEvents, cotización de couriers, Push/Pull tracking |

## 3. Dónde vive cada tipo de archivo

### Models

Los models viven en `app/models/` (plano, sin subdirectorios). Cada model representa una tabla.

### POROs (lógica de negocio)

Los POROs se organizan por dominio:

```
app/poros/
├── application_poro.rb
├── auth/
│   ├── register_company.rb      # Crea empresa + usuario inicial
│   └── authenticate_user.rb
├── catalog/
│   ├── create_product.rb
│   ├── update_stock.rb          # Actualiza stock + dispara Outbound Sync
│   └── outbound_sync.rb        # Propaga cambio de stock a canales externos
├── orders/
│   ├── create_order.rb
│   ├── confirm_order.rb        # Confirma orden + descuenta stock
│   └── process_webhook_order.rb # Ingesta orden de un canal externo
└── shipments/
    ├── quote_shipment.rb        # Cotización concurrente con múltiples couriers
    └── confirm_dispatch.rb      # Confirma despacho + obtiene tracking
```

Un PORO = un caso de uso. El nombre del archivo es el verbo + sustantivo del caso de uso.

### Jobs

Los jobs se organizan por dominio:

```
app/jobs/
├── application_job.rb
├── catalog/
│   └── sync_stock_to_channel_job.rb
├── orders/
│   └── process_webhook_event_job.rb
└── shipments/
    └── pull_tracking_status_job.rb
```

### Controllers, Serializers, Policies

No tienen subdirectorios — el nombre del archivo es suficiente:

```
app/controllers/api/v1/
├── users_controller.rb
├── products_controller.rb
├── orders_controller.rb
└── shipments_controller.rb

app/serializers/
├── user_serializer.rb
├── product_serializer.rb
└── order_serializer.rb

app/policies/
├── product_policy.rb
├── order_policy.rb
└── shipment_policy.rb
```

## 4. Reglas de dependencia entre dominios

```
catalog   →  integrations   ✅ (Outbound Sync usa el HTTP Adapter de integrations)
orders    →  catalog        ✅ (confirmar orden descuenta stock)
shipments →  orders         ✅ (un envío pertenece a una orden)
webhooks  →  orders         ✅ (los webhooks disparan procesamiento de órdenes)
webhooks  →  shipments      ✅ (los webhooks de couriers actualizan tracking)
```

Los dominios nunca importan hacia arriba en la jerarquía de dependencia. Si dos dominios necesitan lógica compartida que no pertenece a ninguno, esa lógica va en `app/poros/shared/` o en el model directamente.

## 5. Cómo agregar una nueva entidad a un dominio existente

Ejemplo: agregar `StockPerWarehouse` al dominio `catalog`.

1. **Migración**: `rails g migration CreateStockPerWarehouse`  
   Incluir `t.references :company, null: false, foreign_key: true`

2. **Model** (`app/models/stock_per_warehouse.rb`)  
   Validaciones y relaciones. Sin lógica de negocio.

3. **Policy** (`app/policies/stock_per_warehouse_policy.rb`)  
   Reglas de autorización: ¿quién puede ver y modificar el stock?

4. **Serializer** (`app/serializers/stock_per_warehouse_serializer.rb`)  
   Solo campos necesarios en la respuesta JSON.

5. **PORO(s)** (`app/poros/catalog/update_warehouse_stock.rb`)  
   Lógica de negocio: actualizar stock + disparar sync saliente.

6. **Controller** (`app/controllers/api/v1/stock_per_warehouses_controller.rb`)  
   Thin: autenticar, autorizar, delegar al PORO, serializar.

7. **Ruta** en `config/routes.rb`

8. **Specs**: `spec/models/`, `spec/requests/api/v1/`, `spec/policies/`, `spec/poros/catalog/`

## 6. Cuándo usar PORO vs llamar al modelo directamente

No toda operación necesita un PORO. El patrón se usa cuando la lógica supera lo que ActiveRecord puede manejar por sí solo — no como envoltorio obligatorio de cada operación CRUD.

### Crear un PORO cuando la operación:

- Involucra **más de un modelo** (ej: confirmar orden + descontar stock + registrar evento)
- Tiene **lógica condicional de negocio** no trivial (ej: confirmar solo si hay stock suficiente en el warehouse correcto)
- Llama a un **servicio externo** (ej: cotizar envío con courier, sincronizar producto a Mercado Libre)
- Coordina **efectos secundarios** (ej: crear envío + encolar job de tracking + notificar al canal)
- Es un **caso de uso nombrable** del dominio (el nombre es un verbo de negocio: `ConfirmOrder`, `ProcessWebhookOrder`)

### Llamar al modelo directamente desde el controller cuando:

- Es creación o actualización de un **único modelo** sin efectos secundarios
- ActiveRecord maneja toda la lógica mediante validaciones y callbacks simples
- No hay coordinación entre modelos, jobs ni servicios externos

### Ejemplo comparativo

```ruby
# ❌ PORO innecesario: solo persiste con params, sin lógica adicional
module Warehouses
  class CreateWarehouse < ApplicationPoro
    def call
      Warehouse.create!(@params.merge(company: @company))
    end
  end
end

# ✅ Llamada directa al modelo: correcto para CRUD simple
def create
  authorize Warehouse
  warehouse = Warehouse.create!(warehouse_params.merge(company: current_company))
  render json: WarehouseSerializer.render(warehouse), status: :created
end

# ✅ PORO justificado: coordina múltiples modelos con lógica de negocio real
module Orders
  class ConfirmOrder < ApplicationPoro
    def call
      ActiveRecord::Base.transaction do
        @order.confirm!
        @order.items.each { |item| item.product.decrement_stock!(item.quantity) }
        Shipments::ScheduleDispatch.new(order: @order).call
      end
    end
  end
end
```

## 7. La "Regla de Dos" para POROs

Si un PORO se usa en un solo contexto, vive en su dominio.

En el momento en que un segundo dominio necesita la misma lógica, se mueve a `app/poros/shared/` o se extrae a un método del model si es lógica de datos pura.

## 8. Testing por dominio

Cada feature debe tener cobertura de:

| Tipo de spec        | Qué verifica                                     |
| ------------------- | ------------------------------------------------ |
| Model spec          | Validaciones, relaciones, scopes                 |
| Policy spec         | Que el usuario correcto puede/no puede           |
| PORO spec           | Lógica de negocio en aislamiento                 |
| Request spec        | El endpoint completo: auth, scope multi-tenant, respuesta JSON |

El request spec es el más importante: verifica que un usuario de un tenant no puede acceder a recursos de otro tenant, incluso manipulando IDs en la URL.

Ver guía completa de testing en [`docs/guidelines/testing.md`](testing.md).
