#====================================================
#
#    Copyright 2008-2010 iAnywhere Solutions, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#                                                                               
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#
# See the License for the specific language governing permissions and
# limitations under the License.
#
# While not a requirement of the license, if you do modify this file, we
# would appreciate hearing about it.   Please email sqlany_interfaces@sybase.com
#
#
#====================================================

require 'active_record/connection_adapters/abstract_adapter'
require 'arel/visitors/sqlanywhere.rb'

# Singleton class to hold a valid instance of the SQLAnywhereInterface across all connections
class SA
  include Singleton
  def api
    if @pid != Process.pid
      reset_api
    end
    @api
  end

  def initialize
    @api = nil
    @pid = nil
    require 'sqlanywhere' unless defined? SQLAnywhere
    reset_api
  end

  private
  def reset_api
    @pid = Process.pid
    if @api != nil
      @api.sqlany_fini()
      SQLAnywhere::API.sqlany_finalize_interface( @api )
    end
    @api = SQLAnywhere::SQLAnywhereInterface.new()
    raise LoadError, "Could not load SQLAnywhere DBCAPI library" if SQLAnywhere::API.sqlany_initialize_interface(@api) == 0 
    raise LoadError, "Could not initialize SQLAnywhere DBCAPI library" if @api.sqlany_init() == 0 
  end
end

