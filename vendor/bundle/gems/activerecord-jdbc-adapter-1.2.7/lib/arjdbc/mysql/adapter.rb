require 'bigdecimal'
require 'active_record/connection_adapters/abstract/schema_definitions'
require 'arjdbc/mysql/explain_support'

module ::ArJdbc
  module MySQL

    def self.extended(adapter)
      adapter.configure_connection
    end

    def configure_connection
      execute("SET SQL_AUTO_IS_NULL=0")
    end

    def self.column_selector
      [ /mysql/i, lambda { |_,column| column.extend(::ArJdbc::MySQL::Column) } ]
    end

    def self.jdbc_connection_class
      ::ActiveRecord::ConnectionAdapters::MySQLJdbcConnection
    end

    module Column
      
      def extract_default(default)
        if sql_type =~ /blob/i || type == :text
          if default.blank?
            return null ? nil : ''
          else
            raise ArgumentError, "#{type} columns cannot have a default value: #{default.inspect}"
          end
        elsif missing_default_forged_as_empty_string?(default)
          nil
        else
          super
        end
      end

      def has_default?
        return false if sql_type =~ /blob/i || type == :text #mysql forbids defaults on blob and text columns
        super
      end

      def simplified_type(field_type)
        case field_type
        when /tinyint\(1\)|bit/i then :boolean
        when /enum/i             then :string
        when /year/i             then :integer
        else
          super
        end
      end

      def extract_limit(sql_type)
        case sql_type
        when /blob|text/i
          case sql_type
          when /tiny/i
            255
          when /medium/i
            16777215
          when /long/i
            2147483647 # mysql only allows 2^31-1, not 2^32-1, somewhat inconsistently with the tiny/medium/normal cases
          else
            nil # we could return 65535 here, but we leave it undecorated by default
          end
        when /^enum/i;     255
        when /^bigint/i;    8
        when /^int/i;       4
        when /^mediumint/i; 3
        when /^smallint/i;  2
        when /^tinyint/i;   1
        when /^(bool|date|float|int|time)/i
          nil
        else
          super
        end
      end

      # MySQL misreports NOT NULL column default when none is given.
      # We can't detect this for columns which may have a legitimate ''
      # default (string) but we can for others (integer, datetime, boolean,
      # and the rest).
      #
      # Test whether the column has default '', is not null, and is not
      # a type allowing default ''.
      def missing_default_forged_as_empty_string?(default)
        type != :string && !null && default == ''
      end
      
    end

    ColumnExtensions = Column # :nodoc: backwards-compatibility
    
    def modify_types(types)
      types[:primary_key] = "int(11) DEFAULT NULL auto_increment PRIMARY KEY"
      types[:integer] = { :name => 'int', :limit => 4 }
      types[:decimal] = { :name => "decimal" }
      types[:timestamp] = { :name => "datetime" }
      types[:datetime][:limit] = nil
      types
    end

    ADAPTER_NAME = 'MySQL'.freeze
    
    def adapter_name #:nodoc:
      ADAPTER_NAME
    end

    def self.arel2_visitors(config)
      {
        'mysql' => ::Arel::Visitors::MySQL,
        'mysql2' => ::Arel::Visitors::MySQL,
        'jdbcmysql' => ::Arel::Visitors::MySQL
      }
    end

    def case_sensitive_equality_operator
      "= BINARY"
    end

    def case_sensitive_modifier(node)
      Arel::Nodes::Bin.new(node)
    end

    def limited_update_conditions(where_sql, quoted_table_name, quoted_primary_key)
      where_sql
    end

    # QUOTING ==================================================

    def quote(value, column = nil)
      return value.quoted_id if value.respond_to?(:quoted_id)
      return value.to_s if column && column.type == :primary_key
      
      if value.kind_of?(String) && column && column.type == :binary && column.class.respond_to?(:string_to_binary)
        "x'#{column.class.string_to_binary(value).unpack("H*")[0]}'"
      elsif value.kind_of?(BigDecimal)
        value.to_s("F")
      else
        super
      end
    end
    
    def quote_column_name(name) # :nodoc:
      "`#{name.to_s.gsub('`', '``')}`"
    end
    
    def quote_table_name(name) # :nodoc:
      quote_column_name(name).gsub('.', '`.`')
    end
    
    def supports_savepoints? # :nodoc:
      true
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

    def disable_referential_integrity # :nodoc:
      fk_checks = select_value("SELECT @@FOREIGN_KEY_CHECKS")
      begin
        update("SET FOREIGN_KEY_CHECKS = 0")
        yield
      ensure
        update("SET FOREIGN_KEY_CHECKS = #{fk_checks}")
      end
    end

    # DATABASE STATEMENTS ======================================
    
    def exec_insert(sql, name, binds)
      execute sql, name, binds
    end
    alias :exec_update :exec_insert
    alias :exec_delete :exec_insert
    
    # Make it public just like native MySQL adapter does.
    def update_sql(sql, name = nil) # :nodoc:
      super
    end
    
    # SCHEMA STATEMENTS ========================================
    
    def structure_dump #:nodoc:
      if supports_views?
        sql = "SHOW FULL TABLES WHERE Table_type = 'BASE TABLE'"
      else
        sql = "SHOW TABLES"
      end

      select_all(sql).inject("") do |structure, table|
        table.delete('Table_type')

        hash = show_create_table(table.to_a.first.last)

        if(table = hash["Create Table"])
          structure += table + ";\n\n"
        elsif(view = hash["Create View"])
          structure += view + ";\n\n"
        end
      end
    end

    # based on:
    # https://github.com/rails/rails/blob/3-1-stable/activerecord/lib/active_record/connection_adapters/mysql_adapter.rb#L756
    # Required for passing rails column caching tests
    # Returns a table's primary key and belonging sequence.
    def pk_and_sequence_for(table) #:nodoc:
      keys = []
      result = execute("SHOW INDEX FROM #{quote_table_name(table)} WHERE Key_name = 'PRIMARY'", 'SCHEMA')
      result.each do |h|
        keys << h["Column_name"]
      end
      keys.length == 1 ? [keys.first, nil] : nil
    end

    # based on:
    # https://github.com/rails/rails/blob/3-1-stable/activerecord/lib/active_record/connection_adapters/mysql_adapter.rb#L647
    # Returns an array of indexes for the given table.
    def indexes(table_name, name = nil)#:nodoc:
      indexes = []
      current_index = nil
      result = execute("SHOW KEYS FROM #{quote_table_name(table_name)}", name)
      result.each do |row|
        key_name = row["Key_name"]
        if current_index != key_name
          next if key_name == "PRIMARY" # skip the primary key
          current_index = key_name
          indexes << ::ActiveRecord::ConnectionAdapters::IndexDefinition.new(
            row["Table"], key_name, row["Non_unique"] == 0, [], [])
        end

        indexes.last.columns << row["Column_name"]
        indexes.last.lengths << row["Sub_part"]
      end
      indexes
    end

    def jdbc_columns(table_name, name = nil)#:nodoc:
      sql = "SHOW FIELDS FROM #{quote_table_name(table_name)}"
      execute(sql, 'SCHEMA').map do |field|
        ::ActiveRecord::ConnectionAdapters::MysqlColumn.new(field["Field"], field["Default"], field["Type"], field["Null"] == "YES")
      end
    end

    # Returns just a table's primary key
    def primary_key(table)
      pk_and_sequence = pk_and_sequence_for(table)
      pk_and_sequence && pk_and_sequence.first
    end

    def recreate_database(name, options = {}) #:nodoc:
      drop_database(name)
      create_database(name, options)
    end

    def create_database(name, options = {}) #:nodoc:
      if options[:collation]
        execute "CREATE DATABASE `#{name}` DEFAULT CHARACTER SET `#{options[:charset] || 'utf8'}` COLLATE `#{options[:collation]}`"
      else
        execute "CREATE DATABASE `#{name}` DEFAULT CHARACTER SET `#{options[:charset] || 'utf8'}`"
      end
    end

    def drop_database(name) #:nodoc:
      execute "DROP DATABASE IF EXISTS `#{name}`"
    end

    def current_database
      select_one("SELECT DATABASE() as db")["db"]
    end

    def create_table(name, options = {}) #:nodoc:
      super(name, {:options => "ENGINE=InnoDB DEFAULT CHARSET=utf8"}.merge(options))
    end

    def rename_table(name, new_name)
      execute "RENAME TABLE #{quote_table_name(name)} TO #{quote_table_name(new_name)}"
    end

    def remove_index!(table_name, index_name) #:nodoc:
      # missing table_name quoting in AR-2.3
      execute "DROP INDEX #{quote_column_name(index_name)} ON #{quote_table_name(table_name)}"
    end
    
    def add_column(table_name, column_name, type, options = {})
      add_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ADD #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
      add_column_options!(add_column_sql, options)
      add_column_position!(add_column_sql, options)
      execute(add_column_sql)
    end

    def change_column_default(table_name, column_name, default) #:nodoc:
      column = column_for(table_name, column_name)
      change_column table_name, column_name, column.sql_type, :default => default
    end

    def change_column_null(table_name, column_name, null, default = nil)
      column = column_for(table_name, column_name)

      unless null || default.nil?
        execute("UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(column_name)}=#{quote(default)} WHERE #{quote_column_name(column_name)} IS NULL")
      end

      change_column table_name, column_name, column.sql_type, :null => null
    end

    def change_column(table_name, column_name, type, options = {}) #:nodoc:
      column = column_for(table_name, column_name)

      unless options_include_default?(options)
        options[:default] = column.default
      end

      unless options.has_key?(:null)
        options[:null] = column.null
      end

      change_column_sql = "ALTER TABLE #{quote_table_name(table_name)} CHANGE #{quote_column_name(column_name)} #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
      add_column_options!(change_column_sql, options)
      add_column_position!(change_column_sql, options)
      execute(change_column_sql)
    end

    def rename_column(table_name, column_name, new_column_name) #:nodoc:
      options = {}
      if column = columns(table_name).find { |c| c.name == column_name.to_s }
        options[:default] = column.default
        options[:null] = column.null
      else
        raise ActiveRecord::ActiveRecordError, "No such column: #{table_name}.#{column_name}"
      end
      current_type = select_one("SHOW COLUMNS FROM #{quote_table_name(table_name)} LIKE '#{column_name}'")["Type"]
      rename_column_sql = "ALTER TABLE #{quote_table_name(table_name)} CHANGE #{quote_column_name(column_name)} #{quote_column_name(new_column_name)} #{current_type}"
      add_column_options!(rename_column_sql, options)
      execute(rename_column_sql)
    end

    def add_limit_offset!(sql, options) #:nodoc:
      limit, offset = options[:limit], options[:offset]
      if limit && offset
        sql << " LIMIT #{offset.to_i}, #{sanitize_limit(limit)}"
      elsif limit
        sql << " LIMIT #{sanitize_limit(limit)}"
      elsif offset
        sql << " OFFSET #{offset.to_i}"
      end
      sql
    end

    # Taken from: https://github.com/gfmurphy/rails/blob/3-1-stable/activerecord/lib/active_record/connection_adapters/mysql_adapter.rb#L540
    #
    # In the simple case, MySQL allows us to place JOINs directly into the UPDATE
    # query. However, this does not allow for LIMIT, OFFSET and ORDER. To support
    # these, we must use a subquery. However, MySQL is too stupid to create a
    # temporary table for this automatically, so we have to give it some prompting
    # in the form of a subsubquery. Ugh!
    def join_to_update(update, select) #:nodoc:
      if select.limit || select.offset || select.orders.any?
        subsubselect = select.clone
        subsubselect.projections = [update.key]

        subselect = Arel::SelectManager.new(select.engine)
        subselect.project Arel.sql(update.key.name)
        subselect.from subsubselect.as('__active_record_temp')

        update.where update.key.in(subselect)
      else
        update.table select.source
        update.wheres = select.constraints
      end
    end

    def show_variable(var)
      res = execute("show variables like '#{var}'")
      result_row = res.detect {|row| row["Variable_name"] == var }
      result_row && result_row["Value"]
    end

    def charset
      show_variable("character_set_database")
    end

    def collation
      show_variable("collation_database")
    end

    def type_to_sql(type, limit = nil, precision = nil, scale = nil)
      return super unless type.to_s == 'integer'

      case limit
      when 1; 'tinyint'
      when 2; 'smallint'
      when 3; 'mediumint'
      when nil, 4, 11; 'int(11)'  # compatibility with MySQL default
      when 5..8; 'bigint'
      else raise(ActiveRecordError, "No integer type has byte size #{limit}")
      end
    end

    def add_column_position!(sql, options)
      if options[:first]
        sql << " FIRST"
      elsif options[:after]
        sql << " AFTER #{quote_column_name(options[:after])}"
      end
    end

    protected
    def quoted_columns_for_index(column_names, options = {})
      length = options[:length] if options.is_a?(Hash)

      case length
      when Hash
        column_names.map { |name| length[name] ? "#{quote_column_name(name)}(#{length[name]})" : quote_column_name(name) }
      when Fixnum
        column_names.map { |name| "#{quote_column_name(name)}(#{length})" }
      else
        column_names.map { |name| quote_column_name(name) }
      end
    end

    def translate_exception(exception, message)
      return super unless exception.respond_to?(:errno)

      case exception.errno
      when 1062
        ::ActiveRecord::RecordNotUnique.new(message, exception)
      when 1452
        ::ActiveRecord::InvalidForeignKey.new(message, exception)
      else
        super
      end
    end

    private
    def column_for(table_name, column_name)
      unless column = columns(table_name).find { |c| c.name == column_name.to_s }
        raise "No such column: #{table_name}.#{column_name}"
      end
      column
    end

    def show_create_table(table)
      select_one("SHOW CREATE TABLE #{quote_table_name(table)}")
    end

    def supports_views?
      false
    end
  end
