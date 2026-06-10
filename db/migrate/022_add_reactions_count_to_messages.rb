class AddReactionsCountToMessages < ActiveRecord::Migration[6.0]
  # Aggregate Telegram reaction count per message. Updated by BotDispatcher
  # from message_reaction (per-user delta, best-effort) and
  # message_reaction_count (authoritative aggregate, self-healing) updates.
  # Feeds Message.top_reacted — Quote-of-the-day and Wrapped "funniest".
  #
  # Additive column, default 0, no backfill. Intentionally no down that
  # drops the column: SQLite needs a full table rebuild for column-drop and
  # migrations auto-run on every container start — rollback is "leave it".
  def change
    add_column :messages, :reactions_count, :integer, default: 0, null: false
  end
end
