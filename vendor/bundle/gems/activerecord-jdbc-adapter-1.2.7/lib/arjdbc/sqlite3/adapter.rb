require 'arjdbc/jdbc/missing_functionality_helper'
require 'arjdbc/sqlite3/explain_support'

module ::ArJdbc
  module SQLite3
    def self.column_selector
      [ /sqlite/i, lambda { |cfg,col| col.extend(::ArJdbc::SQLite3::Column) } ]
    end

    def self.jdbc_connection_class
      ::ActiveRecord::ConnectionAdapters::SQLite3JdbcConnection
    end
    
    module Column
      def init_column(name, default, *args)
        @default = nil if default =~ /NULL/
      end

      def type_cast(value)
        return nil if value.nil?
        case type
        when :string then value
        when :primary_key then defined?(value.to_i) ? value.to_i : (value ? 1 : 0)
        when :float    then value.to_f
        when :decimal  then self.class.value_to_decimal(value)
        when :boolean  then self.class.value_to_boolean(value)
        else super
        end
      end
      
      private
      def simplified_type(field_type)
        case field_type
        when /boolean/i       then :boolean
        when /text/i          then :text
        when /varchar/i       then :string
        when /int/i           then :integer
        when /float/i         then :float
        when /real|decimal/i  then @scale == 0 ? :integer : :decimal
        when /datetime/i      then :datetime
        when /date/i          then :date
        when /time/i          then :time
        when /blob/i          then :binary
        else super
        end
      end

      def extract_limit(sql_type)
        return nil if sql_type =~ /^(real)\(\d+/i
        super
      end

      def extract_precision(sql_type)
        case sql_type
          when /^(real)\((\d+)(,\d+)?\)/i then $2.to_i
          else super
        end
      end

      def extract_scale(sql_type)
        case sql_type
          when /^(real)\((\d+)\)/i then 0
          when /^(real)\((\d+)(,(\d+))\)/i then $4.to_i
          else super
        end
      end

      # Post process default value from JDBC into a Rails-friendly format (columns{-internal})
      def default_value(value)
        # jdbc returns column default strings with actual single quotes around the value.
        return $1 if value =~ /^'(.*)'$/

        value
      end
    end

    def adapter_name #:nodoc:
      'SQLite'
    end

    def self.arel2_visitors(config)
      {
        'sqlite3' => ::Arel::Visitors::SQLite,
        'jdbcsqlite3' => ::Arel::Visitors::SQLite
      }
    end

    def supports_ddl_transactions? # :nodoc:
      true # sqlite_version >= '2.0.0'
    end
    
    def supports_savepoints? # :nodoc:
      sqlite_version >= '3.6.8'
    end
    
    def supports_add_column? # :nodoc:
      sqlite_version >= '3.1.6'
    end

    def supports_count_distinct? # :nodoc:
      sqlite_version >= '3.2.6'
    end

    def supports_autoincrement? # :nodoc:
      sqlite_version >= '3.1.0'
    end

    def supports_index_sort_order? # :nodoc:
      sqlite_version >= '3.3.0'
    end
    
    def sqlite_version
      @sqlite_version ||= select_value('select sqlite_version(*)')
    end
    private :sqlite_version

    def modify_types(types)
      super(types)
      types[:primary_key] = "integer primary key autoincrement not null"
      types[:string] = { :name => "varchar", :limit => 255 }
      types[:text] = { :name => "text" }
      types[:float] = { :name => "float" }
      types[:decimal] = { :name => "decimal" }
      types[:datetime] = { :name => "datetime" }
      types[:timestamp] = { :name => "datetime" }
      types[:time] = { :name => "time" }
      types[:date] = { :name => "date" }
      types[:boolean] = { :name => "boolean" }
      types[:binary] = { :name => "blob" }
      types
    end
    
    def quote(value, column = nil)
      if value.kind_of?(String)
        column_type = column && column.type
        if column_type == :binary && column.class.respond_to?(:string_to_binary)
          "x'#{column.class.string_to_binary(value).unpack("H*")[0]}'"
        else
          super
        end
      else
        super
      end
    end

    def quote_column_name(name) # :nodoc:
      %Q("#{name.to_s.gsub('"', '""')}") # "' kludge for emacs font-lock
    end

    # Quote date/time values for use in SQL input. Includes microseconds
    # if the value is a Time responding to usec.
    def quoted_date(value) # :nodoc:
      if value.respond_to?(:usec)
        "#{super}.#{sprintf("%06d", value.usec)}"
      else
        super
      end
    end
    
    # NOTE: we have an extra binds argument at the end due 2.3 support.
    def insert_sql(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil, binds = []) # :nodoc:
      execute(sql, name, binds)
      id_value || last_insert_id
    end
    
    def tables(name = nil) #:nodoc:
      sql = <<-SQL
        SELECT name
        FROM sqlite_master
        WHERE type = 'table' AND NOT name = 'sqlite_sequence'
      SQL

      select_rows(sql, name).map do |row|
        row[0]
      end
    end

    def indexes(table_name, name = nil)
      result = select_rows("SELECT name, sql FROM sqlite_master WHERE tbl_name = #{quote_table_name(table_name)} AND type = 'index'", name)

      result.collect do |row|
        name = row[0]
        index_sql = row[1]
        unique = (index_sql =~ /unique/i)
        cols = index_sql.match(/\((.*)\)/)[1].gsub(/,/,' ').split.map do |c|
          match = /^"(.+)"$/.match(c); match ? match[1] : c
        end
        ::ActiveRecord::ConnectionAdapters::IndexDefinition.new(table_name, name, unique, cols)
      end
    end

    def create_savepoint
      execute("SAVEPOINT #{current_savepoint_name}")
    end

    def rollback_to_savepoint
      execute("ROLLBACK TO SAVEPOINT #{current_savepoint_name}")
    end

    def release_savepoint
      execute("RELEASE SAVEPOINT #{current_savepoint_name}")
    end
    
    def recreate_database(name, options = {})
      tables.each{ |table| drop_table(table) }
    end

    def select(sql, name = nil, binds = [])
      execute(sql, name, binds).map do |row|
        record = {}
        row.each_key do |key|
          if key.is_a?(String)
            record[key.sub(/^"?\w+"?\./, '')] = row[key]
          end
        end
        record
      end
    end

    def table_structure(table_name)
      sql = "PRAGMA table_info(#{quote_table_name(table_name)})"
      log(sql, 'SCHEMA') { @connection.execute_query(sql) }
    rescue ActiveRecord::JDBCError => error
      e = ActiveRecord::StatementInvalid.new("Could not find table '#{table_name}'")
      e.set_backtrace error.backtrace
      raise e
    end

    def jdbc_columns(table_name, name = nil) #:nodoc:
      table_structure(table_name).map do |field|
        ::ActiveRecord::ConnectionAdapters::SQLite3Column.new(
          @config, field['name'], field['dflt_value'], field['type'], field['notnull'] == 0
        )
      end
    end

    def primary_key(table_name) #:nodoc:
      column = table_structure(table_name).find { |field|
        field['pk'].to_i == 1
      }
      column && column['name']
    end

    def remove_index!(table_name, index_name) #:nodoc:
      execute "DROP INDEX #{quote_column_name(index_name)}"
    end

    def rename_table(name, new_name)
      execute "ALTER TABLE #{quote_table_name(name)} RENAME TO #{quote_table_name(new_name)}"
    end

    # See: http://www.sqlite.org/lang_altertable.html
    # SQLite has an additional restriction on the ALTER TABLE statement
    def valid_alter_table_options( type, options)
      type.to_sym != :primary_key
    end

    def add_column(table_name, column_name, type, options = {}) #:nodoc:
      if supports_add_column? && valid_alter_table_options( type, options )
        super(table_name, column_name, type, options)
      else
        alter_table(table_name) do |definition|
          definition.column(column_name, type, options)
        end
      end
    end

    def remove_column(table_name, *column_names) #:nodoc:
      raise ArgumentError.new("You must specify at least one column name.  Example: remove_column(:people, :first_name)") if column_names.empty?
      column_names.flatten.each do |column_name|
        alter_table(table_name) do |definition|
          definition.columns.delete(definition[column_name])
        end
      end
    end
    alias :remove_columns :remove_column

    def change_column_default(table_name, column_name, default) #:nodoc:
      alter_table(table_name) do |definition|
        definition[column_name].default = default
      end
    end

    def change_column_null(table_name, column_name, null, default = nil)
      unless null || default.nil?
        execute("UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(column_name)}=#{quote(default)} WHERE #{quote_column_name(column_name)} IS NULL")
      end
      alter_table(table_name) do |definition|
        definition[column_name].null = null
      end
    end

    def change_column(table_name, column_name, type, options = {}) #:nodoc:
      alter_table(table_name) do |definition|
        include_default = options_include_default?(options)
        definition[column_name].instance_eval do
          self.type    = type
          self.limit   = options[:limit] if options.include?(:limit)
          self.default = options[:default] if include_default
          self.null    = options[:null] if options.include?(:null)
          self.precision = options[:precision] if options.include?(:precision)
          self.scale   = options[:scale] if options.include?(:scale)
        end
      end
    end

    def rename_column(table_name, column_name, new_column_name) #:nodoc:
      unless columns(table_name).detect{|c| c.name == column_name.to_s }
        raise ActiveRecord::ActiveRecordError, "Missing column #{table_name}.#{column_name}"
      end
      alter_table(table_name, :rename => {column_name.to_s => new_column_name.to_s})
    end

     # SELECT ... FOR UPDATE is redundant since the table is locked.
    def add_lock!(sql, options) #:nodoc:
      sql
    end

    def empty_insert_statement_value
      "VALUES(NULL)"
    end

    protected
    
    include ArJdbc::MissingFunctionalityHelper

    def translate_exception(exception, message)
      case exception.message
      when /column(s)? .* (is|are) not unique/
        ActiveRecord::RecordNotUnique.new(message, exception)
      else
        super
      end
    end

    def last_insert_id
      @connection.last_insert_row_id
    end
    
    def last_inserted_id(result)
      last_insert_id
    end
    
    private
    
    def _execute(sql, name = nil)
      result = super
      self.class.insert?(sql) ? last_insert_id : result
    end
    
  end
end

module ActiveRecord::ConnectionAdapters
  remove_const(:SQLite3Adapter) if const_defined?(:SQLite3Adapter)
  remove_const(:SQLiteAdapter) if const_defined?(:SQLiteAdapter)

  class SQLite3Column < JdbcColumn
    include ArJdbc::SQLite3::Column

    def initialize(name, *args)
      if Hash === name
        super
      else
        super(nil, name, *args)
      end
    end

    def call_discovered_column_callbacks(*)
    end

    def self.string_to_binary(value)
      value
    end

    def self.binary_to_string(value)
      if value.respond_to?(:encoding) && value.encoding != Encoding::ASCII_8BIT
        value = value.force_encoding(Encoding::ASCII_8BIT)
      end
      value
    end
  end

  class SQLite3Adapter < JdbcAdapter
    include ArJdbc::SQLite3
    include ArJdbc::SQLite3::ExplainSupport

    def jdbc_connection_class(spec)
      ::ArJdbc::SQLite3.jdbc_connection_class
    end

    def jdbc_column_class
      ActiveRecord::ConnectionAdapters::SQLite3Column
    end

    alias_chained_method :columns, :query_cache, :jdbc_columns
    
  end

  SQLiteAdapter = SQLite3Adapter
end

# Don't need to load native sqlite3 adapter
$LOADED_FEATURES << 'active_record/connection_adapters/sqlite_adapter.rb'
$LOADED_FEATURES << 'active_record/connection_adapters/sqlite3_adapter.rb'

# Fake out sqlite3/version driver for AR tests
$LOADED_FEATURES << 'sqlite3/version.rb'
module SQLite3
  module Version
    VERSION = '1.2.6' # query_cache_test.rb requires SQLite3::Version::VERSION > '1.2.5'
  end
end