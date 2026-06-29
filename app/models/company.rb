# frozen_string_literal: true

class Company < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :warehouses, dependent: :destroy

  validates :name, presence: true
  validates :tax_id, presence: true, uniqueness: true
end
