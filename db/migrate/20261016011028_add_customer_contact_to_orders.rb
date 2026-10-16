class AddCustomerContactToOrders < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :customer_email, :string
    add_column :orders, :customer_phone, :string
  end
end
