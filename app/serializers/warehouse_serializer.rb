# frozen_string_literal: true

class WarehouseSerializer < ApplicationSerializer
  identifier :id
  fields :name, :zip_code, :address
end
