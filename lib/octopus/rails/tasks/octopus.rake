task :use_standard_connection do
  ActiveRecord::Base.custom_octopus_connection = true
  ActiveRecord::Base.establish_connection
end
task :'db:create' => :use_standard_connection
task :'db:test:purge' => :use_standard_connection
