# frozen_string_literal: true

require "json_rpc_handler"
require_relative "instrumentation"
require_relative "methods"

module MCP
  class Server
    DEFAULT_VERSION = "0.1.0"

    class RequestHandlerError < StandardError
      attr_reader :error_type
      attr_reader :original_error

      def initialize(message, request, error_type: :internal_error, original_error: nil)
        super(message)
        @request = request
        @error_type = error_type
        @original_error = original_error
      end
    end

    class MethodAlreadyDefinedError < StandardError
      attr_reader :method_name

      def initialize(method_name)
        super("Method #{method_name} already defined")
        @method_name = method_name
      end
    end

    include Instrumentation

    attr_accessor :name, :version, :tools, :prompts, :resources, :server_context, :configuration, :capabilities, :transport

    def initialize(
      name: "model_context_protocol",
      version: DEFAULT_VERSION,
      tools: [],
      prompts: [],
      resources: [],
      resource_templates: [],
      server_context: nil,
      configuration: nil,
      capabilities: nil,
      transport: nil
    )
      @name = name
      @version = version
      @tools = tools.to_h { |t| [t.name_value, t] }
      @prompts = prompts.to_h { |p| [p.name_value, p] }
      @resources = resources
      @resource_templates = resource_templates
      @resource_index = index_resources_by_uri(resources)
      @server_context = server_context
      @configuration = MCP.configuration.merge(configuration)
      @capabilities = capabilities || default_capabilities

      @handlers = {
        Methods::RESOURCES_LIST => method(:list_resources),
        Methods::RESOURCES_READ => method(:read_resource_no_content),
        Methods::RESOURCES_TEMPLATES_LIST => method(:list_resource_templates),
        Methods::TOOLS_LIST => method(:list_tools),
        Methods::TOOLS_CALL => method(:call_tool),
        Methods::PROMPTS_LIST => method(:list_prompts),
        Methods::PROMPTS_GET => method(:get_prompt),
        Methods::INITIALIZE => method(:init),
        Methods::PING => ->(_) { {} },

        # No op handlers for currently unsupported methods
        Methods::RESOURCES_SUBSCRIBE => ->(_) {},
        Methods::RESOURCES_UNSUBSCRIBE => ->(_) {},
        Methods::COMPLETION_COMPLETE => ->(_) {},
        Methods::LOGGING_SET_LEVEL => ->(_) {},
      }
      @transport = transport
    end

    def handle(request)
      JsonRpcHandler.handle(request) do |method|
        handle_request(request, method)
      end
    end

    def handle_json(request)
      JsonRpcHandler.handle_json(request) do |method|
        handle_request(request, method)
      end
    end

    def define_tool(name: nil, description: nil, input_schema: nil, annotations: nil, &block)
      tool = Tool.define(name:, description:, input_schema:, annotations:, &block)
      @tools[tool.name_value] = tool
    end

    def define_prompt(name: nil, description: nil, arguments: [], &block)
      prompt = Prompt.define(name:, description:, arguments:, &block)
      @prompts[prompt.name_value] = prompt
    end

    def define_custom_method(method_name:, &block)
      if @handlers.key?(method_name)
        raise MethodAlreadyDefinedError, method_name
      end

      @handlers[method_name] = block
    end

    def notify_tools_list_changed
      return unless @transport

      @transport.send_notification(Methods::NOTIFICATIONS_TOOLS_LIST_CHANGED)
    rescue => e
      report_exception(e, { notification: "tools_list_changed" })
    end

    def notify_prompts_list_changed
      return unless @transport

      @transport.send_notification(Methods::NOTIFICATIONS_PROMPTS_LIST_CHANGED)
    rescue => e
      report_exception(e, { notification: "prompts_list_changed" })
    end

    def notify_resources_list_changed
      return unless @transport

      @transport.send_notification(Methods::NOTIFICATIONS_RESOURCES_LIST_CHANGED)
    rescue => e
      report_exception(e, { notification: "resources_list_changed" })
    end

    def resources_list_handler(&block)
      @handlers[Methods::RESOURCES_LIST] = block
    end

    def resources_read_handler(&block)
      @handlers[Methods::RESOURCES_READ] = block
    end

    def resources_templates_list_handler(&block)
      @handlers[Methods::RESOURCES_TEMPLATES_LIST] = block
    end

    def tools_list_handler(&block)
      @handlers[Methods::TOOLS_LIST] = block
    end

    def tools_call_handler(&block)
      @handlers[Methods::TOOLS_CALL] = block
    end

    def prompts_list_handler(&block)
      @handlers[Methods::PROMPTS_LIST] = block
    end

    def prompts_get_handler(&block)
      @handlers[Methods::PROMPTS_GET] = block
    end

    private

    def handle_request(request, method)
      handler = @handlers[method]
      unless handler
        instrument_call("unsupported_method") {}
        return
      end

      Methods.ensure_capability!(method, capabilities)

      ->(params) {
        instrument_call(method) do
          case method
          when Methods::TOOLS_LIST
            { tools: @handlers[Methods::TOOLS_LIST].call(params) }
          when Methods::PROMPTS_LIST
            { prompts: @handlers[Methods::PROMPTS_LIST].call(params) }
          when Methods::RESOURCES_LIST
            { resources: @handlers[Methods::RESOURCES_LIST].call(params) }
          when Methods::RESOURCES_READ
            { contents: @handlers[Methods::RESOURCES_READ].call(params) }
          when Methods::RESOURCES_TEMPLATES_LIST
            { resourceTemplates: @handlers[Methods::RESOURCES_TEMPLATES_LIST].call(params) }
          else
            @handlers[method].call(params)
          end
        rescue => e
          report_exception(e, { request: request })
          if e.is_a?(RequestHandlerError)
            add_instrumentation_data(error: e.error_type)
            raise e
          end

          add_instrumentation_data(error: :internal_error)
          raise RequestHandlerError.new("Internal error handling #{method} request", request, original_error: e)
        end
      }
    end

    def default_capabilities
      {
        tools: { listChanged: true },
        prompts: { listChanged: true },
        resources: { listChanged: true },
      }
    end

    def server_info
      @server_info ||= {
        name:,
        version:,
      }
    end

    def init(request)
      {
        protocolVersion: configuration.protocol_version,
        capabilities: capabilities,
        serverInfo: server_info,
      }
    end

    def list_tools(request)
      @tools.map { |_, tool| tool.to_h }
    end

    def call_tool(request)
      tool_name = request[:name]
      tool = tools[tool_name]
      unless tool
        add_instrumentation_data(error: :tool_not_found)
        raise RequestHandlerError.new("Tool not found #{tool_name}", request, error_type: :tool_not_found)
      end

      arguments = request[:arguments] || {}
      add_instrumentation_data(tool_name:)

      if tool.input_schema&.missing_required_arguments?(arguments)
        add_instrumentation_data(error: :missing_required_arguments)
        raise RequestHandlerError.new(
          "Missing required arguments: #{tool.input_schema.missing_required_arguments(arguments).join(", ")}",
          request,
          error_type: :missing_required_arguments,
        )
      end

      if configuration.validate_tool_call_arguments && tool.input_schema
        begin
          tool.input_schema.validate_arguments(arguments)
        rescue Tool::InputSchema::ValidationError => e
          add_instrumentation_data(error: :invalid_schema)
          raise RequestHandlerError.new(e.message, request, error_type: :invalid_schema)
        end
      end

      begin
        call_tool_with_args(tool, arguments)
      rescue => e
        raise RequestHandlerError.new("Internal error calling tool #{tool_name}", request, original_error: e)
      end
    end

    def list_prompts(request)
      @prompts.map { |_, prompt| prompt.to_h }
    end

    def get_prompt(request)
      prompt_name = request[:name]
      prompt = @prompts[prompt_name]
      unless prompt
        add_instrumentation_data(error: :prompt_not_found)
        raise RequestHandlerError.new("Prompt not found #{prompt_name}", request, error_type: :prompt_not_found)
      end

      add_instrumentation_data(prompt_name:)

      prompt_args = request[:arguments]
      prompt.validate_arguments!(prompt_args)

      call_prompt_template_with_args(prompt, prompt_args)
    end

    def list_resources(request)
      @resources.map(&:to_h)
    end

    # Server implementation should set `resources_read_handler` to override no-op default
    def read_resource_no_content(request)
      add_instrumentation_data(resource_uri: request[:uri])
      []
    end

    def list_resource_templates(request)
      @resource_templates.map(&:to_h)
    end

    def report_exception(exception, server_context = {})
      configuration.exception_reporter.call(exception, server_context)
    end

    def index_resources_by_uri(resources)
      resources.each_with_object({}) do |resource, hash|
        hash[resource.uri] = resource
      end
    end

    def accepts_server_context?(method_object)
      parameters = method_object.parameters
      accepts_server_context = parameters.any? { |_type, name| name == :server_context }
      has_kwargs = parameters.any? { |type, _| type == :keyrest }

      accepts_server_context || has_kwargs
    end

    def call_tool_with_args(tool, arguments)
      args = arguments&.transform_keys(&:to_sym) || {}

      if accepts_server_context?(tool.method(:call))
        tool.call(**args, server_context: server_context).to_h
      else
        tool.call(**args).to_h
      end
    end

    def call_prompt_template_with_args(prompt, args)
      if accepts_server_context?(prompt.method(:template))
        prompt.template(args, server_context: server_context).to_h
      else
        prompt.template(args).to_h
      end
    end
  end
end
