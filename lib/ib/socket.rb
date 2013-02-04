require 'socket'

module IB
  class IBSocket < TCPSocket

    # Sends null terminated data string into socket
    def write_data data
      self.syswrite(data.to_s + EOL)
    end

    def read_string
      string = self.gets(EOL)
      raise SocketError.new "socke may close" if !string
      string.chop
    end

    def read_int
      self.read_string.to_i
    end

    def read_int_max
      str = self.read_string
      str.to_i unless str.nil? || str.empty?
    end

    def read_boolean
      str = self.read_string
      str.nil? ? false : str.to_i != 0
    end

    def read_decimal
      # Floating-point numbers shouldn't be used to store money...
      # ...but BigDecimals are too unwieldy to use in this case... maybe later
      #  self.read_string.to_d
      self.read_string.to_f
    end

    def read_decimal_max
      str = self.read_string
      # Floating-point numbers shouldn't be used to store money...
      # ...but BigDecimals are too unwieldy to use in this case... maybe later
      #  str.nil? || str.empty? ? nil : str.to_d
      str.to_f unless str.nil? || str.empty? || str.to_f > 1.797 * 10.0 ** 306
    end

    # If received decimal is below limit ("not yet computed"), return nil
    def read_decimal_limit limit = -1
      value = self.read_decimal
      # limit is the "not yet computed" indicator
      value <= limit ? nil : value
    end

    alias read_decimal_limit_1 read_decimal_limit

    def read_decimal_limit_2
      read_decimal_limit -2
    end

    ### Complex operations

    # Returns loaded Array or [] if count was 0
    def read_array &block
      count = read_int
      count > 0 ? Array.new(count, &block) : []
    end

    # Returns loaded Hash
    def read_hash
      tags = read_array { |_| [read_string, read_string] }
      tags.empty? ? Hash.new : Hash[*tags.flatten]
    end

  end # class IBSocket

end # module IB
