# frozen_string_literal: true

class AddClaimedAtToFailedEvents < ActiveRecord::Migration[8.1]
  def change
    # Momento en que un worker reclamó el evento. Si el worker muere antes de
    # persistir el resultado, el claim queda vencido y el barrido lo rescata.
    add_column :failed_events, :claimed_at, :datetime

    # Índice del rescate: eventos en processing con el claim vencido.
    add_index :failed_events, %i[status claimed_at]
  end
end
