# frozen_string_literal: true

class Product < ApplicationRecord
  include CompanyScoped

  belongs_to :company
  has_many :stocks, dependent: :destroy
  has_many :product_mappings, dependent: :destroy

  validates :sku, presence: true, uniqueness: { scope: :company_id }
  validates :name, presence: true
  validates :weight, numericality: { greater_than_or_equal_to: 0 }

  scope :with_total_stock, lambda {
    left_joins(:stocks)
      .group(:id)
      .select('products.*', 'COALESCE(SUM(stocks.quantity), 0) AS total_stock')
  }

  # Retorna el stock total consolidado usando SUM en la DB.
  # Para colecciones usar el scope with_total_stock para evitar N+1.
  def total_stock
    stocks.sum(:quantity)
  end
end
