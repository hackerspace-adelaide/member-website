class CreateMemberships < ActiveRecord::Migration
  def change
    create_table :memberships do |t|
      t.integer :user_id
      t.datetime :valid_from
      t.integer :duration

      t.timestamps
    end
  end
end
