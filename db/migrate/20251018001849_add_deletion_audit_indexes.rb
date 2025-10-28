class AddDeletionAuditIndexes < ActiveRecord::Migration[8.0]
  def change
    # Indexes for querying deletion audit logs
    add_index :deletion_audit, :table_name, name: 'idx_deletion_audit_table'
    add_index :deletion_audit, :ts, name: 'idx_deletion_audit_ts'
  end
end
