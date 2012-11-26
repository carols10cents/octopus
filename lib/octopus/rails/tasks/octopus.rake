# schema:dump -- dump all shards too
task :dump_shards_schema do
  if ActiveRecord::Base.connection.is_a?(Octopus::Proxy)
    ActiveRecord::Base.connection.dump_shards_schema
  end
end
task :'db:schema:dump' => :dump_shards_schema

# structure:dump -- dump all shards too
task :dump_shards_structure do
  if ActiveRecord::Base.connection.is_a?(Octopus::Proxy)
    ActiveRecord::Base.connection.dump_shards_structure
  end
end
task :'db:structure:dump' => :dump_shards_structure

# Not sure if this is needed; taken from
# https://github.com/tchandy/octopus/issues/31
# This might actually *prevent* loading/dumping from shards
task :use_standard_connection do
  ActiveRecord::Base.custom_octopus_connection = true
  ActiveRecord::Base.establish_connection
end
task :'db:create' => :use_standard_connection
# task :'db:test:purge' =>

# Not sure if this is needed; taken from
# https://github.com/tchandy/octopus/issues/31
# This might actually *prevent* loading/dumping from shards
task :reconnect_octopus do
  if !ActiveRecord::Base.connection.is_a?(Octopus::Proxy)
    ActiveRecord::Base.custom_octopus_connection = false
    ActiveRecord::Base.connection.initialize_shards(Octopus.config)
  end
end

# schema:load -- load all shards too
task :load_shards_schema => :reconnect_octopus do
  if ActiveRecord::Base.connection.is_a?(Octopus::Proxy)
    ActiveRecord::Base.connection.load_shards_schema
  end
end
task :'db:schema:load' => :load_shards_schema

# db:test:clone_structure -- load all shards too
task :test_shards_load_structure => [:environment, :reconnect_octopus] do
  if ActiveRecord::Base.connection.is_a?(Octopus::Proxy)
    ActiveRecord::Base.connection.test_shards_load_structure
  end
end
task :'db:test:load_structure' => :test_shards_load_structure

task :test_shards_purge => [:environment, :reconnect_octopus] do
  if ActiveRecord::Base.connection.is_a?(Octopus::Proxy)
    ActiveRecord::Base.connection.test_shards_purge
  end
end
task :'db:test:purge' => [:test_shards_purge, :use_standard_connection]