# frozen_string_literal: true

class Warehouse < ApplicationRecord
  belongs_to :company

  validates :name, presence: true
  validates :zip_code, presence: true
  validates :address, presence: true
end
