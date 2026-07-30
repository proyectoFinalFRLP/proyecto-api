# frozen_string_literal: true

class Product < ApplicationRecord
  include CompanyScoped

  belongs_to :company
  has_many :stocks, dependent: :destroy
  has_many :product_mappings, dependent: :destroy

  validates :sku, presence: true, uniqueness: { scope: :company_id }
  validates :name, presence: true
  validates :weight, numericality: { greater_than_or_equal_to: 0 }
end
