# frozen_string_literal: true

class Warehouse < ApplicationRecord
  include CompanyScoped

  belongs_to :company
  has_many :stocks, dependent: :destroy

  validates :name, presence: true
  validates :zip_code, presence: true
  validates :address, presence: true
end