end

module ActiveRecord
  module ConnectionAdapters
    # Remove any vestiges of core/Ruby MySQL adapter
    remove_const(:MysqlColumn) if const_defined?(:MysqlColumn)
    remove_const(:MysqlAdapter) if const_defined?(:MysqlAdapter)

    class MysqlColumn < JdbcColumn
      include ::ArJdbc::MySQL::Column

      def initialize(name, *args)
        if Hash === name
          super
        else
          super(nil, name, *args)
        end
      end

      def call_discovered_column_callbacks(*)
      end
    end

    class MysqlAdapter < JdbcAdapter
      include ::ArJdbc::MySQL
      include ::ArJdbc::MySQL::ExplainSupport

      def initialize(*args)
        super
        configure_connection
      end

      def jdbc_connection_class(spec)
        ::ArJdbc::MySQL.jdbc_connection_class
      end

      def jdbc_column_class
        MysqlColumn
      end
      alias_chained_method :columns, :query_cache, :jdbc_columns

      # some QUOTING caching :

      @@quoted_table_names = {}

      def quote_table_name(name)
        unless quoted = @@quoted_table_names[name]
          quoted = super
          @@quoted_table_names[name] = quoted.freeze
        end
        quoted
      end

      @@quoted_column_names = {}

      def quote_column_name(name)
        unless quoted = @@quoted_column_names[name]
          quoted = super
          @@quoted_column_names[name] = quoted.freeze
        end
        quoted
      end
      
    end
  end
end

# Don't need to load native mysql adapter
$LOADED_FEATURES << 'active_record/connection_adapters/mysql_adapter.rb'
$LOADED_FEATURES << 'active_record/connection_adapters/mysql2_adapter.rb'

module Mysql # :nodoc:
  remove_const(:Error) if const_defined?(:Error)
  class Error < ::ActiveRecord::JDBCError; end

  def self.client_version
    50400 # faked out for AR tests
  end
end
