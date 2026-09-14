# frozen_string_literal: true

class Company < ApplicationRecord
  # El slug es el subdominio con el que el tenant se presenta (`norte.<dominio>`),
  # así que se restringe al alfabeto de una etiqueta de DNS.
  SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  has_many :users, dependent: :destroy
  has_many :warehouses, dependent: :destroy
  has_many :company_integrations, dependent: :destroy
  has_many :products, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :shipments, dependent: :destroy
  has_many :failed_events, dependent: :destroy

  # El slug es obligatorio, pero pedirlo explícitamente en cada alta sería ruido:
  # se deriva del nombre cuando no viene. Los tenants que sí importan (los de
  # seeds) declaran el suyo y ese gana.
  before_validation :assign_default_slug, on: :create

  validates :name, presence: true
  validates :tax_id, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT }

  scope :active, -> { where(is_active: true) }

  # Una empresa dada de baja se trata como inexistente: no se puede pedir su
  # config pública ni loguearse contra ella.
  def self.find_active_by_slug(slug)
    normalized = slug.to_s.strip.downcase
    return nil if normalized.blank?

    active.find_by(slug: normalized)
  end

  private

  def assign_default_slug
    return if slug.present?

    base = name.to_s.parameterize
    # Sin nombre no hay slug derivable; la validación de `name` ya rechaza el
    # registro, no hace falta inventar un valor acá.
    return if base.blank?

    self.slug = available_slug(base)
  end

  def available_slug(base)
    candidate = base
    suffix = 2

    while self.class.exists?(slug: candidate)
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end

    candidate
  end
end
