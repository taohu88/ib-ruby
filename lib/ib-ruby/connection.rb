require 'ib-ruby/socket'
require 'logger'
#require 'bigdecimal'
#require 'bigdecimal/util'

if RUBY_VERSION < "1.9"
  require 'sha1'
else
  require 'digest/sha1'
  include Digest
end

# Add method to_ib to render datetime in IB format (zero padded "yyyymmdd HH:mm:ss")
class Time
  def to_ib
    "#{self.year}#{sprintf("%02d", self.month)}#{sprintf("%02d", self.day)} " +
        "#{sprintf("%02d", self.hour)}:#{sprintf("%02d", self.min)}:#{sprintf("%02d", self.sec)}"
  end
end # Time

module IB
  # Encapsulates API connection to TWS
  class Connection

    # Please note, we are realizing only the most current TWS protocol versions,
    # thus improving performance at the expense of backwards compatibility.
    # Older protocol versions support can be found in older gem versions.

    CLIENT_VERSION = 48 # # Was 27 in original Ruby code
    SERVER_VERSION = 53 # Minimal server version. Latest, was 38 in current Java code.
    TWS_IP_ADDRESS = "127.0.0.1"
    TWS_PORT = "7496"

    attr_reader :next_order_id

    def initialize(opts = {})
      @options = {:ip => TWS_IP_ADDRESS, :port => TWS_PORT, }.merge(opts)

      @connected = false
      @next_order_id = nil
      @server = Hash.new # information about server and server connection state

      # Message listeners. Key is the message class to listen for.
      # Value is an Array of Procs. The proc will be called with the populated message
      # instance as its argument when a message of that type is received.
      @listeners = Hash.new { |hash, key| hash[key] = Array.new }

      #logger.debug("IB#init: Initializing...")

      self.open(@options)
    end

    def server_version
      @server[:version]
    end

    def open(opts = {})
      raise Exception.new("Already connected!") if @connected

      opts = @options.merge(opts)

      # Subscribe to the NextValidID message from TWS that is always
      # sent at connect, and save the id.
      self.subscribe(Messages::Incoming::NextValidID) do |msg|
        @next_order_id = msg.data[:id]
        p "Got next valid order id #{@next_order_id}."
      end

      @server[:socket] = IBSocket.open(opts[:ip], opts[:port])
      #logger.info("* TWS socket connected to #{@options[:ip]}:#{@options[:port]}.")

      # Secret handshake.
      @server[:socket].send(CLIENT_VERSION)
      @server[:version] = @server[:socket].read_int
      @server[:local_connect_time] = Time.now()
      raise(Exception.new("TWS version >= #{SERVER_VERSION} required.")) if @server[:version] < SERVER_VERSION

      puts "\tGot server version: #{@server[:version]}."
      #logger.debug("\tGot server version: #{@server[:version]}.")

      # Server version >= 20 sends the server time back. Our min server version is 38
      @server[:remote_connect_time] = @server[:socket].read_string
      #logger.debug("\tServer connect time: #{@server[:remote_connect_time]}.")

      # Server wants an arbitrary client ID at this point. This can be used
      # to identify subsequent communications.
      @server[:client_id] = SHA1.digest(Time.now.to_s + $$.to_s).unpack("C*").join.to_i % 999999999
      @server[:socket].send(@server[:client_id])
      #logger.debug("\tSent client id # #{@server[:client_id]}.")

      #logger.debug("Starting reader thread..")
      Thread.abort_on_exception = true
      @server[:reader_thread] = Thread.new { self.reader }

      @connected = true
    end

    def close
      @server[:reader_thread].kill # Thread uses blocking I/O, so join is useless.
      @server[:socket].close()
      @server = Hash.new
      @@server_version = nil
      @connected = false
      #logger.debug("Disconnected.")
    end

    def to_s
      "IB Connector: #{ @connected ? "connected." : "disconnected."}"
    end

    # Subscribe to incoming message events of type message_class.
    # code is a Proc that will be called with the message instance as its argument.
    def subscribe(message_class, code = nil, &block)
      code ||= block

      raise ArgumentError.new "Need listener proc or block" unless code.is_a? Proc
      unless message_class < Messages::Incoming::AbstractMessage
        raise ArgumentError.new "#{message_class} must be an IB message class"
      end

      @listeners[message_class].push(code)
    end

    # Send an outgoing message.
    def send(message)
      raise Exception.new("only sending Messages::Outgoing") unless message.is_a? Messages::Outgoing::AbstractMessage

      message.send(@server)
    end

    protected

    def reader
      loop do
        # this blocks, so Thread#join is useless.
        msg_id = @server[:socket].read_int

        # Debug:
        p "Got message #{msg_id} (#{Messages::Incoming::Table[msg_id]})" unless [1, 2, 4, 6, 7, 8, 9, 53].include? msg_id

        if msg_id == 0
          # Debug:
          p "Zero msg id! Must be a nil passed in... Ignoring..."
        else
          # Create a new instance of the appropriate message type, and have it read the message.
          # NB: Failure here usually means unsupported message type received
          msg = Messages::Incoming::Table[msg_id].new(@server[:socket], @server[:version])

          @listeners[msg.class].each { |listener|
            listener.call(msg)
          }

          # Log the error messages. Make an exception for the "successfully connected"
          # messages, which, for some reason, come back from IB as errors.
          if msg.is_a?(Messages::Incoming::Error)
            # connect strings
            if msg.code == 2104 || msg.code == 2106
              #logger.info(msg.to_human)
            else
              #logger.error(msg.to_human)
            end
          else
            # Warn if nobody listened to a non-error incoming message.
            unless @listeners[msg.class].size > 0
              #logger.warn { " WARNING: Nobody listened to incoming message #{msg.class}" }
            end
          end
        end
        # #logger.debug("Reader done with message id #{msg_id}.")
      end # loop
    end # reader
  end # class Connection
  IB = Connection
end # module IB