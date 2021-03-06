module Fluent
  class SQLOutput < BufferedOutput
    Plugin.register_output('sql', self)

    include SetTimeKeyMixin
    include SetTagKeyMixin

    config_param :host, :string
    config_param :port, :integer, :default => nil
    config_param :adapter, :string
    config_param :username, :string, :default => nil
    config_param :password, :string, :default => nil
    config_param :database, :string
    config_param :socket, :string, :default => nil
    config_param :remove_tag_prefix, :string, :default => nil

    attr_accessor :tables

    unless method_defined?(:log)
      define_method(:log) { $log }
    end

    # TODO: Merge SQLInput's TableElement
    class TableElement
      include Configurable

      config_param :table, :string
      config_param :column_mapping, :string
      config_param :num_retries, :integer, :default => 5

      attr_reader :model
      attr_reader :pattern

      def initialize(pattern, log)
        super()
        @pattern = MatchPattern.create(pattern)
        @log = log
      end

      def configure(conf)
        super

        @mapping = parse_column_mapping(@column_mapping)
        @format_proc = Proc.new { |record|
          new_record = {}
          @mapping.each { |k, c|
            new_record[c] = record[k]
          }
          new_record
        }
      end

      def init(base_model)
        # See SQLInput for more details of following code
        table_name = @table
        @model = Class.new(base_model) do
          self.table_name = table_name
          self.inheritance_column = '_never_use_output_'
        end

        class_name = table_name.singularize.camelize
        base_model.const_set(class_name, @model)
        model_name = ActiveModel::Name.new(@model, nil, class_name)
        @model.define_singleton_method(:model_name) { model_name }

        # TODO: check column_names and table schema
        columns = @model.columns.map { |column| column.name }.sort
      end

      def import(chunk)
        records = []
        chunk.msgpack_each { |tag, time, data|
          begin
            # format process should be moved to emit / format after supports error stream.
            records << @model.new(@format_proc.call(data))
          rescue => e
            args = {:error => e.message, :error_class => e.class, :table => @table, :record => Yajl.dump(data)}
            @log.warn "Failed to create the model. Ignore a record:", args
          end
        }
        begin
          @model.import(records)
        rescue ActiveRecord::StatementInvalid, ActiveRecord::ThrowResult, ActiveRecord::Import::MissingColumnError => e
          # ignore other exceptions to use Fluentd retry mechanizm
          @log.warn "Got deterministic error. Fallback to one-by-one import", :error => e.message, :error_class => e.class
          one_by_one_import(records)
        end
      end

      def one_by_one_import(records)
        records.each { |record|
          retries = 0
          begin
            @model.import([record])
          rescue ActiveRecord::StatementInvalid, ActiveRecord::ThrowResult, ActiveRecord::Import::MissingColumnError => e
            @log.error "Got deterministic error again. Dump a record", :error => e.message, :error_class => e.class, :record => record
          rescue => e
            retries += 1
            if retries > @num_retries
              @log.error "Can't recover undeterministic error. Dump a record", :error => e.message, :error_class => e.class, :record => record
              next
            end

            @log.warn "Failed to import a record: retry number = #{retries}", :error  => e.message, :error_class => e.class
            sleep 0.5
            retry
          end
        }
      end

      private

      def parse_column_mapping(column_mapping_conf)
        mapping = {}
        column_mapping_conf.split(',').each { |column_map|
          key, column = column_map.strip.split(':', 2)
          column = key if column.nil?
          mapping[key] = column
        }
        mapping
      end
    end

    def initialize
      super
      require 'active_record'
      require 'activerecord-import'
    end

    def configure(conf)
      super

      if remove_tag_prefix = conf['remove_tag_prefix']
        @remove_tag_prefix = Regexp.new('^' + Regexp.escape(remove_tag_prefix))
      end

      @tables = []
      @default_table = nil
      conf.elements.select { |e|
        e.name == 'table'
      }.each { |e|
        te = TableElement.new(e.arg, log)
        te.configure(e)
        if e.arg.empty?
          $log.warn "Detect duplicate default table definition" if @default_table
          @default_table = te
        else
          @tables << te
        end
      }
      @only_default = @tables.empty?

      if @default_table.nil?
        raise ConfigError, "There is no default table. <table> is required in sql output"
      end
    end

    def start
      super

      config = {
        :adapter => @adapter,
        :host => @host,
        :port => @port,
        :database => @database,
        :username => @username,
        :password => @password,
        :socket => @socket,
      }

      @base_model = Class.new(ActiveRecord::Base) do
        self.abstract_class = true
      end

      SQLOutput.const_set("BaseModel_#{rand(1 << 31)}", @base_model)
      @base_model.establish_connection(config)

      # ignore tables if TableElement#init failed
      @tables.reject! do |te|
        init_table(te, @base_model)
      end
      init_table(@default_table, @base_model)
    end

    def shutdown
      super
    end

    def emit(tag, es, chain)
      if @only_default
        super(tag, es, chain)
      else
        super(tag, es, chain, format_tag(tag))
      end
    end

    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def write(chunk)
      @tables.each { |table|
        if table.pattern.match(chunk.key)
          return table.import(chunk)
        end
      }
      @default_table.import(chunk)
    end

    private

    def init_table(te, base_model)
      begin
        te.init(base_model)
        log.info "Selecting '#{te.table}' table"
        false
      rescue => e
        log.warn "Can't handle '#{te.table}' table. Ignoring.", :error => e.message, :error_class => e.class
        log.warn_backtrace e.backtrace
        true
      end
    end

    def format_tag(tag)
      if @remove_tag_prefix
        tag.gsub(@remove_tag_prefix, '')
      else
        tag
      end
    end
  end
end
