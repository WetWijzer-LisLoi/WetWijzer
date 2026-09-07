class AddCustomerTypeToSubscriptions < ActiveRecord::Migration[8.1]
  def change
    add_column :subscriptions, :customer_type, :string
  end
end
