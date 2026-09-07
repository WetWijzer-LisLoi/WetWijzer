class AddWeeklyFreeCreditsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :weekly_free_credits_balance, :integer
    add_column :users, :weekly_credits_refilled_at, :datetime
  end
end
