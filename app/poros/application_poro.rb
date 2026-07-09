# frozen_string_literal: true

class ApplicationPoro
  def self.call(...)
    new(...).call
  end
end
