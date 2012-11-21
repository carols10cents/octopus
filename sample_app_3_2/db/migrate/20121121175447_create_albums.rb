class CreateAlbums < ActiveRecord::Migration
  using(:album)

  def change
    create_table :albums do |t|
      t.string :title
      t.string :artist

      t.timestamps
    end
  end
end
