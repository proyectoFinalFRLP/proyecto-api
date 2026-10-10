# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Reports::Window do
  # Jueves 02/10/2026 a las 01:30 en Argentina, que en UTC ya es 04:30.
  let(:now) { Time.zone.parse('2026-10-02 04:30:00 UTC') }

  def window(period = '7d') = described_class.new(period: period, now: now)

  it 'starts at the beginning of the first of the last N days, in Argentina' do
    expect(window.from.iso8601).to eq('2026-09-26T00:00:00-03:00')
  end

  it 'ends now' do
    expect(window.to).to eq(now)
  end

  it 'defaults to the last seven days' do
    expect(described_class.new(period: nil, now: now).days).to eq(7)
  end

  it 'refuses a period it does not know' do
    expect { window('1y') }.to raise_error(described_class::UnknownPeriodError, /7d, 30d, 90d/)
  end

  it 'puts the previous window right before, with the same length' do
    expect(window.previous_range).to eq((window.from - 7.days)...window.from)
  end

  it 'lists every day of the window, empty ones included' do
    expect(window.buckets.map(&:iso8601)).to eq(
      %w[2026-09-26 2026-09-27 2026-09-28 2026-09-29 2026-09-30 2026-10-01 2026-10-02]
    )
  end

  # 21:30 en Argentina del 01/10 ya es 02/10 en UTC: el corte va por la hora local.
  it 'buckets an instant by its day in Argentina, not in UTC' do
    expect(window.bucket_for(Time.zone.parse('2026-10-02 00:30:00 UTC')).iso8601).to eq('2026-10-01')
  end

  context 'with ninety days' do
    it 'groups the curve by week, starting on Monday', :aggregate_failures do
      buckets = window('90d').buckets

      expect(window('90d').granularity).to eq('week')
      expect(buckets).to all(satisfy(&:monday?))
      expect(buckets.last.iso8601).to eq('2026-09-28')
    end
  end
end