module ActiveRecord
  class Base
    DEFAULT_CONFIG = { :username => 'dba', :password => 'sql' }
    # Main connection function to SQL Anywhere
    # Connection Adapter takes four parameters:
    # * :database (required, no default). Corresponds to "DatabaseName=" in connection string
    # * :server (optional, defaults to :databse). Corresponds to "ServerName=" in connection string 
    # * :username (optional, default to 'dba')
    # * :password (optional, deafult to 'sql')
    # * :encoding (optional, defaults to charset of OS)
    # * :commlinks (optional). Corresponds to "CommLinks=" in connection string
    # * :connection_name (optional). Corresponds to "ConnectionName=" in connection string
    
    def self.sqlanywhere_connection(config)
      
      if config[:connection_string]
        connection_string = config[:connection_string]
      else
        config = DEFAULT_CONFIG.merge(config)

        raise ArgumentError, "No database name was given. Please add a :database option." unless config.has_key?(:database)

        connection_string = "ServerName=#{(config[:server] || config[:database])};DatabaseName=#{config[:database]};UserID=#{config[:username]};Password=#{config[:password]};"
        connection_string += "CommLinks=#{config[:commlinks]};" unless config[:commlinks].nil?
        connection_string += "ConnectionName=#{config[:connection_name]};" unless config[:connection_name].nil?
        connection_string += "CharSet=#{config[:encoding]};" unless config[:encoding].nil?      
        connection_string += "Idle=0" # Prevent the server from disconnecting us if we're idle for >240mins (by default)
      end

      db = SA.instance.api.sqlany_new_connection()
      
      ConnectionAdapters::SQLAnywhereAdapter.new(db, logger, connection_string)
    end
  end

  module ConnectionAdapters
    class SQLAnywhereException < StandardError
      attr_reader :errno
      attr_reader :sql

      def initialize(message, errno, sql)
        super(message)
        @errno = errno
        @sql = sql
      end
    end
  
    class SQLAnywhereColumn < Column
      private
        # Overridden to handle SQL Anywhere integer, varchar, binary, and timestamp types
        def simplified_type(field_type)
          return :boolean if field_type =~ /tinyint/i
          return :boolean if field_type =~ /bit/i
          return :text if field_type =~ /long varchar/i
          return :string if field_type =~ /varchar/i
          return :binary if field_type =~ /long binary/i
          return :datetime if field_type =~ /timestamp/i
          return :integer if field_type =~ /smallint|bigint/i
          return :text if field_type =~ /xml/i
          return :integer if field_type =~ /uniqueidentifier/i
          super
        end

        def extract_limit(sql_type)
          case sql_type
            when /^tinyint/i
              1
            when /^smallint/i 
              2
            when /^integer/i  
              4            
            when /^bigint/i   
              8  
            else super
          end
        end

      protected
        # Handles the encoding of a binary object into SQL Anywhere
        # SQL Anywhere requires that binary values be encoded as \xHH, where HH is a hexadecimal number
        # This function encodes the binary string in this format
        def self.string_to_binary(value)
          "\\x" + value.unpack("H*")[0].scan(/../).join("\\x")
        end
        
        def self.binary_to_string(value)
          value.gsub(/\\x[0-9]{2}/) { |byte| byte[2..3].hex }
        end
		
		# Should override the time column values.
		# Sybase doesn't like the time zones.
		
    end
    
    class SQLAnywhereAdapter < AbstractAdapter
      def initialize( connection, logger, connection_string = "") #:nodoc:
        super(connection, logger)
        @auto_commit = true
        @affected_rows = 0
        @connection_string = connection_string
        @visitor = Arel::Visitors::SQLAnywhere.new self
        connect!
      end

      def explain(arel, binds = [])
        # Not implemented
      end
      
      def adapter_name #:nodoc:
        'SQLAnywhere'
      end

      def supports_migrations? #:nodoc:
        true
      end

      def requires_reloading?
        true
      end
   
      def active?
        # The liveness variable is used a low-cost "no-op" to test liveness
        SA.instance.api.sqlany_execute_immediate(@connection, "SET liveness = 1") == 1
      rescue
        false
      end

      def disconnect!
        result = SA.instance.api.sqlany_disconnect( @connection )
        super
      end

      def reconnect!
        disconnect!
        connect!
      end

      def supports_count_distinct? #:nodoc:
        true
      end

      def supports_autoincrement? #:nodoc:
        true
      end

      # Maps native ActiveRecord/Ruby types into SQLAnywhere types
      # TINYINTs are treated as the default boolean value
      # ActiveRecord allows NULLs in boolean columns, and the SQL Anywhere BIT type does not
      # As a result, TINYINT must be used. All TINYINT columns will be assumed to be boolean and
      # should not be used as single-byte integer columns. This restriction is similar to other ActiveRecord database drivers
      def native_database_types #:nodoc:
        {
          :primary_key => 'INTEGER PRIMARY KEY DEFAULT AUTOINCREMENT NOT NULL',
          :string      => { :name => "varchar", :limit => 255 },
          :text        => { :name => "long varchar" },
          :integer     => { :name => "integer", :limit => 4 },
          :float       => { :name => "float" },
          :decimal     => { :name => "decimal" },
          :datetime    => { :name => "datetime" },
          :timestamp   => { :name => "datetime" },
          :time        => { :name => "time" },
          :date        => { :name => "date" },
          :binary      => { :name => "binary" },
          :boolean     => { :name => "tinyint", :limit => 1}
        }
      end
      
      def select_rows(sql, name = nil)
        exec_query(sql, name).rows
      end

      # QUOTING ==================================================

      # Applies quotations around column names in generated queries
      def quote_column_name(name) #:nodoc:
        # Remove backslashes and double quotes from column names
        name = name.to_s.gsub(/\\|"/, '')
        %Q("#{name}")
      end

      def quote_table_name(name)
        # Remove backslashes and double quotes from column names
        name = name.to_s.gsub(/\\|"/, '')
        # If it contains a dot, leave that out of quotes (by quoting it here..)
        name = name.gsub(/\./, '"."')
        %Q("#{name}")
      end

      # Handles special quoting of binary columns. Binary columns will be treated as strings inside of ActiveRecord.
      # ActiveRecord requires that any strings it inserts into databases must escape the backslash (\).
      # Since in the binary case, the (\x) is significant to SQL Anywhere, it cannot be escaped.
      def quote(value, column = nil)
        case value
          when String, ActiveSupport::Multibyte::Chars
            value_S = value.to_s
            if column && column.type == :binary && column.class.respond_to?(:string_to_binary)
              "'#{column.class.string_to_binary(value_S)}'"
            else
               super(value, column)
            end
          when TrueClass
            1
          when FalseClass
            0
          else
            super(value, column)
        end
      end

      # The database execution function
      def execute(sql, name = nil) #:nodoc:
        if name == :skip_logging
          begin
            stmt = SA.instance.api.sqlany_prepare(@connection, sql)
            sqlanywhere_error_test(sql) if stmt==nil
            r = SA.instance.api.sqlany_execute(stmt)
            sqlanywhere_error_test(sql) if r==0
            @affected_rows = SA.instance.api.sqlany_affected_rows(stmt)
            sqlanywhere_error_test(sql) if @affected_rows==-1
          rescue StandardError => e
            @affected_rows = 0
            raise e
          ensure
            SA.instance.api.sqlany_free_stmt(stmt)
          end

        else
          log(sql, name) { execute(sql, :skip_logging) }
        end
        @affected_rows
      end
      
      def sqlanywhere_error_test(sql = '')
        error_code, error_message = SA.instance.api.sqlany_error(@connection)
        if error_code != 0
          sqlanywhere_error(error_code, error_message, sql)
        end
      end
      
      def sqlanywhere_error(code, message, sql)        
        raise SQLAnywhereException.new(message, code, sql)
      end

      def translate_exception(exception, message)
        return super unless exception.respond_to?(:errno)
        case exception.errno
          when -143
            if exception.sql !~ /^SELECT/i then
              raise ActiveRecord::ActiveRecordError.new(message)
            else
              super
            end
          when -194
            raise InvalidForeignKey.new(message, exception)
          when -196
            raise RecordNotUnique.new(message, exception)
          when -183
            raise ArgumentError, message
          else
            super
        end
      end
      
      def last_inserted_id(result)
        select('SELECT @@IDENTITY').first["@@IDENTITY"]
      end

      def begin_db_transaction #:nodoc:   
        @auto_commit = false;
      end

      def commit_db_transaction #:nodoc:
        SA.instance.api.sqlany_commit(@connection)
        @auto_commit = true;
      end

      def rollback_db_transaction #:nodoc:
        SA.instance.api.sqlany_rollback(@connection)
        @auto_commit = true;
      end

      # SQL Anywhere does not support sizing of integers based on the sytax INTEGER(size). Integer sizes
      # must be captured when generating the SQL and replaced with the appropriate size.
      def type_to_sql(type, limit = nil, precision = nil, scale = nil) #:nodoc:
        type = type.to_sym
        if native = native_database_types[type]
          if type == :integer
            case limit
              when 1
                'tinyint'
              when 2
                'smallint'
              when 3..4
                'integer'
              when 5..8
                'bigint'
              else
                'integer'
            end
          elsif type == :string and !limit.nil?
             "varchar (#{limit})"
          elsif type == :boolean
            'tinyint'
          elsif type == :binary
            if limit
              "binary (#{limit})"
            else
              "long binary"
            end
          else
            super(type, limit, precision, scale)
          end
        else
          super(type, limit, precision, scale)
        end
      end
      
      # Do not return SYS-owned or DBO-owned tables or RS_systabgroup-owned
      def tables(name = nil) #:nodoc:
        sql = "SELECT table_name FROM SYS.SYSTABLE WHERE creator NOT IN (0,3,5)"
        exec_query(sql, name).map { |row| row["table_name"] }
      end
      
      def columns(table_name, name = nil) #:nodoc:
        table_structure(table_name).map do |field|
          SQLAnywhereColumn.new(field['name'], field['default'], field['domain'], (field['nulls'] == 1))
        end
      end
      
      def indexes(table_name, name = nil) #:nodoc:
        sql = "SELECT DISTINCT index_name, \"unique\" FROM SYS.SYSTABLE INNER JOIN SYS.SYSIDXCOL ON SYS.SYSTABLE.table_id = SYS.SYSIDXCOL.table_id INNER JOIN SYS.SYSIDX ON SYS.SYSTABLE.table_id = SYS.SYSIDX.table_id AND SYS.SYSIDXCOL.index_id = SYS.SYSIDX.index_id WHERE table_name = '#{table_name}' AND index_category > 2"
        exec_query(sql, name).map do |row|
          index = IndexDefinition.new(table_name, row['index_name'])
          index.unique = row['unique'] == 1
          sql = "SELECT column_name FROM SYS.SYSIDX INNER JOIN SYS.SYSIDXCOL ON SYS.SYSIDXCOL.table_id = SYS.SYSIDX.table_id AND SYS.SYSIDXCOL.index_id = SYS.SYSIDX.index_id INNER JOIN SYS.SYSCOLUMN ON SYS.SYSCOLUMN.table_id = SYS.SYSIDXCOL.table_id AND SYS.SYSCOLUMN.column_id = SYS.SYSIDXCOL.column_id WHERE index_name = '#{row['index_name']}'"	
          index.columns = exec_query(sql).map { |col| col['column_name'] }
          index
        end
      end

      def primary_key(table_name) #:nodoc:
        sql = "SELECT cname from SYS.SYSCOLUMNS where tname = '#{table_name}' and in_primary_key = 'Y'"
        rs = exec_query(sql)
        if !rs.nil? and !rs.first.nil?
          rs.first['cname']
        else
          nil
        end
      end

      def remove_index(table_name, options={}) #:nodoc:
        exec_query "DROP INDEX #{quote_table_name(table_name)}.#{quote_column_name(index_name(table_name, options))}"
      end

      def rename_table(name, new_name)
        exec_query "ALTER TABLE #{quote_table_name(name)} RENAME #{quote_table_name(new_name)}"
      end

      def change_column_default(table_name, column_name, default) #:nodoc:
        exec_query "ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} DEFAULT #{quote(default)}"
      end

      def change_column_null(table_name, column_name, null, default = nil)
        unless null || default.nil?
          exec_query("UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(column_name)}=#{quote(default)} WHERE #{quote_column_name(column_name)} IS NULL")
        end
        exec_query("ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} #{null ? '' : 'NOT'} NULL")
      end             

      def change_column(table_name, column_name, type, options = {}) #:nodoc:         
        add_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
        add_column_options!(add_column_sql, options)
        add_column_sql << ' NULL' if options[:null]
        exec_query(add_column_sql)
      end
       
      def rename_column(table_name, column_name, new_column_name) #:nodoc:
        if column_name.downcase == new_column_name.downcase
          whine = "if_the_only_change_is_case_sqlanywhere_doesnt_rename_the_column"
          rename_column table_name, column_name, "#{new_column_name}#{whine}"
          rename_column table_name, "#{new_column_name}#{whine}", new_column_name
        else
          exec_query "ALTER TABLE #{quote_table_name(table_name)} RENAME #{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}"
        end
      end

      def remove_column(table_name, *column_names)
        column_names = column_names.flatten
        column_names.zip(columns_for_remove(table_name, *column_names)).each do |unquoted_column_name, column_name|
          sql = <<-SQL
            SELECT "index_name" FROM SYS.SYSTAB join SYS.SYSTABCOL join SYS.SYSIDXCOL join SYS.SYSIDX
            WHERE "column_name" = '#{unquoted_column_name}' AND "table_name" = '#{table_name}'
          SQL
          select(sql, nil).each do |row|
            execute "DROP INDEX \"#{table_name}\".\"#{row['index_name']}\""      
          end
          exec_query "ALTER TABLE #{quote_table_name(table_name)} DROP #{column_name}"
        end
      end

     def disable_referential_integrity(&block) #:nodoc:
       old = select_value("SELECT connection_property( 'wait_for_commit' )")
 
       begin
         update("SET TEMPORARY OPTION wait_for_commit = ON")
         yield
       ensure
         update("SET TEMPORARY OPTION wait_for_commit = #{old}")
       end
     end
      
	  
	  				
      protected
      
        def select(sql, name = nil, binds = []) #:nodoc:
           exec_query(sql, name, binds).to_a
        end

        # Queries the structure of a table including the columns names, defaults, type, and nullability 
        # ActiveRecord uses the type to parse scale and precision information out of the types. As a result,
        # chars, varchars, binary, nchars, nvarchars must all be returned in the form <i>type</i>(<i>width</i>)
        # numeric and decimal must be returned in the form <i>type</i>(<i>width</i>, <i>scale</i>)
        # Nullability is returned as 0 (no nulls allowed) or 1 (nulls allowed)
        # Also, ActiveRecord expects an autoincrement column to have default value of NULL

        def table_structure(table_name)
          sql = <<-SQL
SELECT SYS.SYSCOLUMN.column_name AS name, 
  if left("default",1)='''' then substring("default", 2, length("default")-2) // remove the surrounding quotes
  else NULLIF(SYS.SYSCOLUMN."default", 'autoincrement') 
  endif AS "default",
  IF SYS.SYSCOLUMN.domain_id IN (7,8,9,11,33,34,35,3,27) THEN
    IF SYS.SYSCOLUMN.domain_id IN (3,27) THEN
      SYS.SYSDOMAIN.domain_name || '(' || SYS.SYSCOLUMN.width || ',' || SYS.SYSCOLUMN.scale || ')'
    ELSE
      SYS.SYSDOMAIN.domain_name || '(' || SYS.SYSCOLUMN.width || ')'
    ENDIF
  ELSE
    SYS.SYSDOMAIN.domain_name 
  ENDIF AS domain, 
  IF SYS.SYSCOLUMN.nulls = 'Y' THEN 1 ELSE 0 ENDIF AS nulls
FROM 
  SYS.SYSCOLUMN 
  INNER JOIN SYS.SYSTABLE ON SYS.SYSCOLUMN.table_id = SYS.SYSTABLE.table_id 
  INNER JOIN SYS.SYSDOMAIN ON SYS.SYSCOLUMN.domain_id = SYS.SYSDOMAIN.domain_id
WHERE
  table_name = '#{table_name}'
SQL
          structure = exec_query(sql, :skip_logging).to_hash

          structure.map do |column|
            if String === column["default"]
              # Escape the hexadecimal characters.
              # For example, a column default with a new line might look like 'foo\x0Abar'.
              # After the gsub it will look like 'foo\nbar'.
              column["default"].gsub!(/\\x(\h{2})/) {$1.hex.chr}
            end
            column
          end
          raise(ActiveRecord::StatementInvalid, "Could not find table '#{table_name}'") if structure == false
          structure
        end

      private

        def connect!
          result = SA.instance.api.sqlany_connect(@connection, @connection_string)
          if result == 1 then
            set_connection_options
          else
            error = SA.instance.api.sqlany_error(@connection)
            raise ActiveRecord::ActiveRecordError.new("#{error}: Cannot Establish Connection")
          end
        end

        def set_connection_options
          SA.instance.api.sqlany_execute_immediate(@connection, "SET TEMPORARY OPTION non_keywords = 'LOGIN'") rescue nil
          SA.instance.api.sqlany_execute_immediate(@connection, "SET TEMPORARY OPTION timestamp_format = 'YYYY-MM-DD HH:NN:SS'") rescue nil
          #SA.instance.api.sqlany_execute_immediate(@connection, "SET OPTION reserved_keywords = 'LIMIT'") rescue nil
          # The liveness variable is used a low-cost "no-op" to test liveness
          SA.instance.api.sqlany_execute_immediate(@connection, "CREATE VARIABLE liveness INT") rescue nil
        end
		
      def exec_query(sql, name = nil, binds = [])
        log(sql, name, binds) do
          stmt = SA.instance.api.sqlany_prepare(@connection, sql)
          sqlanywhere_error_test(sql) if stmt==nil
          
          begin
            
            for i in 0...binds.length
              bind_type = binds[i][0].type
              bind_value = binds[i][1]
              result, bind_param = SA.instance.api.sqlany_describe_bind_param(stmt, i)
              sqlanywhere_error_test(sql) if result==0
              
              bind_param.set_direction(1) # https://github.com/sqlanywhere/sqlanywhere/blob/master/ext/sacapi.h#L175
              if bind_value.nil?
                bind_param.set_value(nil)
              else
                # perhaps all this ought to be handled in the column class?
                case bind_type
                when :boolean
                  bind_param.set_value(bind_value ? 1 : 0)
                when :decimal
                  bind_param.set_value(bind_value.to_s)
                when :date
                  bind_param.set_value(bind_value.to_s)
                when :datetime, :time
                  bind_param.set_value(bind_value.to_time.getutc.strftime("%Y-%m-%d %H:%M:%S"))
                when :integer
                  bind_param.set_value(bind_value.to_i)
                else
                  bind_param.set_value(bind_value)
                end
              end
              result = SA.instance.api.sqlany_bind_param(stmt, i, bind_param)
              sqlanywhere_error_test(sql) if result==0
              
            end
            
            if SA.instance.api.sqlany_execute(stmt) == 0
              sqlanywhere_error_test(sql)
            end
            
            fields = []
            native_types = []
            
            num_cols = SA.instance.api.sqlany_num_cols(stmt)
            sqlanywhere_error_test(sql) if num_cols == -1
            
            for i in 0...num_cols
              result, col_num, name, ruby_type, native_type, precision, scale, max_size, nullable = SA.instance.api.sqlany_get_column_info(stmt, i)
              sqlanywhere_error_test(sql) if result==0
              fields << name
              native_types << native_type
            end
            rows = []
            while SA.instance.api.sqlany_fetch_next(stmt) == 1
              row = []
              for i in 0...num_cols
                r, value = SA.instance.api.sqlany_get_column(stmt, i)
                row << native_type_to_ruby_type(native_types[i], value)
              end
              rows << row
            end
            @affected_rows = SA.instance.api.sqlany_affected_rows(stmt)
            sqlanywhere_error_test(sql) if @affected_rows==-1
          rescue StandardError => e
            @affected_rows = 0
            raise e
          ensure
            SA.instance.api.sqlany_free_stmt(stmt)
          end
          
          if @auto_commit
            result = SA.instance.api.sqlany_commit(@connection)
            sqlanywhere_error_test(sql) if result==0
          end
          return ActiveRecord::Result.new(fields, rows)
        end
      end
        
      def exec_delete(sql, name = 'SQL', binds = [])
        exec_query(sql, name, binds)
        @affected_rows
      end
      alias :exec_update :exec_delete

        # convert sqlany type to ruby type
        # the types are taken from here
        # http://dcx.sybase.com/1101/en/dbprogramming_en11/pg-c-api-native-type-enum.html
        def native_type_to_ruby_type(native_type, value)
          return nil if value.nil?
          case native_type
          when 484 # DT_DECIMAL (also and more importantly numeric)
            BigDecimal.new(value)
          when 448,452,456,460,640  # DT_VARCHAR, DT_FIXCHAR, DT_LONGVARCHAR, DT_STRING, DT_LONGNVARCHAR
            value.force_encoding(ActiveRecord::Base.connection_config['encoding'] || "UTF-8")
          else
            value
          end
        end
    end
  end
end

