# frozen_string_literal: true

module Aws
  module Rails
    module SqsActiveJob
      # @return [Configuration] the (singleton) Configuration
      def self.config
        @config ||= Configuration.new
      end

      # @yield Configuration
      def self.configure
        yield(config)
      end

      def self.fifo?(queue_url)
        queue_url.ends_with? '.fifo'
      end

      # Configuration for AWS SQS ActiveJob.
      # Use +Aws::Rails::SqsActiveJob.config+ to access the singleton config instance.
      class Configuration
        # Default configuration options
        # @api private
        DEFAULTS = {
          max_messages: 10,
          shutdown_timeout: 15,
          queues: {},
          logger: ::Rails.logger,
          message_group_id: 'SqsActiveJobGroup',
          excluded_deduplication_keys: ['job_id']
        }.freeze

        # @api private
        attr_accessor :queues, :max_messages, :visibility_timeout,
                      :shutdown_timeout, :client, :logger,
                      :async_queue_error_handler, :message_group_id

        attr_reader :excluded_deduplication_keys

        # Don't use this method directly: Configuration is a singleton class, use
        # +Aws::Rails::SqsActiveJob.config+ to access the singleton config.
        #
        # @param [Hash] options
        # @option options [Hash[Symbol, String]] :queues A mapping between the
        #   active job queue name and the SQS Queue URL. Note: multiple active
        #   job queues can map to the same SQS Queue URL.
        #
        # @option options  [Integer] :max_messages
        #    The max number of messages to poll for in a batch.
        #
        # @option options [Integer] :visibility_timeout
        #   If unset, the visibility timeout configured on the
        #   SQS queue will be used.
        #   The visibility timeout is the number of seconds
        #   that a message will not be processable by any other consumers.
        #   You should set this value to be longer than your expected job runtime
        #   to prevent other processes from picking up an running job.
        #   See the (SQS Visibility Timeout Documentation)[https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html]
        #
        # @option options [Integer] :shutdown_timeout
        #   the amount of time to wait
        #   for a clean shutdown.  Jobs that are unable to complete in this time
        #   will not be deleted from the SQS queue and will be retryable after
        #   the visibility timeout.
        #
        # @option options [ActiveSupport::Logger] :logger Logger to use
        #   for the poller.
        #
        # @option options [String] :config_file
        #   Override file to load configuration from. If not specified will
        #   attempt to load from config/aws_sqs_active_job.yml.
        #
        # @option options [String] :message_group_id (SqsActiveJobGroup)
        #  The message_group_id to use for queueing messages on a fifo queues.
        #  Applies only to jobs queued on FIFO queues.
        #  See the (SQS FIFO Documentation)[https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/FIFO-queues.html]
        #
        # @option options [Callable] :async_queue_error_handler An error handler
        #   to be called when the async active job adapter experiances an error
        #   queueing a job.  Only applies when
        #   +active_job.queue_adapter = :amazon_sqs_async+.  Called with:
        #   [error, job, job_options]
        #
        # @option options [SQS::Client] :client SQS Client to use. A default
        #   client will be created if none is provided.
        #
        # @option options [Array] :excluded_deduplication_keys (['job_id'])
        #   The type of keys stored in the array should be String or Symbol.
        #   Using this option, job_id is implicitly added to the keys.

        def initialize(options = {})
          options[:config_file] ||= config_file if File.exist?(config_file)
          options = DEFAULTS
                    .merge(file_options(options))
                    .merge(options)
          set_attributes(options)
        end

        def excluded_deduplication_keys=(keys)
          @excluded_deduplication_keys = keys.map(&:to_s) | ['job_id']
        end

        def client
          @client ||= begin
            client = Aws::SQS::Client.new
            client.config.user_agent_frameworks << 'aws-sdk-rails'
            client
          end
        end

        # Return the queue_url for a given job_queue name
        def queue_url_for(job_queue)
          job_queue = job_queue.to_sym
          raise ArgumentError, "No queue defined for #{job_queue}" unless queues.key? job_queue

          queues[job_queue]
        end

        # @api private
        def to_s
          to_h.to_s
        end

        # @api private
        def to_h
          h = {}
          instance_variables.each do |v|
            v_sym = v.to_s.gsub('@', '').to_sym
            val = instance_variable_get(v)
            h[v_sym] = val
          end
          h
        end

        private

        # Set accessible attributes after merged options.
        def set_attributes(options)
          options.each_key do |opt_name|
            instance_variable_set("@#{opt_name}", options[opt_name])
            client.config.user_agent_frameworks << 'aws-sdk-rails' if opt_name == :client
          end
        end

        def file_options(options = {})
          file_path = config_file_path(options)
          if file_path
            load_from_file(file_path)
          else
            {}
          end
        end

        def config_file
          file = ::Rails.root.join("config/aws_sqs_active_job/#{::Rails.env}.yml")
          file = ::Rails.root.join('config/aws_sqs_active_job.yml') unless File.exist?(file)
          file
        end

        # Load options from YAML file
        def load_from_file(file_path)
          opts = load_yaml(file_path) || {}
          opts.deep_symbolize_keys
        end

        # @return [String] Configuration path found in environment or YAML file.
        def config_file_path(options)
          options[:config_file] || ENV.fetch('AWS_SQS_ACTIVE_JOB_CONFIG_FILE', nil)
        end

        def load_yaml(file_path)
          require 'erb'
          source = ERB.new(File.read(file_path)).result

          # Avoid incompatible changes with Psych 4.0.0
          # https://bugs.ruby-lang.org/issues/17866
          # rubocop:disable Security/YAMLLoad
          begin
            YAML.load(source, aliases: true) || {}
          rescue ArgumentError
            YAML.load(source) || {}
          end
          # rubocop:enable Security/YAMLLoad
        end
      end
    end
  end
end
