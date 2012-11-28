require "set"

class Octopus::Proxy
  attr_accessor :current_model, :current_shard, :current_group, :block,
      :last_current_shard, :config

  def initialize(config = Octopus.config)
    initialize_shards(config)
    initialize_replication(config) if !config.nil? && config["replicated"]
  end

  def default_shard
    if current_model && current_model.default_shard
       current_model.default_shard
    else
      :master
    end
  end

  def initialize_shards(config, env = Octopus.rails_env())
    @shards = HashWithIndifferentAccess.new
    @groups = {}
    @adapters = Set.new
    @shards[:master] = ActiveRecord::Base.connection_pool_without_octopus()
    @config = ActiveRecord::Base.connection_pool_without_octopus.connection.instance_variable_get(:@config)

    @current_shard = default_shard

    if !config.nil? && config.has_key?("verify_connection")
      @verify_connection = config["verify_connection"]
    else
      @verify_connection = false
    end

    if !config.nil?
      @entire_sharded = config['entire_sharded']
      shards_config = config[env]
    end

    shards_config ||= []

    init_shards_config(shards_config)

  end

  def init_shards_config(shards_config)
    shards_config.each do |key, value|
      if value.has_key?("adapter")
        initialize_adapter(value['adapter'])
        @shards[key.to_sym] = connection_pool_for(value, "#{value['adapter']}_connection")
      else
        @groups[key.to_s] = []

        value.each do |k, v|
          raise "You have duplicated shard names!" if @shards.has_key?(k.to_sym)

          initialize_adapter(v['adapter'])
          config_with_octopus_shard = v.merge(:octopus_shard => k)

          @shards[k.to_sym] = connection_pool_for(config_with_octopus_shard, "#{v['adapter']}_connection")
          @groups[key.to_s] << k.to_sym
        end
      end
    end
  end

  def dump_shards_schema
    (@shards.keys - ["master"]).each do |shard_name|
      require 'active_record/schema_dumper'
      File.open("#{Rails.root}/db/schema_#{shard_name}.rb", "w") do |file|
        self.current_shard = shard_name
        ActiveRecord::SchemaDumper.dump(select_connection, file)
      end
    end
  end

  def load_shards_schema
    (@shards.keys - ["master"]).each do |shard_name|
      file = "#{Rails.root}/db/schema_#{shard_name}.rb"
      if File.exists?(file)
        load(file)
      else
        abort %{#{file} doesn't exist yet. Run "rake db:migrate" to create it then try again. If you do not intend to use a database, you should instead alter #{Rails.root}/config/boot.rb to limit the frameworks that will be loaded}
      end
    end
  end

  def dump_shards_structure
    (@shards.keys - ["master"]).each do |shard_name|
      database_name = Octopus.config[Rails.env]["shards"][shard_name]['database']
      `pg_dump -i -U "carolnichols" -s -x -O -f db/#{Rails.env}_#{shard_name}_structure.sql #{database_name}`
    end
  end

  def test_shards_purge
    initialize_shards(Octopus.config, "test")


    (@shards.keys - ["master"]).each do |shard_name|

      config = Octopus.config["test"]["shards"][shard_name]

      ActiveRecord::Base.clear_active_connections!
      ActiveRecord::Base.establish_connection(config.merge('database' => 'postgres', 'schema_search_path' => 'public'))
      ActiveRecord::Base.connection.drop_database config['database']

      ActiveRecord::Base.establish_connection(config.merge('database' => 'postgres', 'schema_search_path' => 'public'))
      ActiveRecord::Base.connection.create_database(config['database'], config.merge('encoding' => 'utf8'))
      ActiveRecord::Base.establish_connection(config)
    end

  end

  def test_shards_load_structure
    initialize_shards(Octopus.config, "test")
    (@shards.keys - ["master"]).each do |shard_name|
      filename = File.join(Rails.root, "db", "#{Rails.env}_#{shard_name}_structure.sql")

      database = Octopus.config["test"]["shards"][shard_name]['database']

      `psql -f "#{filename}" #{database}`
    end
  end


  def initialize_replication(config)
    @replicated = true
    if config.has_key?("fully_replicated")
      @fully_replicated = config["fully_replicated"]
    else
      @fully_replicated = true
    end
    @slaves_list = @shards.keys.map {|sym| sym.to_s}.sort
    @slaves_list.delete('master')
    @slave_index = 0
  end

  def current_shard=(shard_symbol)
    if shard_symbol.is_a?(Array)
      shard_symbol.each {|symbol| raise "Nonexistent Shard Name: #{symbol}" if @shards[symbol].nil? }
    else
      raise "Nonexistent Shard Name: #{shard_symbol}" if @shards[shard_symbol].nil?
    end

    @current_shard = shard_symbol
  end

  def current_group=(group_symbol)
    # TODO: Error message should include all groups if given more than one bad name.
    [group_symbol].flatten.each do |group|
      raise "Nonexistent Group Name: #{group}" unless has_group?(group)
    end

    @current_group = group_symbol
  end

  def current_model=(model)
    @current_model = model.is_a?(ActiveRecord::Base) ? model.class : model
  end

  # Public: Whether or not a group exists with the given name converted to a
  # string.
  #
  # Returns a boolean.
  def has_group?(group)
    @groups.has_key?(group.to_s)
  end

  # Public: Retrieves the defined shards for a given group.
  #
  # Returns an array of shard names as symbols or nil if the group is not
  # defined.
  def shards_for_group(group)
    @groups.fetch(group.to_s, nil)
  end

  def select_connection
    @shards[shard_name].verify_active_connections! if @verify_connection
    # Rails 3.1 sets automatic_reconnect to false when it removes
    # connection pool.  Octopus can potentially retain a reference to a closed
    # connection pool.  Previously, that would work since the pool would just
    # reconnect, but in Rails 3.1 the flag prevents this.
    if Octopus.rails31?
      if !@shards[shard_name].automatic_reconnect
        @shards[shard_name].automatic_reconnect = true
      end
    end
    @shards[shard_name].connection()
  end

  def shard_name
    current_shard.is_a?(Array) ? current_shard.first : current_shard
  end

  def should_clean_table_name?
    @adapters.size > 1
  end

  def run_queries_on_shard(shard, &block)
    older_shard = self.current_shard
    last_block = self.block

    begin
      self.block = true
      self.current_shard = shard
      yield
    ensure
      self.block = last_block || false
      self.current_shard = older_shard
    end
  end

  def send_queries_to_multiple_shards(shards, &block)
    shards.each do |shard|
      self.run_queries_on_shard(shard, &block)
    end
  end

  def clean_proxy()
    @current_shard = default_shard
    @current_group = nil
    @block = false
  end

  def check_schema_migrations(shard)
    if !OctopusModel.using(shard).connection.table_exists?(ActiveRecord::Migrator.schema_migrations_table_name())
      OctopusModel.using(shard).connection.initialize_schema_migrations_table
    end
  end

  def transaction(options = {}, &block)
    if @replicated && (current_model.replicated || @fully_replicated)
      self.run_queries_on_shard(default_shard) do
        select_connection.transaction(options, &block)
      end
    elsif current_model.default_shard
      self.run_queries_on_shard(current_model.default_shard) do
        select_connection.transaction(options, &block)
      end
    else
      select_connection.transaction(options, &block)
    end
  end

  def method_missing(method, *args, &block)
    if method == :current_database
      puts "yep"
    end
    if should_clean_connection?(method)
      if method == :current_database
        puts "should clean conn"
      end
      conn = select_connection()
      self.last_current_shard = self.current_shard
      clean_proxy()
      conn.send(method, *args, &block)
    elsif should_send_queries_to_replicated_databases?(method)
      if method == :current_database
        puts "should send to repl"
      end
      send_queries_to_selected_slave(method, *args, &block)
    else
      if method == :current_database
        puts "general case"
        puts "current_model = #{current_model.inspect}"
        puts "current_model.default_shard = #{current_model.default_shard}"
        puts "default shard = #{default_shard}"
        puts "shard_name = #{shard_name}"

      end
      select_connection().send(method, *args, &block)
    end
  end

  def respond_to?(method, include_private = false)
    super || select_connection.respond_to?(method, include_private)
  end

  def connection_pool
    return @shards[current_shard]
  end

  protected
  def connection_pool_for(adapter, config)
    ActiveRecord::ConnectionAdapters::ConnectionPool.new(ActiveRecord::Base::ConnectionSpecification.new(adapter.dup, config))
  end

  def initialize_adapter(adapter)
    @adapters << adapter
    begin
      require "active_record/connection_adapters/#{adapter}_adapter"
    rescue LoadError
      raise "Please install the #{adapter} adapter: `gem install activerecord-#{adapter}-adapter` (#{$!})"
    end
  end

  def should_clean_connection?(method)
    method.to_s =~ /insert|select|execute/ && !@replicated && !self.block
  end

  def should_send_queries_to_replicated_databases?(method)
    @replicated && method.to_s =~ /select/ && !@block
  end

  def send_queries_to_selected_slave(method, *args, &block)
    old_shard = self.current_shard

    begin
      if current_model.replicated || @fully_replicated
        self.current_shard = @slaves_list[@slave_index = (@slave_index + 1) % @slaves_list.length]
      else
        self.current_shard = default_shard
      end

      select_connection.send(method, *args, &block)
    ensure
      self.current_shard = old_shard
    end
  end
end
